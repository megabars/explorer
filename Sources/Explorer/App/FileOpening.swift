import AppKit

@MainActor
enum FileOpening {
    static func open(_ url: URL, onError: @escaping @MainActor (String) -> Void) {
        guard NSWorkspace.shared.open(url) else {
            onError("Could not open “\(url.lastPathComponent)”. Check that the item exists and an application is available.")
            return
        }
    }

    static func open(_ urls: [URL], with application: URL, onError: @escaping @MainActor (String) -> Void) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) { _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in onError(message) }
        }
    }

    static func openTerminal(at url: URL, onError: @escaping @MainActor (String) -> Void) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            onError("Terminal is not available.")
            return
        }
        open([url], with: terminal, onError: onError)
    }
}
