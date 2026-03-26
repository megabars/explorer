import SwiftUI

struct BrowserContainerView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState

    var body: some View {
        ZStack {
            if browser.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = browser.errorMessage {
                errorView(message: error)
            } else if browser.items.isEmpty {
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
        // Keyboard shortcuts
        .onKeyPress(.delete, action: {
            browser.trash(navigation: navigation)
            return .handled
        })
    }

    @ViewBuilder
    private var contentView: some View {
        switch browser.viewMode {
        case .list:
            FileListView(browser: browser, navigation: navigation)
        case .icons:
            FileGridView(browser: browser, navigation: navigation)
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
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
