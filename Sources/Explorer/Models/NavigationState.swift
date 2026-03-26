import Foundation
import Observation

@Observable
@MainActor
final class NavigationState {
    var currentURL: URL
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    private(set) var history: [URL] = []

    init(startURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = startURL
    }

    func navigate(to url: URL) {
        guard url != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
        if !history.contains(url) {
            history.insert(url, at: 0)
            if history.count > 50 { history.removeLast() }
        }
    }

    func goBack() {
        guard !backStack.isEmpty else { return }
        forwardStack.append(currentURL)
        currentURL = backStack.removeLast()
    }

    func goForward() {
        guard !forwardStack.isEmpty else { return }
        backStack.append(currentURL)
        currentURL = forwardStack.removeLast()
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent != currentURL else { return }
        navigate(to: parent)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.pathComponents.count > 1 }
}
