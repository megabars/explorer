import SwiftUI
import AppKit

struct FileListNSTableView: NSViewRepresentable {
    private static let tagDotSize: CGFloat = 8
    private static let tagDotSpacing: CGFloat = 3
    private static let visibleTagLimit = 5

    enum DropTransfer {
        case copy, move

        var operation: NSDragOperation {
            switch self {
            case .copy: .copy
            case .move: .move
            }
        }
    }

    let items: [FileItem]
    @Binding var selection: Set<URL>
    var renamingItem: FileItem?
    let renameText: (URL) -> String?
    let onOpen: (FileItem) -> Void
    let onNewFolder: () -> Void
    let onRename: (FileItem) -> Void
    let onRenameTextChange: (URL, String) -> Void
    let onCommitRename: (URL, String) -> Void
    let onCancelRename: (URL) -> Void
    let onTrash: ([FileItem]) -> Void
    let onSelectionAnchorChanged: (URL?) -> Void
    let onError: @MainActor (String) -> Void
    // Clipboard
    let onCut: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let canPaste: () -> Bool
    // Duplicate
    let onDuplicate: () -> Void
    // Compress
    let onCompress: () -> Void
    // Tags
    let onSetTags: (FileItem, [String]) -> Void
    // Sidebar
    var onAddToSidebar: ((URL) -> Void)?
    // Current directory (for empty-space context menu)
    var currentURL: URL
    // Drag & Drop
    let onDrop: ([URL], URL, DropTransfer) -> Void
    // Tags column
    var tagsColumnVisible: Bool
    let onTagsColumnVisibilityChanged: (Bool) -> Void
    // Cut indicator
    var cutURLs: Set<URL>
    // Sorting
    var sortKey: BrowserViewModel.SortKey
    var sortAscending: Bool
    let onSortChange: (BrowserViewModel.SortKey, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true

        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 3, height: 2)

