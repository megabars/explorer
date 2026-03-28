import SwiftUI
import AppKit

/// Container that centers the NSTextField vertically on every layout pass.
class TextFieldContainer: NSView {
    let textField = NSTextField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField.isBordered = false
        textField.isBezeled = false
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = textField.fittingSize.height
        let y = (bounds.height - h) / 2
        textField.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
    }
}

/// Wraps NSTextField to give full control over first-responder, Tab completion,
/// and Return/Escape key handling — things SwiftUI's TextField cannot do.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TextFieldContainer {
        let container = TextFieldContainer()
        let field = container.textField
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        context.coordinator.field = field
        return container
    }

    func updateNSView(_ container: TextFieldContainer, context: Context) {
        let field = container.textField
        if field.stringValue != text {
            field.stringValue = text
        }
        guard !context.coordinator.didBecomeFirstResponder else { return }
        context.coordinator.didBecomeFirstResponder = true
        DispatchQueue.main.async {
            guard field.superview != nil, let window = field.window else { return }
            window.makeFirstResponder(field)
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
            let raw = field.stringValue
            let value = raw.unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .reduce(into: "") { $0.append(Character($1)) }
            if value != raw { field.stringValue = value }
            parent.text = value
            parent.onTextChange(value)
        }

        /// Tracks whether onCommit or onCancel was already called for the current editing session,
        /// preventing the duplicate call from controlTextDidEndEditing after doCommandBy.
        var didFinishEditing = false

        func controlTextDidEndEditing(_ obj: Notification) {
            didBecomeFirstResponder = false
            guard !didFinishEditing else {
                didFinishEditing = false
                return
            }
            parent.onCancel()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didFinishEditing = true
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didFinishEditing = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
