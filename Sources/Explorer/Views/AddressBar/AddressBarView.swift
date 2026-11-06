import SwiftUI

/// The main address bar component.
/// - Idle state: horizontal scrollable breadcrumb tokens (click or Cmd+L to edit).
/// - Editing state: NSTextField with path completion popover.
struct AddressBarView: View {
    let vm: AddressBarViewModel
    let navigation: NavigationState
    let fsService: FileSystemService
    let showHidden: Bool
    @State private var focusRequest = 0

    var body: some View {
        ZStack {
            if vm.isEditing {
                editingView
            } else {
                tokenView
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .onChange(of: navigation.revision) { _, _ in
            if vm.isEditing { vm.cancel() }
        }
    }

    // MARK: - Token (idle) view

    private var tokenView: some View {
        ScrollViewReader { proxy in
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
                        .id(index == components.count - 1 ? "last" : url.path)
                    }
                }
                .padding(.horizontal, 6)
            }
            // clipped() prevents the ScrollView's content size from leaking into the toolbar
            // item measurement, which would cause NSToolbar to push items into >> overflow.
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: navigation.currentURL) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("last", anchor: .trailing)
                }
            }
            .onAppear {
                proxy.scrollTo("last", anchor: .trailing)
            }
        }
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
            text: vm.editText,
            placeholder: "/Users/…",
            showsPopover: vm.commitError != nil || !vm.completions.isEmpty,
            focusRequest: focusRequest,
            onCommit: {
                let revision = navigation.revision
                Task {
                    guard navigation.revision == revision else { return }
                    let url = await vm.commit(service: fsService, isCurrent: { navigation.revision == revision })
                    guard navigation.revision == revision else { return }
                    if let url {
                        navigation.navigate(to: url)
                    } else if vm.commitError != nil {
                        focusRequest += 1
                    }
                }
            },
            onCancel: {
                vm.cancel()
            },
            onTab: {
                Task {
                    await vm.completeUsingTab(service: fsService, showHidden: showHidden)
                }
            },
            onTextChange: { text in
                vm.textDidChange(text, service: fsService, showHidden: showHidden)
            }
        )
        .padding(.horizontal, 8)
        .popover(isPresented: Binding(
            get: { vm.commitError != nil || !vm.completions.isEmpty },
            set: {
                if !$0 {
                    vm.dismissCompletions()
                    vm.dismissError()
                }
            }
        ), arrowEdge: .bottom) {
            Group {
                if let error = vm.commitError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .padding(10)
                } else {
                    CompletionPopoverView(completions: vm.completions) { selected in
                        if vm.selectCompletion(selected, service: fsService, showHidden: showHidden) {
                            focusRequest += 1
                        }
                    }
                }
            }
            .onExitCommand { vm.cancel() }
        }
    }
}