        let tagsCol = NSTableColumn(identifier: .init("tags"))
        tagsCol.title = L10n.text("Tags")
        let tagsWidth = CGFloat(Self.visibleTagLimit) * Self.tagDotSize
            + CGFloat(Self.visibleTagLimit - 1) * Self.tagDotSpacing + 6
        tagsCol.maxWidth = tagsWidth
        tagsCol.minWidth = tagsWidth
        tagsCol.width = tagsWidth

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L10n.text("Name")
        nameCol.width = 300
        nameCol.minWidth = 80
        nameCol.resizingMask = .autoresizingMask
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = L10n.text("Date Modified")
        dateCol.width = 155
        dateCol.minWidth = 80
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "dateModified", ascending: false)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L10n.text("Size")
        sizeCol.width = 75
        sizeCol.minWidth = 50
        sizeCol.headerCell.alignment = .right
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = L10n.text("Kind")
        kindCol.width = 130
        kindCol.minWidth = 60
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)

        for col in [tagsCol, nameCol, dateCol, sizeCol, kindCol] { tableView.addTableColumn(col) }
        context.coordinator.syncSortDescriptors(in: tableView)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        // Right-click menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        // Drag & Drop
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        tableView.sizeLastColumnToFit()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // Sync tags column visibility
        if let col = tableView.tableColumn(withIdentifier: .init("tags")),
           col.isHidden != !tagsColumnVisible {
            col.isHidden = !tagsColumnVisible
        }

        coordinator.syncSortDescriptors(in: tableView)
        coordinator.updateRows(in: tableView)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FileListNSTableView
        weak var tableView: NSTableView?
        // AppKit's row indexes refer to this snapshot until the editor can be safely removed.
        private var displayedItems: [FileItem] = []
        private var displayedCutURLs: Set<URL> = []
        private var isSyncingSelection = false

        // MARK: Rename state
        private var renamingRow: Int?
        private weak var editingTextField: NSTextField?

        private struct ValidatedDrop {
            let sequenceNumber: Int
            let destination: URL
            let transfer: DropTransfer
        }

        private var validatedDrop: ValidatedDrop?

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = L10n.locale
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        init(_ parent: FileListNSTableView) {
            self.parent = parent
        }

        func updateRows(in tableView: NSTableView) {
            let requestedID = parent.renamingItem?.id
            let renameTargetMissing = requestedID.map { id in
                !parent.items.contains { $0.id == id }
            } ?? false
            if let renamingRow, displayedItems[renamingRow].id != requestedID || renameTargetMissing {
                finishEditing()
            }

            syncRows(in: tableView)

            guard let requestedID else { return }
            if renameTargetMissing {
                // This can run during updateNSView. Clear the binding on the next pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.renamingItem?.id == requestedID,
                          !self.parent.items.contains(where: { $0.id == requestedID }) else { return }
                    self.parent.onCancelRename(requestedID)
                }
            } else if renamingRow == nil,
                      let row = displayedItems.firstIndex(where: { $0.id == requestedID }) {
                beginEditing(row: row, in: tableView)
            }
        }

        private func syncRows(in tableView: NSTableView) {
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if renamingRow == nil,
               displayedCutURLs != parent.cutURLs || !displayedItems.elementsEqual(parent.items, by: sameRow) {
                let scrollOffset = tableView.visibleRect.origin
                displayedItems = parent.items
                displayedCutURLs = parent.cutURLs
                tableView.reloadData()
                tableView.scroll(scrollOffset)
            }

            let selection = parent.selection
            let indexes = IndexSet(displayedItems.indices.filter { selection.contains(displayedItems[$0].url) })
            if tableView.selectedRowIndexes != indexes {
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        private func sameRow(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
            // FileItem equality tracks identity. Cells and actions also depend on its metadata.
            lhs.id == rhs.id && lhs.url == rhs.url && lhs.name == rhs.name &&
            lhs.isDirectory == rhs.isDirectory && lhs.isPackage == rhs.isPackage &&
            lhs.isHidden == rhs.isHidden && lhs.isSymlink == rhs.isSymlink &&
            lhs.fileSize == rhs.fileSize && lhs.contentModificationDate == rhs.contentModificationDate &&
            lhs.creationDate == rhs.creationDate && lhs.kind == rhs.kind && lhs.tags == rhs.tags
        }

        // MARK: - Rename editing

        private func beginEditing(row: Int, in tableView: NSTableView) {
            renamingRow = row
            tableView.scrollRowToVisible(row)
            let id = displayedItems[row].id
            // Defer to next run-loop pass so the cell is fully laid out after any preceding reloadData.
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView, self.renamingRow == row,
                      self.displayedItems[row].id == id, self.editingTextField == nil else { return }
                guard let text = self.parent.renameText(id) else {
                    self.finishEditing()
                    self.syncRows(in: tableView)
                    return
                }
                let nameColumn = tableView.column(withIdentifier: .init("name"))
                guard let window = tableView.window, nameColumn >= 0,
                      let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
                      let tf = cell.textField else {
                    self.cancelRename()
                    return
                }
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.editingTextField = tf
                tf.isEditable = true
                tf.isBezeled = true
                tf.bezelStyle = .roundedBezel
                tf.stringValue = text
                tf.delegate = self
                guard window.makeFirstResponder(tf) else {
                    self.cancelRename()
                    return
                }
                tf.currentEditor()?.selectAll(nil)
            }
        }

        private func commitRename(newText: String) {
            guard let row = renamingRow else { return }
            let id = displayedItems[row].id
            finishEditing()
            parent.onCommitRename(id, newText)
            if let tableView { syncRows(in: tableView) }
        }

        private func cancelRename() {
            guard let row = renamingRow else { return }
            let id = displayedItems[row].id
            finishEditing()
            parent.onCancelRename(id)
            if let tableView { syncRows(in: tableView) }
        }

        private func finishEditing() {
            let row = renamingRow
            renamingRow = nil
            guard let row, let tf = editingTextField else { return }
            editingTextField = nil
            tf.delegate = nil
            if let editor = tf.currentEditor(), tableView?.window?.firstResponder === editor {
                tableView?.window?.makeFirstResponder(tableView)
            }
            tf.isEditable = false
            tf.isBezeled = false
            tf.stringValue = displayedItems[row].name
        }

        // MARK: NSTextFieldDelegate — rename text field events

        func controlTextDidChange(_ obj: Notification) {
            guard let row = renamingRow, let tf = obj.object as? NSTextField,
                  tf === editingTextField else { return }
            parent.onRenameTextChange(displayedItems[row].id, tf.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField,
                  tf === editingTextField else { return }
            // Focus lost without explicit Enter/Escape → treat as commit (Finder-like behaviour).
            commitRename(newText: tf.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === editingTextField else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitRename(newText: textView.string)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelRename()
                return true
            }
            return false
        }

        // MARK: DataSource

        func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

        // MARK: Delegate — cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayedItems.indices.contains(row) else { return nil }
            let item = displayedItems[row]
            let isCut = displayedCutURLs.contains(item.url)
            let colID = tableColumn?.identifier.rawValue ?? ""

            let view: NSView?
            switch colID {
            case "tags":
                view = tagsCell(for: item, in: tableView)
            case "name":
                view = nameCell(for: item, in: tableView)
            case "date":
                let text = item.contentModificationDate.map { dateFormatter.string(from: $0) } ?? "—"
                view = labelCell(id: "dateCell", text: text, alignment: .left, in: tableView)
            case "size":
                let text = item.isDirectory ? "—" : item.fileSize.map { FileSizeFormatter.string(fromByteCount: $0) } ?? "—"
                view = labelCell(id: "sizeCell", text: text, alignment: .right, in: tableView)
            case "kind":
                view = labelCell(id: "kindCell", text: item.kind, alignment: .left, in: tableView)
            default:
                view = nil
            }
            // Apply cut opacity to all cells of cut items
            view?.alphaValue = isCut ? 0.4 : 1.0
            return view
        }

        private func tagsCell(for item: FileItem, in tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("tagsCell")
            let cell: NSTableCellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let stack = NSStackView()
                stack.identifier = NSUserInterfaceItemIdentifier("tagDotsStack")
                stack.orientation = .horizontal
                stack.spacing = FileListNSTableView.tagDotSpacing
                stack.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: c.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()

            if let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "tagDotsStack" }) as? NSStackView {
                stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                for tag in item.tags.prefix(FileListNSTableView.visibleTagLimit) {
                    let dot = NSView()
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = tagNSColor(tag).cgColor
                    dot.layer?.cornerRadius = FileListNSTableView.tagDotSize / 2
                    dot.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        dot.widthAnchor.constraint(equalToConstant: FileListNSTableView.tagDotSize),
                        dot.heightAnchor.constraint(equalToConstant: FileListNSTableView.tagDotSize),
                    ])
                    stack.addArrangedSubview(dot)
                }
            }
            return cell
        }

        // MARK: Column visibility (macOS 13+)
        // nonisolated + assumeIsolated because AppKit always calls these on the main thread
        // but the new SDK annotations don't carry @preconcurrency like older delegate methods do.

        nonisolated func tableView(_ tableView: NSTableView, userCanChangeVisibilityOf column: NSTableColumn) -> Bool {
            MainActor.assumeIsolated {
                column.identifier.rawValue == "tags"
            }
        }

        nonisolated func tableView(_ tableView: NSTableView, userDidChangeVisibilityOf columns: [NSTableColumn]) {
            MainActor.assumeIsolated {
                guard let tagsCol = columns.first(where: { $0.identifier.rawValue == "tags" }) else { return }
                parent.onTagsColumnVisibilityChanged(!tagsCol.isHidden)
            }
        }

        private func nameCell(for item: FileItem, in tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("nameCell")
            let cell: NSTableCellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id

                let img = NSImageView()
                img.translatesAutoresizingMaskIntoConstraints = false
                img.imageScaling = .scaleProportionallyDown
                c.imageView = img
                c.addSubview(img)

                // Use a regular NSTextField (not labelWithString) so it can be made editable
                // for inline renaming without needing a separate overlay view.
                let tf = NSTextField()
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingMiddle
                tf.isBordered = false
                tf.isBezeled = false
                tf.drawsBackground = false
                tf.isEditable = false
                tf.isSelectable = false
                tf.font = .systemFont(ofSize: NSFont.systemFontSize)
                c.textField = tf
                c.addSubview(tf)

                NSLayoutConstraint.activate([
                    img.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    img.widthAnchor.constraint(equalToConstant: 16),
                    img.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()

            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.imageView?.image?.size = NSSize(width: 16, height: 16)
            // Only update the name if this cell is not the one currently being renamed —
            // overwriting it would clobber whatever the user has typed so far.
            if let textField = cell.textField, textField !== editingTextField {
                textField.stringValue = item.name
            }

            return cell
        }

        private func tagNSColor(_ tag: String) -> NSColor {
            switch tag.lowercased() {
            case "red":    return .systemRed
            case "orange": return .systemOrange
            case "yellow": return .systemYellow
            case "green":  return .systemGreen
            case "blue":   return .systemBlue
            case "purple": return .systemPurple
            case "gray", "grey": return .systemGray
            default:       return .systemGray
            }
        }

        private func labelCell(id: String, text: String, alignment: NSTextAlignment, in tableView: NSTableView) -> NSView {
            let nsID = NSUserInterfaceItemIdentifier(id)
            let cell: NSTableCellView = tableView.makeView(withIdentifier: nsID, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = nsID
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.alignment = alignment
                c.textField = tf
                c.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = text
            return cell
        }

        // MARK: Sorting

        func syncSortDescriptors(in tableView: NSTableView) {
            let current = tableView.sortDescriptors.first
            guard current?.key != parent.sortKey.rawValue || current?.ascending != parent.sortAscending else { return }
            tableView.sortDescriptors = [NSSortDescriptor(key: parent.sortKey.rawValue, ascending: parent.sortAscending)]
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let sortKey = BrowserViewModel.SortKey(rawValue: key),
                  sortKey != parent.sortKey || descriptor.ascending != parent.sortAscending else { return }
            parent.onSortChange(sortKey, descriptor.ascending)
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tv = notification.object as? NSTableView else { return }
            let urls = Set(tv.selectedRowIndexes.compactMap { row in
                displayedItems.indices.contains(row) ? displayedItems[row].url : nil
            })
            if parent.selection != urls { parent.selection = urls }
            let anchorRow = tv.clickedRow >= 0 && tv.selectedRowIndexes.contains(tv.clickedRow) ? tv.clickedRow : tv.selectedRow
            parent.onSelectionAnchorChanged(displayedItems.indices.contains(anchorRow) ? displayedItems[anchorRow].url : nil)
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard displayedItems.indices.contains(row) else { return }
            parent.onOpen(displayedItems[row])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView else { return }
            let row = tv.clickedRow
            let canPaste = parent.canPaste()

            // Right-click on empty space — show background context menu
            guard displayedItems.indices.contains(row) else {
                menu.addItem(withTitle: L10n.text("New Folder"), action: #selector(menuNewFolder(_:)), keyEquivalent: "")
                    .target = self
                menu.addItem(.separator())
                let pasteItem = menu.addItem(withTitle: L10n.text("Paste"), action: canPaste ? #selector(menuPaste(_:)) : nil, keyEquivalent: "")
                pasteItem.target = self
                if !canPaste { pasteItem.isEnabled = false }
                menu.addItem(.separator())
                let termItem = menu.addItem(withTitle: L10n.text("Open in Terminal"), action: #selector(menuOpenInTerminal(_:)), keyEquivalent: "")
                termItem.representedObject = parent.currentURL
                termItem.target = self
                return
            }

            let item = displayedItems[row]

            // If the right-clicked item is not already selected, select it exclusively
            if !parent.selection.contains(item.url) {
                parent.selection = [item.url]
                parent.onSelectionAnchorChanged(item.url)
            }

            menu.addItem(withTitle: L10n.text("Open"), action: #selector(menuOpen(_:)), keyEquivalent: "")
                .representedObject = item.url

            // "Open With ▶" submenu — for files only (not directories/packages)
            if !item.isDirectory && !item.isPackage {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
                if !apps.isEmpty {
                    let openWithItem = NSMenuItem(title: L10n.text("Open With"), action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: L10n.text("Open With"))
                    let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: item.url)
                    for appURL in apps {
                        let appName = (Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String)
                                      ?? appURL.deletingPathExtension().lastPathComponent
                        let title = appURL == defaultAppURL ? L10n.format("%@ (default)", appName) : appName
                        let mi = NSMenuItem(title: title, action: #selector(menuOpenWith(_:)), keyEquivalent: "")
                        mi.representedObject = [item.url, appURL] as [URL]
                        mi.target = self
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        icon.size = NSSize(width: 16, height: 16)
                        mi.image = icon
                        submenu.addItem(mi)
                    }
                    openWithItem.submenu = submenu
                    menu.addItem(openWithItem)
                }
            }
            menu.addItem(.separator())

            // Clipboard
            menu.addItem(withTitle: L10n.text("Cut"), action: #selector(menuCut(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: L10n.text("Copy"), action: #selector(menuCopy(_:)), keyEquivalent: "")
                .representedObject = item.url
            let pasteItem = menu.addItem(withTitle: L10n.text("Paste"), action: canPaste ? #selector(menuPaste(_:)) : nil, keyEquivalent: "")
            if !canPaste { pasteItem.isEnabled = false }
            menu.addItem(.separator())

            menu.addItem(withTitle: L10n.text("Duplicate"), action: #selector(menuDuplicate(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: L10n.text("Compress..."), action: #selector(menuCompress(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())

            menu.addItem(withTitle: L10n.text("Rename"), action: #selector(menuRename(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())

            menu.addItem(withTitle: L10n.text("Move to Trash"), action: #selector(menuTrash(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: L10n.text("Get Info"), action: #selector(menuGetInfo(_:)), keyEquivalent: "")
                .representedObject = item.url

            // Tags submenu
            let tagsMenu = NSMenu()
            for tagName in ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"] {
                let tagItem = NSMenuItem(title: L10n.text(tagName), action: #selector(menuToggleTag(_:)), keyEquivalent: "")
                tagItem.representedObject = [item.url, tagName, item] as [Any]
                tagItem.state = item.tags.contains(tagName) ? .on : .off
                tagItem.target = self
                tagsMenu.addItem(tagItem)
            }
            tagsMenu.addItem(.separator())
            let clearTagItem = NSMenuItem(title: L10n.text("None"), action: #selector(menuClearTags(_:)), keyEquivalent: "")
            clearTagItem.representedObject = [item.url, item] as [Any]
            clearTagItem.target = self
            tagsMenu.addItem(clearTagItem)
            let tagsMenuItem = NSMenuItem(title: L10n.text("Tags"), action: nil, keyEquivalent: "")
            tagsMenuItem.submenu = tagsMenu
            menu.addItem(tagsMenuItem)

            if item.isDirectory, parent.onAddToSidebar != nil {
                menu.addItem(.separator())
                menu.addItem(withTitle: L10n.text("Add to Sidebar"), action: #selector(menuAddToSidebar(_:)), keyEquivalent: "")
                    .representedObject = item.url
            }

            if item.isDirectory {
                menu.addItem(.separator())
                menu.addItem(withTitle: L10n.text("Open in Terminal"), action: #selector(menuOpenInTerminal(_:)), keyEquivalent: "")
                    .representedObject = item.url
            }

            for i in menu.items { i.target = self }
        }

        @objc func menuOpen(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            parent.onOpen(item)
        }

        @objc func menuRename(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let row = displayedItems.firstIndex(where: { $0.url == url }),
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            // Ensure row is selected before starting rename
            tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            parent.selection = [url]
            parent.onSelectionAnchorChanged(url)
            parent.onRename(item)
        }

        @objc func menuTrash(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            let selection = parent.selection
            parent.onTrash(selection.contains(url) ? parent.items.filter { selection.contains($0.url) } : [item])
        }

        @objc func menuGetInfo(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            ExplorerFileInfo.show(for: item, in: tableView?.window)
        }

        @objc func menuOpenWith(_ sender: NSMenuItem) {
            guard let urls = sender.representedObject as? [URL], urls.count == 2 else { return }
            FileOpening.open([urls[0]], with: urls[1], onError: parent.onError)
        }

        @objc func menuOpenInTerminal(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            FileOpening.openTerminal(at: url, onError: parent.onError)
        }

        @objc func menuNewFolder(_ sender: NSMenuItem) {
            parent.onNewFolder()
        }

        @objc func menuCut(_ sender: NSMenuItem) {
            parent.onCut()
        }

        @objc func menuCopy(_ sender: NSMenuItem) {
            parent.onCopy()
        }

        @objc func menuPaste(_ sender: NSMenuItem) {
            parent.onPaste()
        }

        @objc func menuDuplicate(_ sender: NSMenuItem) {
            parent.onDuplicate()
        }

        @objc func menuCompress(_ sender: NSMenuItem) {
            parent.onCompress()
        }

        @objc func menuAddToSidebar(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            parent.onAddToSidebar?(url)
        }

        @objc func menuToggleTag(_ sender: NSMenuItem) {
            guard let obj = sender.representedObject as? [Any],
                  let item = obj[2] as? FileItem,
                  let tagName = obj[1] as? String else { return }
            var tags = item.tags
            if tags.contains(tagName) {
                tags.removeAll { $0 == tagName }
            } else {
                tags.append(tagName)
            }
            parent.onSetTags(item, tags)
        }

        @objc func menuClearTags(_ sender: NSMenuItem) {
            guard let obj = sender.representedObject as? [Any],
                  let item = obj[1] as? FileItem else { return }
            parent.onSetTags(item, [])
        }

        // MARK: Drag Source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard displayedItems.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(displayedItems[row].url.absoluteString, forType: .fileURL)
            item.setData(Data(), forType: .init(GridFileTransfer.internalType))
            return item
        }

        // MARK: Drop Destination

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            validatedDrop = nil
            let mask = info.draggingSourceOperationMask
            let transfer: DropTransfer
            if mask.contains(.move) {
                transfer = .move
            } else if mask.contains(.copy) {
                transfer = .copy
            } else {
                return []
            }
            let folder = dropDirectory(at: row, operation: dropOperation)
            let destination = folder ?? parent.currentURL
            guard !dropURLs(from: info, to: destination).isEmpty else { return [] }

            if folder == nil { tableView.setDropRow(-1, dropOperation: .on) }
            validatedDrop = ValidatedDrop(sequenceNumber: info.draggingSequenceNumber, destination: destination, transfer: transfer)
            return transfer.operation
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            defer { validatedDrop = nil }
            let destination = dropDirectory(at: row, operation: dropOperation) ?? parent.currentURL
            guard let drop = validatedDrop, drop.sequenceNumber == info.draggingSequenceNumber,
                  drop.destination == destination,
                  info.draggingSourceOperationMask.contains(drop.transfer.operation) else { return false }

            let urls = dropURLs(from: info, to: destination)
            guard !urls.isEmpty else { return false }
            parent.onDrop(urls, destination, drop.transfer)
            return true
        }

        private func dropDirectory(at row: Int, operation: NSTableView.DropOperation) -> URL? {
            guard operation == .on, displayedItems.indices.contains(row),
                  displayedItems[row].isDirectory, !displayedItems[row].isPackage else { return nil }
            return displayedItems[row].url
        }

        private func dropURLs(from info: any NSDraggingInfo, to destination: URL) -> [URL] {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let destinationPath = destination.standardizedFileURL.pathComponents
            guard urls.allSatisfy({ !destinationPath.starts(with: $0.standardizedFileURL.pathComponents) }) else { return [] }
            return urls
        }
    }
}
