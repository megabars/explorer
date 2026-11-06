import AppKit

@MainActor
enum ExplorerFileInfo {
    static func show(for item: FileItem, in window: NSWindow? = NSApp?.keyWindow) {
        guard let window else { return }
        let details: [(String, String?)] = [
            ("Kind", item.kind),
            ("Where", item.url.deletingLastPathComponent().path),
            ("Size", item.isDirectory ? nil : item.fileSize.map(FileSizeFormatter.string(fromByteCount:))),
            ("Created", item.creationDate?.formatted(date: .long, time: .shortened)),
            ("Modified", item.contentModificationDate?.formatted(date: .long, time: .shortened)),
            ("Tags", item.tags.isEmpty ? nil : item.tags.joined(separator: ", "))
        ]
        let rows: [[NSView]] = details.compactMap { label, value in
            guard let value else { return nil }
            let field = NSTextField(wrappingLabelWithString: value)
            field.isSelectable = true
            field.preferredMaxLayoutWidth = 320
            return [NSTextField(labelWithString: label), field]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 12
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize

        let alert = NSAlert()
        alert.messageText = item.name
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
