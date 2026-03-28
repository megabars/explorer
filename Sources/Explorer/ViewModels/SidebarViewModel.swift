import Foundation
import Observation

@Observable
@MainActor
final class SidebarViewModel {
    var favorites: [SidebarItem]
    var volumeService = VolumeService.shared
    /// Cached availability for favorite items. Populated asynchronously to avoid main-thread I/O.
    private(set) var favoriteAvailability: [URL: Bool] = [:]

    private static let defaultsKey = "explorerFavorites"

    init() {
        favorites = Self.loadFavorites()
    }

    var volumes: [SidebarItem] { volumeService.volumes }

    /// Refreshes the availability of each favorite item off the main actor.
    func refreshFavoriteAvailability() async {
        var result: [URL: Bool] = [:]
        for item in favorites {
            result[item.url] = await FileSystemService.shared.exists(at: item.url)
        }
        favoriteAvailability = result
    }

    func isAvailable(_ item: SidebarItem) -> Bool {
        if item.section == .locations {
            return true
        }
        return favoriteAvailability[item.url] ?? false
    }

    func addFavorite(url: URL) {
        guard !favorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let item = SidebarItem(id: url, url: url, name: name, systemImage: "folder", section: .favorites)
        favorites.append(item)
        saveFavorites()
        Task { await refreshFavoriteAvailability() }
    }

    func removeFavorite(id: URL) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    // MARK: - Persistence

    private static func loadFavorites() -> [SidebarItem] {
        guard let paths = UserDefaults.standard.array(forKey: defaultsKey) as? [String], !paths.isEmpty else {
            return SidebarItem.defaults
        }
        var seen = Set<URL>()
        return paths.compactMap { path -> SidebarItem? in
            // Support both legacy .path format and .absoluteString format
            let url: URL
            if path.hasPrefix("file://") {
                guard let parsed = URL(string: path) else { return nil }
                url = parsed
            } else {
                url = URL(fileURLWithPath: path)
            }
            let key = url.standardizedFileURL
            guard seen.insert(key).inserted else { return nil }
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            let icon = defaultIcon(for: url)
            return SidebarItem(id: url, url: url, name: name, systemImage: icon, section: .favorites)
        }
    }

    private func saveFavorites() {
        // Use absoluteString for lossless URL round-trip (handles percent-encoded characters)
        let paths = favorites.map(\.url.absoluteString)
        UserDefaults.standard.set(paths, forKey: Self.defaultsKey)
    }

    private static func defaultIcon(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch url.standardizedFileURL {
        case home.standardizedFileURL: return "house"
        case home.appendingPathComponent("Desktop").standardizedFileURL: return "menubar.dock.rectangle"
        case home.appendingPathComponent("Documents").standardizedFileURL: return "doc"
        case home.appendingPathComponent("Downloads").standardizedFileURL: return "arrow.down.circle"
        default: return "folder"
        }
    }
}
