import SwiftUI

struct ContentView: View {
    @State private var navigation = NavigationState()
    @State private var browser = BrowserViewModel()
    @State private var sidebar = SidebarViewModel()
    @State private var addressBar = AddressBarViewModel()
    @State private var isSearching = false
    @State private var appKitCommandState = ExplorerCommand.AppKitState()

    private let fsService = FileSystemService.shared

    var body: some View {
        mainLayout
            .focusedSceneValue(\.explorerCommandContext, commandContext)
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.isEmpty, !ExplorerCommand.isEditingText,
                      browser.renamingItem == nil,
                      browser.selection.count == 1,
                      let item = browser.selectedItems.first else { return .ignored }
                browser.startRename(item)
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                guard isSearching, !ExplorerCommand.isEditingText else { return .ignored }
                closeFilter()
                return .handled
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAppKitCommandState()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refreshAppKitCommandState()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { notification in
                guard let window = notification.object as? NSWindow, window.isKeyWindow else { return }
                refreshAppKitCommandState()
            }
    }

    private var mainLayout: some View {
        NavigationSplitView {
            SidebarView(vm: sidebar, navigation: navigation)
        } detail: {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarView(query: $browser.searchQuery, onClose: closeFilter)
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

    private func closeFilter() {
        browser.searchQuery = ""
        isSearching = false
    }

    private var commandContext: ExplorerCommandContext {
        var commands: Set<ExplorerCommand> = [.editAddress, .filter]
        let hasDirectory = browser.loadError == nil
        if hasDirectory { commands.insert(.newFolder) }
        if let textCommands = appKitCommandState.textCommands {
            commands.formUnion(textCommands)
        } else {
            if !browser.selectedItems.isEmpty { commands.formUnion([.cut, .copy, .duplicate, .trash]) }
            if hasDirectory && browser.canPaste { commands.insert(.paste) }
            if !browser.sortedItems.isEmpty { commands.insert(.selectAll) }
            if browser.lastAction != nil { commands.insert(.undo) }
        }
        return ExplorerCommandContext(available: commands, perform: performCommand)
    }

    private func refreshAppKitCommandState() {
        let state = ExplorerCommand.appKitState()
        if state.pasteboardChangeCount != appKitCommandState.pasteboardChangeCount {
            browser.refreshClipboard()
        }
        if state != appKitCommandState { appKitCommandState = state }
    }

    private func performCommand(_ command: ExplorerCommand) {
        command.perform {
            switch command {
            case .newFolder: browser.newFolder(in: navigation.currentURL)
            case .editAddress: addressBar.beginEditing(from: navigation.currentURL)
            case .trash: browser.trash(navigation: navigation)
            case .cut: browser.cut()
            case .copy: browser.copy()
            case .paste: browser.paste(into: navigation.currentURL)
            case .duplicate: browser.duplicate()
            case .selectAll:
                let visible = browser.sortedItems
                browser.selection = Set(visible.map(\.url))
                if browser.lastSelectedURL.map({ !browser.selection.contains($0) }) ?? true {
                    browser.lastSelectedURL = visible.first?.url
                }
            case .undo: browser.undo()
            case .redo: break
            case .filter:
                if isSearching {
                    closeFilter()
                } else {
                    isSearching = true
                }
            }
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
