import Foundation
import Observation

@Observable
@MainActor
final class NavigationState {
    var currentURL: URL
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    init(startURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = startURL
    }

    func navigate(to url: URL) {
        guard url != currentURL else { return }
        // Group all three mutations together — @MainActor serialises execution so observers
        // see a consistent snapshot after the current turn of the run loop.
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
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
        let parent = currentURL.deletingLastPathComponent().standardized
        guard parent != currentURL.standardized else { return }
        navigate(to: parent)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.pathComponents.count > 1 }
}
