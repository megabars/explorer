import Foundation

struct SidebarItem: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let systemImage: String
    let section: Section

    enum Section: String, Sendable {
        case favorites = "Favorites"
        case locations = "Locations"
    }

    private static let builtInFavorites: [(url: URL, name: String, image: String)] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home, L10n.text("Home"), "house"),
            (home.appendingPathComponent("Desktop"), L10n.text("Desktop"), "menubar.dock.rectangle"),
            (home.appendingPathComponent("Documents"), L10n.text("Documents"), "doc"),
            (home.appendingPathComponent("Downloads"), L10n.text("Downloads"), "arrow.down.circle"),
        ]
    }()

    static let defaults: [SidebarItem] = {
        let fm = FileManager.default
        var seen = Set<URL>()
        return builtInFavorites.compactMap { url, name, image -> SidebarItem? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            // Deduplicate by standardized URL to handle symlinks and relative-path aliases
            let key = url.standardizedFileURL
            guard seen.insert(key).inserted else { return nil }
            return SidebarItem(id: url, url: url, name: name, systemImage: image, section: .favorites)
        }
    }()

    static func favorite(at url: URL) -> SidebarItem {
        let path = url.standardizedFileURL.path
        let builtIn = builtInFavorites.first { $0.url.standardizedFileURL.path == path }
        let name = builtIn?.name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        return SidebarItem(id: url, url: url, name: name, systemImage: builtIn?.image ?? "folder", section: .favorites)
    }
}
