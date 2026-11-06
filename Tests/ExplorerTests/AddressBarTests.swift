import AppKit
import Testing
@testable import Explorer

@Suite(.serialized)
@MainActor
struct AddressBarTests {
    @Test
    func testTabCompletesCurrentInputBeforeDebounceFires() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Old", "Projects", "Projects Archive"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }

        let service = FileSystemService()
        let addressBar = AddressBarViewModel()
        addressBar.beginEditing(from: root)
        addressBar.textDidChange(root.appendingPathComponent("Ol").path, service: service, showHidden: false)
        addressBar.textDidChange(root.appendingPathComponent("Proj").path, service: service, showHidden: false)
        await addressBar.completeUsingTab(service: service, showHidden: false)

        #expect(addressBar.editText.hasSuffix("/\(root.lastPathComponent)/Projects/"))
        #expect(addressBar.isEditing)

        let unmatchedPath = root.appendingPathComponent("Missing").path
        addressBar.textDidChange(unmatchedPath, service: service, showHidden: false)
        await addressBar.completeUsingTab(service: service, showHidden: false)
        #expect(addressBar.editText == unmatchedPath)
        #expect(addressBar.isEditing)
        addressBar.cancel()
    }

    @Test
    func testCommitClosesEditingAndResolvesAFileToItsParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("document.txt")
        try Data().write(to: file)

        let service = FileSystemService()
        let addressBar = AddressBarViewModel()
        addressBar.beginEditing(from: root)
        addressBar.textDidChange(file.path, service: service, showHidden: false)
        let destination = await addressBar.commit(service: service)
        #expect(destination?.path == root.path)
        #expect(!addressBar.isEditing)
        #expect(addressBar.completions.isEmpty)

        addressBar.beginEditing(from: root)
        addressBar.textDidChange("", service: service, showHidden: false)
        let emptyDestination = await addressBar.commit(service: service)
        #expect(emptyDestination == nil)
        #expect(!addressBar.isEditing)
    }

    @Test
    func testFieldConsumesTabAndFinishesOnlyOnce() {
        let field = NSTextField()
        let editor = NSTextView()
        var actions: [String] = []
        let wrapper = FocusedTextField(
            text: "/",
            showsPopover: false,
            focusRequest: 0,
            onCommit: { actions.append("commit") },
            onCancel: { actions.append("cancel") },
            onTab: { actions.append("tab") },
            onTextChange: { _ in }
        )
        let coordinator = wrapper.makeCoordinator()
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(actions == ["tab", "commit"])

        let nextCoordinator = wrapper.makeCoordinator()
        #expect(nextCoordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        nextCoordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(actions == ["tab", "commit", "cancel"])
    }

    @Test
    func testCompletionUpdatesTheActiveFieldEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
        field.stringValue = "/tmp/Pro"
        window.contentView?.addSubview(field)

        var changes: [String] = []
        let wrapper = FocusedTextField(
            text: "/tmp/Projects/",
            showsPopover: false,
            focusRequest: 0,
            onCommit: {},
            onCancel: {},
            onTab: {},
            onTextChange: { changes.append($0) }
        )
        let coordinator = wrapper.makeCoordinator()
        field.delegate = coordinator
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)

        coordinator.updateText(in: field)
        #expect(window.firstResponder === editor)
        #expect(editor.string == "/tmp/Projects/")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
        #expect(changes.isEmpty)

        editor.insertText("Next", replacementRange: editor.selectedRange())
        #expect(changes == ["/tmp/Projects/Next"])
    }
}
