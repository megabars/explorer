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

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.minWidth = 80
        nameCol.resizingMask = .autoresizingMask

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Date Modified"
        dateCol.width = 155
        dateCol.minWidth = 80

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 75
        sizeCol.minWidth = 50
        sizeCol.headerCell.alignment = .right

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "Kind"
        kindCol.width = 130
        kindCol.minWidth = 60

        for col in [nameCol, dateCol, sizeCol, kindCol] { tableView.addTableColumn(col) }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        // Right-click menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        tableView.sizeLastColumnToFit()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = nsView.documentView as? NSTableView else { return }

        // Reload only when item list actually changed — preserves scroll position
        let newIDs = items.map(\.id)
        if newIDs != context.coordinator.lastItemIDs {
            context.coordinator.lastItemIDs = newIDs
            let scrollOffset = nsView.documentVisibleRect.origin
            tableView.reloadData()
            nsView.documentView?.scroll(scrollOffset)
        }

        // Sync selection from SwiftUI → NSTableView
        var indexes = IndexSet()
        for (i, item) in items.enumerated() {
            if selection.contains(item.url) { indexes.insert(i) }
        }
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileListNSTableView
        weak var tableView: NSTableView?
        var lastItemIDs: [URL] = []

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        }()

        init(_ parent: FileListNSTableView) {
            self.parent = parent
        }

        // MARK: DataSource

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        // MARK: Delegate — cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.items.count else { return nil }
            let item = parent.items[row]
            let colID = tableColumn?.identifier.rawValue ?? ""

            switch colID {
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

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingMiddle
                c.textField = tf
                c.addSubview(tf)

                NSLayoutConstraint.activate([
                    img.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    img.widthAnchor.constraint(equalToConstant: 16),
                    img.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()

            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.imageView?.image?.size = NSSize(width: 16, height: 16)
            return cell
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
            let snapshot = parent.items
            guard row >= 0, row < snapshot.count else { return }
            let item = snapshot[row]

            menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(menuTrash(_:)), keyEquivalent: "")
                .representedObject = item.url
            menu.addItem(withTitle: "Get Info", action: #selector(menuGetInfo(_:)), keyEquivalent: "")
                .representedObject = item.url

            for i in menu.items { i.target = self }
        }

        @objc func menuOpen(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let item = parent.items.first(where: { $0.url == url }) else { return }
            parent.onOpen(item)
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
    }
}
