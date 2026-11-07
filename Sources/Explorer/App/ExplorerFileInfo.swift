import AppKit

@MainActor
enum ExplorerFileInfo {
    static func show(for item: FileItem, in window: NSWindow? = NSApp?.keyWindow) {
        guard let window else { return }
        let dateFormat = Date.FormatStyle(date: .long, time: .shortened).locale(L10n.locale)
        let details: [(String, String?)] = [
            (L10n.text("Kind"), item.kind),
            (L10n.text("Where"), item.url.deletingLastPathComponent().path),
            (L10n.text("Size"), item.isDirectory ? nil : item.fileSize.map(FileSizeFormatter.string(fromByteCount:))),
            (L10n.text("Created"), item.creationDate?.formatted(dateFormat)),
            (L10n.text("Modified"), item.contentModificationDate?.formatted(dateFormat)),
            (L10n.text("Tags"), item.tags.isEmpty ? nil : item.tags.joined(separator: ", "))
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
        alert.addButton(withTitle: L10n.text("OK"))
        alert.beginSheetModal(for: window)
    }
}
