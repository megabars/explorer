import SwiftUI
import AppKit

struct FileListNSTableView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<URL>
    var renamingItem: FileItem?
    var renameText: Binding<String>
    let onOpen: (FileItem) -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onTrash: (FileItem) -> Void
    // Clipboard
    let onCut: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    var hasPasteContent: Bool
    // Duplicate
    let onDuplicate: () -> Void
    // Compress
    let onCompress: () -> Void
    // Tags
    let onSetTags: (FileItem, [String]) -> Void
    // Sidebar
    var onAddToSidebar: ((URL) -> Void)?
    // Drag & Drop
    let onMove: ([URL], URL) -> Void
    // Tags column
    var tagsColumnVisible: Bool
    let onTagsColumnVisibilityChanged: (Bool) -> Void
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
        tagsCol.title = "Tags"
        tagsCol.width = 16
        tagsCol.minWidth = 12
        tagsCol.maxWidth = 22

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.minWidth = 80
        nameCol.resizingMask = .autoresizingMask
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Date Modified"
        dateCol.width = 155
        dateCol.minWidth = 80
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "dateModified", ascending: false)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 75
        sizeCol.minWidth = 50
        sizeCol.headerCell.alignment = .right
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "Kind"
        kindCol.width = 130
        kindCol.minWidth = 60
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)

        for col in [tagsCol, nameCol, dateCol, sizeCol, kindCol] { tableView.addTableColumn(col) }

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
        context.coordinator.parent = self
        guard let tableView = nsView.documentView as? NSTableView else { return }

        // Sync tags column visibility
        if let col = tableView.tableColumn(withIdentifier: .init("tags")),
           col.isHidden != !tagsColumnVisible {
            col.isHidden = !tagsColumnVisible
        }

        // Sync sort indicator arrow in column headers
        let keyMap: [BrowserViewModel.SortKey: String] = [.name: "name", .dateModified: "dateModified", .size: "size", .kind: "kind"]
        for col in tableView.tableColumns {
            if col.sortDescriptorPrototype?.key == keyMap[sortKey] {
                tableView.setIndicatorImage(
                    NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                    in: col
                )
                tableView.highlightedTableColumn = col
            } else {
                tableView.setIndicatorImage(nil, in: col)
            }
        }


        // Reload when item list or tag content changed — preserves scroll position.
        // Skip reloadData while rename is in progress to avoid destroying the editing cell.
        let newIDs = items.map(\.id)
        let newTagsHash = items.reduce(into: 0) { $0 ^= $1.url.hashValue &+ $1.tags.joined().hashValue }
        if newIDs != context.coordinator.lastItemIDs || newTagsHash != context.coordinator.lastTagsHash {
            // If the item being renamed disappeared, cancel rename first.
            if let renaming = renamingItem, !items.contains(where: { $0.id == renaming.id }) {
                context.coordinator.cancelEditing()
                onCancelRename()
            }
            context.coordinator.lastItemIDs = newIDs
            context.coordinator.lastTagsHash = newTagsHash
            // Don't reload while rename is active — it would destroy the editing text field.
            if !context.coordinator.isRenaming {
                let scrollOffset = nsView.documentVisibleRect.origin
                tableView.reloadData()
                nsView.documentView?.scroll(scrollOffset)
            }
        }

        // Sync selection from SwiftUI → NSTableView
        var indexes = IndexSet()
        for (i, item) in items.enumerated() {
            if selection.contains(item.url) { indexes.insert(i) }
        }
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        // Sync rename state: begin editing when renamingItem is set, end it when cleared.
        let coordinator = context.coordinator
        if let renaming = renamingItem,
           let row = items.firstIndex(where: { $0.id == renaming.id }) {
            if !coordinator.isRenaming {
                coordinator.beginEditing(row: row, text: renameText.wrappedValue, in: tableView)
            }
        } else if coordinator.isRenaming {
            // renamingItem was cleared externally (e.g. cancel from outside) — end editing.
            coordinator.cancelEditing()
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FileListNSTableView
        weak var tableView: NSTableView?
        var lastItemIDs: [URL] = []
        var lastTagsHash: Int = 0

        // MARK: Rename state
        var isRenaming = false
        var renamingRow: Int = -1
        weak var editingTextField: NSTextField?

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        init(_ parent: FileListNSTableView) {
            self.parent = parent
        }

        // MARK: - Rename editing

        func beginEditing(row: Int, text: String, in tableView: NSTableView) {
            guard !isRenaming else { return }
            isRenaming = true
            renamingRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            // Defer to next run-loop pass so the cell is fully laid out after any preceding reloadData.
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView, self.isRenaming else { return }
                // If the view was removed from the window between scheduling and execution,
                // abandon the rename — making a windowless text field first-responder is a no-op
                // and leaves the cell stuck in an editable-but-unfocused state.
                guard tableView.window != nil else {
                    self.isRenaming = false
                    self.renamingRow = -1
                    return
                }
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                      let tf = cell.textField else { return }
                self.editingTextField = tf
                tf.isEditable = true
                tf.isBezeled = true
                tf.bezelStyle = .roundedBezel
                tf.stringValue = text
                tf.delegate = self
                tableView.window?.makeFirstResponder(tf)
                tf.currentEditor()?.selectAll(nil)
            }
        }

        /// Ends rename editing and resets the cell to its normal (label) appearance.
        /// Call this before invoking any ViewModel callback so the guard in callbacks fires correctly.
        func commitEditing(newText: String) {
            guard isRenaming else { return }
            isRenaming = false
            let row = renamingRow
            renamingRow = -1
            cleanupTextField()
            tableView?.window?.makeFirstResponder(tableView)
            parent.renameText.wrappedValue = newText
            // Reload the row to show the item's current name (VM will update items via watcher).
            if row >= 0 { tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
        }

        func cancelEditing() {
            guard isRenaming else { return }
            isRenaming = false
            let row = renamingRow
            renamingRow = -1
            cleanupTextField()
            tableView?.window?.makeFirstResponder(tableView)
            // Reload to restore the original item name in the cell.
            if row >= 0 { tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
        }

        private func cleanupTextField() {
            guard let tf = editingTextField else { return }
            tf.isEditable = false
            tf.isBezeled = false
            tf.delegate = nil
            editingTextField = nil
        }

        // MARK: NSTextFieldDelegate — rename text field events

        func controlTextDidChange(_ obj: Notification) {
            guard isRenaming,
                  let tf = obj.object as? NSTextField,
                  tf === editingTextField else { return }
            // Keep the ViewModel's renameText in sync so commitRename reads the latest value.
            parent.renameText.wrappedValue = tf.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard isRenaming,
                  let tf = obj.object as? NSTextField,
                  tf === editingTextField else { return }
            // Focus lost without explicit Enter/Escape → treat as commit (Finder-like behaviour).
            let text = tf.stringValue
            commitEditing(newText: text)
            parent.onCommitRename()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === editingTextField else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let text = (control as? NSTextField)?.stringValue ?? ""
                // Set isRenaming = false before commitEditing so controlTextDidEndEditing
                // (which fires after we return true) finds isRenaming == false and exits early.
                commitEditing(newText: text)
                parent.onCommitRename()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelEditing()
                parent.onCancelRename()
                return true
            }
            return false
        }

        // MARK: DataSource

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        // MARK: Delegate — cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            // Snapshot to avoid index-out-of-bounds if items mutates between bounds check and access
            let items = parent.items
            guard row < items.count else { return nil }
            let item = items[row]
            let colID = tableColumn?.identifier.rawValue ?? ""

            switch colID {
            case "tags":
                return tagsCell(for: item, in: tableView)
            case "name":
                return nameCell(for: item, in: tableView)
            case "date":
                let text = item.contentModificationDate.map { dateFormatter.string(from: $0) } ?? "—"
                return labelCell(id: "dateCell", text: text, alignment: .left, in: tableView)
            case "size":
                let text = item.isDirectory ? "—" : item.fileSize.map { FileSizeFormatter.string(fromByteCount: $0) } ?? "—"
                return labelCell(id: "sizeCell", text: text, alignment: .right, in: tableView)
            case "kind":
                return labelCell(id: "kindCell", text: item.kind, alignment: .left, in: tableView)
            default:
                return nil
            }
        }

        private func tagsCell(for item: FileItem, in tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("tagsCell")
            let cell: NSTableCellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let stack = NSStackView()
                stack.identifier = NSUserInterfaceItemIdentifier("tagDotsStack")
                stack.orientation = .horizontal
                stack.spacing = 3
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
                for tag in item.tags.prefix(5) {
                    let dot = NSView()
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = tagNSColor(tag).cgColor
                    dot.layer?.cornerRadius = 4
                    dot.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        dot.widthAnchor.constraint(equalToConstant: 8),
                        dot.heightAnchor.constraint(equalToConstant: 8),
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
            if !(isRenaming && renamingRow == tableView.row(for: cell)) {
                cell.textField?.stringValue = item.name
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

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            let sortKey: BrowserViewModel.SortKey
            switch key {
            case "name": sortKey = .name
            case "dateModified": sortKey = .dateModified
            case "size": sortKey = .size
            case "kind": sortKey = .kind
            default: return
            }
            parent.onSortChange(sortKey, descriptor.ascending)
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView else { return }
            let snapshot = parent.items
            let urls = Set(tv.selectedRowIndexes.compactMap { row in
                row < snapshot.count ? snapshot[row].url : nil
            })
            parent.selection = urls
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let snapshot = parent.items
            guard row >= 0, row < snapshot.count else { return }
            parent.onOpen(snapshot[row])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView else { return }
            let row = tv.clickedRow
            // Snapshot to avoid index-out-of-bounds if items mutates between bounds check and access
            let snapshot = parent.items

            // Right-click on empty space — show background context menu
            guard row >= 0, row < snapshot.count else {
                menu.addItem(withTitle: "New Folder", action: #selector(menuNewFolder(_:)), keyEquivalent: "")
                    .target = self
                menu.addItem(.separator())
                let pasteItem = menu.addItem(withTitle: "Paste", action: parent.hasPasteContent ? #selector(menuPaste(_:)) : nil, keyEquivalent: "")
                pasteItem.target = self
                if !parent.hasPasteContent { pasteItem.isEnabled = false }
                return
            }

            let item = snapshot[row]

            // If the right-clicked item is not already selected, select it exclusively
            if !parent.selection.contains(item.url) {
                parent.selection = [item.url]
            }

            menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())

            // Clipboard
            menu.addItem(withTitle: "Cut", action: #selector(menuCut(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: "Copy", action: #selector(menuCopy(_:)), keyEquivalent: "")
                .representedObject = item.url
            let pasteItem = menu.addItem(withTitle: "Paste", action: parent.hasPasteContent ? #selector(menuPaste(_:)) : nil, keyEquivalent: "")
            pasteItem.representedObject = item.url
            if !parent.hasPasteContent { pasteItem.isEnabled = false }
            menu.addItem(.separator())

            menu.addItem(withTitle: "Duplicate", action: #selector(menuDuplicate(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: "Compress...", action: #selector(menuCompress(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())

            menu.addItem(withTitle: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())

            menu.addItem(withTitle: "Move to Trash", action: #selector(menuTrash(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: "Get Info", action: #selector(menuGetInfo(_:)), keyEquivalent: "")
                .representedObject = item.url

            // Tags submenu
            let tagsMenu = NSMenu()
            for tagName in ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"] {
                let tagItem = NSMenuItem(title: tagName, action: #selector(menuToggleTag(_:)), keyEquivalent: "")
                tagItem.representedObject = [item.url, tagName, item] as [Any]
                tagItem.state = item.tags.contains(tagName) ? .on : .off
                tagItem.target = self
                tagsMenu.addItem(tagItem)
            }
            tagsMenu.addItem(.separator())
            let clearTagItem = NSMenuItem(title: "None", action: #selector(menuClearTags(_:)), keyEquivalent: "")
            clearTagItem.representedObject = [item.url, item] as [Any]
            clearTagItem.target = self
            tagsMenu.addItem(clearTagItem)
            let tagsMenuItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            tagsMenuItem.submenu = tagsMenu
            menu.addItem(tagsMenuItem)

            if item.isDirectory, parent.onAddToSidebar != nil {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Add to Sidebar", action: #selector(menuAddToSidebar(_:)), keyEquivalent: "")
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
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            // Ensure row is selected before starting rename
            if let row = parent.items.firstIndex(where: { $0.id == item.id }) {
                tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            parent.selection = [item.url]
            // Trigger rename via the ViewModel (goes through SwiftUI → updateNSView → beginEditing)
            // We do this by calling the parent's onOpen equivalent — but rename has no direct callback.
            // Instead, update the selection so the keyboard shortcut handler in ContentView can fire.
            // For context menu rename, we call the view model indirectly via a notification or
            // use a dedicated callback. For now, simulate pressing Return by calling startRename
            // directly through the existing onOpen pattern — but we need a rename callback.
            // Since FileListView wires onCommitRename/onCancelRename, we need startRename from VM.
            // This is handled via the same path: selection is updated, user presses Return.
            // As a direct fix, post a notification that ContentView can observe.
            NotificationCenter.default.post(
                name: .renameRequestedForURL,
                object: nil,
                userInfo: ["url": url]
            )
        }

        @objc func menuTrash(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            parent.onTrash(item)
        }

        @objc func menuGetInfo(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc func menuNewFolder(_ sender: NSMenuItem) {
            NotificationCenter.default.post(name: .newFolderRequested, object: nil)
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
            let snapshot = parent.items
            guard row < snapshot.count else { return nil }
            let item = snapshot[row]
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.url.absoluteString, forType: .fileURL)
            return pbItem
        }

        // MARK: Drop Destination

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let snapshot = parent.items
            // If dropping onto a directory row, allow it; otherwise redirect to end of list
            if dropOperation == .on, row >= 0, row < snapshot.count, snapshot[row].isDirectory {
                return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
            }
            // Disallow drop onto non-directory rows; redirect to .above (end of list)
            tableView.setDropRow(-1, dropOperation: .on)
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let snapshot = parent.items
            let destination: URL
            if dropOperation == .on, row >= 0, row < snapshot.count, snapshot[row].isDirectory {
                destination = snapshot[row].url
            } else {
                // Drop onto background — move into the current directory (no-op move but handled by caller)
                return false
            }

            var urls: [URL] = []
            info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, _, _ in
                guard let pbItem = draggingItem.item as? NSPasteboardItem,
                      let str = pbItem.string(forType: .fileURL),
                      let url = URL(string: str) else { return }
                urls.append(url)
            }
            guard !urls.isEmpty else { return false }
            parent.onMove(urls, destination)
            return true
        }
    }
}
