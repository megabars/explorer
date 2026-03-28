import SwiftUI

struct BrowserContainerView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState
    let sidebar: SidebarViewModel

    var body: some View {
        ZStack {
            if browser.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = browser.errorMessage {
                errorView(message: error)
            } else if browser.sortedItems.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: navigation.currentURL) { _, newURL in
            browser.load(url: newURL)
        }
        .onAppear {
            browser.load(url: navigation.currentURL)
        }
        .onDisappear {
            browser.stopWatching()
        }
        // Delete key is handled at ContentView level (Cmd+Delete → trash) to avoid
        // duplicate firing when both this view and ContentView receive the event.
    }

    @ViewBuilder
    private var contentView: some View {
        switch browser.viewMode {
        case .list:
            FileListView(browser: browser, navigation: navigation, sidebar: sidebar)
        case .icons:
            FileGridView(browser: browser, navigation: navigation, sidebar: sidebar)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Empty Folder")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                browser.errorMessage = nil
                browser.load(url: navigation.currentURL)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
