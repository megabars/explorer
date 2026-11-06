import SwiftUI
import AppKit

/// Container that centers the NSTextField vertically on every layout pass.
class TextFieldContainer: NSView {
    let textField = NSTextField()
    var onWindowAttached: (() -> Void)?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }

    override func layout() {
        super.layout()
        let h = textField.fittingSize.height
        let y = (bounds.height - h) / 2
        textField.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
    }
}

/// Owns the AppKit field editor for address entry and inline icon rename.
struct FocusedTextField: NSViewRepresentable {
    enum Mode {
        case address
        case rename(onFocusLost: () -> Void)
    }

    var text: String
    var placeholder: String = ""
    var mode: Mode = .address
    var showsPopover: Bool
    var focusRequest: Int
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onTab: (() -> Void)?
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TextFieldContainer {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ container: TextFieldContainer, context: Context) {
        let coordinator = context.coordinator
        let field = container.textField
        let restoringFocus = coordinator.parent.focusRequest != focusRequest
        coordinator.parent = self
        coordinator.updateText(in: field)
        if !coordinator.didRequestFocus || restoringFocus {
            coordinator.requestFocus(placeCursorAtEnd: restoringFocus)
        } else {
            coordinator.finishIfFocusLost()
        }
    }

    static func dismantleNSView(_ container: TextFieldContainer, coordinator: Coordinator) {
        container.onWindowAttached = nil
        container.textField.delegate = nil
        coordinator.field = nil
    }

    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        weak var field: NSTextField?
        private(set) var didRequestFocus = false
        private var lostFocus = false
        private var isUpdatingText = false
        private var didFinishEditing = false
        private var commitRequested = false
        private var endedText: String?

        init(_ parent: FocusedTextField) {
            self.parent = parent
        }

        func makeContainer() -> TextFieldContainer {
            let container = TextFieldContainer()
            let field = container.textField
            field.placeholderString = parent.placeholder
            field.stringValue = parent.text
            if case .rename = parent.mode {
                field.isBezeled = true
                field.bezelStyle = .roundedBezel
                field.drawsBackground = true
                field.backgroundColor = .textBackgroundColor
                field.focusRingType = .default
                field.alignment = .center
                field.font = .systemFont(ofSize: 11)
            }
            field.delegate = self
            self.field = field
            container.onWindowAttached = { [weak self] in
                guard let self, !didRequestFocus else { return }
                requestFocus(placeCursorAtEnd: false)
            }
            return container
        }

        func updateText(in field: NSTextField) {
            if let editor = field.currentEditor() as? NSTextView {
                guard editor.string != parent.text else { return }
                isUpdatingText = true
                defer { isUpdatingText = false }
                editor.insertText(
                    parent.text,
                    replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
                )
            } else if field.stringValue != parent.text {
                field.stringValue = parent.text
            }
        }

        func requestFocus(placeCursorAtEnd: Bool) {
            didRequestFocus = true
            lostFocus = false
            commitRequested = false
            DispatchQueue.main.async { [weak self] in
                guard let self, !didFinishEditing, let field else { return }
                guard let window = field.window else {
                    didRequestFocus = false
                    return
                }
                if field.currentEditor() == nil {
                    guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return }
                    if placeCursorAtEnd {
                        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
                    } else if case .rename = parent.mode {
                        editor.selectAll(nil)
                    }
                }
            }
        }

        func finishIfFocusLost() {
            guard lostFocus, !parent.showsPopover, !didFinishEditing else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, lostFocus, !parent.showsPopover, let field,
                      field.currentEditor() == nil else { return }
                switch parent.mode {
                case .address:
                    finishEditing(parent.onCancel)
                case .rename(let onFocusLost):
                    finishEditing {
                        parent.onTextChange(endedText ?? field.stringValue)
                        onFocusLost()
                    }
                }
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            lostFocus = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdatingText, !didFinishEditing, let field = notification.object as? NSTextField else { return }
            commitRequested = false
            let raw = field.currentEditor()?.string ?? field.stringValue
            if case .rename = parent.mode {
                parent.onTextChange(raw)
                return
            }
            let value = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            if value != raw { field.stringValue = value }
            parent.onTextChange(value)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Clicking a suggestion can move focus into the popover before its action runs.
            // Wait for dismissal or an explicit focus request from the selection.
            lostFocus = true
            if case .rename = parent.mode {
                endedText = (notification.object as? NSTextField)?.stringValue
            }
            finishIfFocusLost()
        }

        private func finishEditing(_ action: () -> Void) {
            guard !didFinishEditing else { return }
            didFinishEditing = true
            action()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                guard let onTab = parent.onTab else { return false }
                if !didFinishEditing {
                    commitRequested = false
                    onTab()
                }
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if case .rename = parent.mode {
                    finishEditing {
                        parent.onTextChange(textView.string)
                        parent.onCommit()
                    }
                    return true
                }
                if !didFinishEditing, !commitRequested {
                    commitRequested = true
                    parent.onCommit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finishEditing(parent.onCancel)
                return true
            default:
                return false
            }
        }
    }
}
