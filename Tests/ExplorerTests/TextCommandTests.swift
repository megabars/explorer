import AppKit
import Testing
@testable import Explorer

@Suite(.serialized)
@MainActor
struct TextCommandTests {
    @Test
    func testEditCommandsUseTheTextEditorBeforeTheWindowAction() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = RecordingEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))

        let undoManager = editor.testUndoManager
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: editor) { target in
            MainActor.assumeIsolated { target.actions.append("undo") }
        }
        undoManager.endUndoGrouping()

        var fileActions: [ExplorerCommand] = []
        let commands: [ExplorerCommand] = [.cut, .copy, .paste, .undo]
        commands.forEach { command in command.perform(in: window) { fileActions.append(command) } }
        #expect(editor.actions == ["cut", "copy", "paste", "undo"])
        #expect(fileActions.isEmpty)

        window.makeFirstResponder(nil)
        commands.forEach { command in command.perform(in: window) { fileActions.append(command) } }
        #expect(fileActions == commands)
    }
}

@MainActor
private final class RecordingEditor: NSTextView {
    var actions: [String] = []
    let testUndoManager = UndoManager()

    override var undoManager: UndoManager? { testUndoManager }
    override func cut(_ sender: Any?) { actions.append("cut") }
    override func copy(_ sender: Any?) { actions.append("copy") }
    override func paste(_ sender: Any?) { actions.append("paste") }
}

