import SwiftUI

struct ContentView: View {
    @State private var navigation = NavigationState()
    @State private var browser = BrowserViewModel()
    @State private var sidebar = SidebarViewModel()
    @State private var addressBar = AddressBarViewModel()
    @State private var isSearching = false

    private let fsService = FileSystemService.shared

    var body: some View {
        mainLayout
            .withKeyboardShortcuts(browser: browser, navigation: navigation, addressBar: addressBar, isSearching: $isSearching)
            .withNotificationHandlers(browser: browser, navigation: navigation, isSearching: $isSearching)
    }

    private var mainLayout: some View {
        NavigationSplitView {
            SidebarView(vm: sidebar, navigation: navigation)
        } detail: {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarView(query: $browser.searchQuery) {
                        browser.searchQuery = ""
                        isSearching = false
                    }
                    Divider()
                }
                BrowserContainerView(browser: browser, navigation: navigation, sidebar: sidebar)
                    .navigationTitle(navigation.currentURL.lastPathComponent)
            }
        }
        .toolbar {
            ExplorerToolbar(
                navigation: navigation,
                browser: browser,
                addressBar: addressBar,
                fsService: fsService
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
        .safeAreaInset(edge: .bottom) { statusBar }
        .alert("Error", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("OK") { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var statusText: String {
        if let error = browser.errorMessage {
            return "Error: \(error)"
        }
        let total = browser.sortedItems.count
        let selected = browser.selection.count
        if selected > 0 {
            return "\(selected) of \(total) selected"
        }
        if !browser.searchQuery.isEmpty {
            return "\(total) result\(total == 1 ? "" : "s")"
        }
        return "\(total) item\(total == 1 ? "" : "s")"
    }
}

// MARK: - View modifiers extracted to reduce type-checker load

private extension View {
    func withKeyboardShortcuts(
        browser: BrowserViewModel,
        navigation: NavigationState,
        addressBar: AddressBarViewModel,
        isSearching: Binding<Bool>
    ) -> some View {
        self
            .onKeyPress(.init("l"), phases: .down) { event in
                guard event.modifiers.contains(.command) else { return .ignored }
                addressBar.beginEditing(from: navigation.currentURL)
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { event in
                guard event.modifiers.contains(.command) else { return .ignored }
                browser.trash(navigation: navigation)
                return .handled
            }
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.isEmpty else { return .ignored }
                guard browser.renamingItem == nil,
                      browser.selection.count == 1,
                      let item = browser.selectedItems.first else { return .ignored }
                browser.startRename(item)
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { event in
                guard isSearching.wrappedValue else { return .ignored }
                browser.searchQuery = ""
                isSearching.wrappedValue = false
                return .handled
            }
    }

    func withNotificationHandlers(
        browser: BrowserViewModel,
        navigation: NavigationState,
        isSearching: Binding<Bool>
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .newFolderRequested)) { _ in
                browser.newFolder(in: navigation.currentURL)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutRequested)) { _ in
                browser.cut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyRequested)) { _ in
                browser.copy()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteRequested)) { _ in
                browser.pasteFromSystemPasteboard(into: navigation.currentURL)
            }
            .onReceive(NotificationCenter.default.publisher(for: .duplicateRequested)) { _ in
                browser.duplicate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .filterRequested)) { _ in
                if isSearching.wrappedValue {
                    browser.searchQuery = ""
                    isSearching.wrappedValue = false
                } else {
                    isSearching.wrappedValue = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .undoRequested)) { _ in
                browser.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllRequested)) { _ in
                browser.selectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goBackRequested)) { _ in
                navigation.goBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goForwardRequested)) { _ in
                navigation.goForward()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goUpRequested)) { _ in
                navigation.goUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSelectedRequested)) { _ in
                for item in browser.selectedItems {
                    browser.open(item, navigation: navigation)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameRequestedForURL)) { note in
                guard let url = note.userInfo?["url"] as? URL,
                      let item = browser.items.first(where: { $0.url == url }) else { return }
                browser.startRename(item)
            }
            .onReceive(NotificationCenter.default.publisher(for: .getInfoRequested)) { _ in
                for url in browser.selection {
                    FileInfoWindowManager.shared.showInfo(for: url)
                }
            }
    }
}
