import AppKit
import Testing
@testable import Explorer

@Suite(.serialized)
@MainActor
struct GridRenameFieldTests {
    enum Completion: CaseIterable {
        case enter, escape, blur
    }

    @Test(arguments: Completion.allCases)
    func renameEditorTakesFocusAndFinishesOnce(_ completion: Completion) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let otherField = NSTextField(frame: NSRect(x: 0, y: 50, width: 100, height: 22))
        window.contentView?.addSubview(otherField)
        #expect(window.makeFirstResponder(otherField))

        var events: [Completion] = []
        var draft = "original.txt"
        let wrapper = FocusedTextField(
            text: draft,
            mode: .rename(onFocusLost: { events.append(.blur) }),
            showsPopover: false,
            focusRequest: 0,
            onCommit: { events.append(.enter) },
            onCancel: { events.append(.escape) },
            onTextChange: { draft = $0 }
        )
        let coordinator = wrapper.makeCoordinator()
        defer { withExtendedLifetime(coordinator) {} }
        let container = coordinator.makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
        window.contentView?.addSubview(container)
        await nextMainTurn()

        let editor = try #require(container.textField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 0, length: "original.txt".utf16.count))
        editor.insertText("new.txt", replacementRange: editor.selectedRange())
        #expect(draft == "new.txt")

        switch completion {
        case .enter:
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case .escape:
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case .blur:
            break
        }
        #expect(window.makeFirstResponder(otherField))
        await nextMainTurn()

        #expect(events == [completion])
        #expect(window.firstResponder === otherField.currentEditor())
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
