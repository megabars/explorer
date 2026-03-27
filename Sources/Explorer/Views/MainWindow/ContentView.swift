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
        // Cmd+Delete — move to trash
        .onKeyPress(.delete, phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            browser.trash(navigation: navigation)
            return .handled
        }
        // Return — start rename on the single selected item
        .onKeyPress(.return, phases: .down) { event in
            guard event.modifiers.isEmpty else { return .ignored }
            guard browser.renamingItem == nil,
                  browser.selection.count == 1,
                  let item = browser.selectedItems.first else { return .ignored }
            browser.startRename(item)
            return .handled
        }
        // Status bar
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        // Rename requested from context menu (list or grid view)
        .onReceive(NotificationCenter.default.publisher(for: .renameRequestedForURL)) { note in
            guard let url = note.userInfo?["url"] as? URL,
                  let item = browser.items.first(where: { $0.url == url }) else { return }
            browser.startRename(item)
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
