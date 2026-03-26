import SwiftUI

/// The main address bar component.
/// - Idle state: horizontal scrollable breadcrumb tokens (click or Cmd+L to edit).
/// - Editing state: NSTextField with path completion popover.
struct AddressBarView: View {
    @Bindable var vm: AddressBarViewModel
    let navigation: NavigationState
    let fsService: FileSystemService

    var body: some View {
        ZStack {
            // Background always visible
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            Color(nsColor: vm.isEditing ? .keyboardFocusIndicatorColor : .separatorColor),
                            lineWidth: vm.isEditing ? 2 : 0.5
                        )
                )

            if vm.isEditing {
                editingView
            } else {
                tokenView
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
    }

    // MARK: - Token (idle) view

    private var tokenView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let components = navigation.currentURL.pathComponentURLs
                ForEach(Array(components.enumerated()), id: \.element) { index, url in
                    PathTokenView(
                        url: url,
                        isLast: index == components.count - 1
                    ) { tapped in
                        navigation.navigate(to: tapped)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tap on the non-button area → enter edit mode
        .simultaneousGesture(
            TapGesture().onEnded {
                vm.beginEditing(from: navigation.currentURL)
            }
        )
    }

    // MARK: - Editing view

    private var editingView: some View {
        FocusedTextField(
            text: $vm.editText,
            placeholder: "/Users/…",
            onCommit: {
                Task {
                    if let url = await vm.commit(service: fsService) {
                        navigation.navigate(to: url)
                    }
                }
            },
            onCancel: {
                vm.cancel()
            },
            onTextChange: { text in
                vm.textDidChange(text, service: fsService)
            }
        )
        .padding(.horizontal, 8)
        .popover(isPresented: Binding(
            get: { !vm.completions.isEmpty },
            set: { if !$0 { vm.completions = [] } }
        ), arrowEdge: .bottom) {
            CompletionPopoverView(completions: vm.completions) { selected in
                vm.editText = selected.path + "/"
                vm.textDidChange(vm.editText, service: fsService)
            }
        }
    }
}
