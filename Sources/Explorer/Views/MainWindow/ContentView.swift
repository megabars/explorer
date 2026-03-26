import SwiftUI

struct ContentView: View {
    @State private var navigation = NavigationState()
    @State private var browser = BrowserViewModel()
    @State private var sidebar = SidebarViewModel()
    @State private var addressBar = AddressBarViewModel()

    private let fsService = FileSystemService.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: sidebar, navigation: navigation)
        } detail: {
            BrowserContainerView(browser: browser, navigation: navigation)
                .navigationTitle(navigation.currentURL.lastPathComponent)
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
        // Cmd+L — focus address bar
        .onKeyPress(.init("l"), phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            addressBar.beginEditing(from: navigation.currentURL)
            return .handled
        }
        // Cmd+Shift+N — new folder
        .onKeyPress(.init("n"), phases: .down) { event in
            guard event.modifiers.contains([.command, .shift]) else { return .ignored }
            browser.newFolder(in: navigation.currentURL)
            return .handled
        }
        // Delete — move to trash
        .onKeyPress(.delete, phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            browser.trash(navigation: navigation)
            return .handled
        }
        // Status bar
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        // Error alert
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
        let total = browser.items.count
        let selected = browser.selection.count
        if selected > 0 {
            return "\(selected) of \(total) selected"
        }
        return "\(total) item\(total == 1 ? "" : "s")"
    }
}
