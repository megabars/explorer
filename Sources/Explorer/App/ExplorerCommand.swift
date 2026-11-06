import AppKit
import SwiftUI

private struct ExplorerCommandContextKey: FocusedValueKey {
    typealias Value = ExplorerCommandContext
}

extension FocusedValues {
    var explorerCommandContext: ExplorerCommandContext? {
        get { self[ExplorerCommandContextKey.self] }
        set { self[ExplorerCommandContextKey.self] = newValue }
    }
}

struct ExplorerCommandContext {
    let available: Set<ExplorerCommand>
    let perform: @MainActor (ExplorerCommand) -> Void
}

@MainActor
enum ExplorerCommand: Hashable {
    case newFolder, editAddress, trash, cut, copy, paste, duplicate, selectAll, undo, redo, filter

    struct AppKitState: Equatable {
        var textCommands: Set<ExplorerCommand>?
        var pasteboardChangeCount: Int?
    }

    static var isEditingText: Bool {
        textEditor(in: NSApp?.keyWindow) != nil
    }

    func perform(in window: NSWindow? = NSApp?.keyWindow, fileAction: () -> Void) {
        if let editor = Self.textEditor(in: window) {
            switch self {
            case .cut: editor.cut(nil)
            case .copy: editor.copy(nil)
            case .paste: editor.paste(nil)
            case .selectAll: editor.selectAll(nil)
            case .undo: editor.undoManager?.undo()
            case .redo: editor.undoManager?.redo()
            case .duplicate, .trash: break
            case .newFolder, .editAddress, .filter: fileAction()
            }
        } else if self != .redo {
            fileAction()
        }
    }

    static func appKitState(in window: NSWindow? = NSApp?.keyWindow, pasteboard: NSPasteboard = .general) -> AppKitState {
        var state = AppKitState(pasteboardChangeCount: pasteboard.changeCount)
        guard let editor = textEditor(in: window) else { return state }
        var commands: Set<ExplorerCommand> = []
        if editor.isSelectable && !editor.string.isEmpty { commands.insert(.selectAll) }
        if editor.selectedRange().length > 0 {
            commands.insert(.copy)
            if editor.isEditable { commands.insert(.cut) }
        }
        if editor.isEditable && pasteboard.availableType(from: editor.readablePasteboardTypes) != nil {
            commands.insert(.paste)
        }
        if editor.undoManager?.canUndo == true { commands.insert(.undo) }
        if editor.undoManager?.canRedo == true { commands.insert(.redo) }
        state.textCommands = commands
        return state
    }

    private static func textEditor(in window: NSWindow?) -> NSTextView? {
        let responder = window?.firstResponder
        return (responder as? NSTextView)
            ?? ((responder as? NSTextField)?.currentEditor() as? NSTextView)
    }
}
