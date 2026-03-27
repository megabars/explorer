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
            // Guard against the view being removed from the hierarchy before the
            // async block executes (e.g. address bar dismissed very quickly).
            guard nsView.superview != nil, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
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
            // Strip control characters (U+0000–U+001F, U+007F) to prevent injection via paste
            let raw = field.stringValue
            let value = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .reduce(into: "") { $0.append(Character($1)) }
            if value != raw {
                field.stringValue = value
            }
            parent.text = value
            parent.onTextChange(value)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Reset so that makeFirstResponder fires again the next time the address bar opens.
            didBecomeFirstResponder = false
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
