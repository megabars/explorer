import SwiftUI
import AppKit

/// Wraps NSTextField to give full control over first-responder, Tab completion,
/// and Return/Escape key handling — things SwiftUI's TextField cannot do.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Become first responder only once when the view first appears
        guard !context.coordinator.didBecomeFirstResponder else { return }
        context.coordinator.didBecomeFirstResponder = true
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        weak var field: NSTextField?
        var didBecomeFirstResponder = false

        init(_ parent: FocusedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            parent.text = value
            parent.onTextChange(value)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCancel()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
