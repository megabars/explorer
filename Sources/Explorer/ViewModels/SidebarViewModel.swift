import Foundation
import Observation

@Observable
@MainActor
final class SidebarViewModel {
    private(set) var favorites: [SidebarItem]
    var volumeService = VolumeService.shared
    /// Cached availability for favorite items. Populated asynchronously to avoid main-thread I/O.
    private(set) var favoriteAvailability: [URL: Bool] = [:]

    private static let defaultsKey = "explorerFavorites"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.loadFavorites(from: defaults)
    }

    var volumes: [SidebarItem] { volumeService.volumes }

    /// Refreshes the availability of each favorite item off the main actor.
    func refreshFavoriteAvailability() async {
        let snapshot = favorites
        var result: [URL: Bool] = [:]
        for item in snapshot {
            guard !Task.isCancelled else { return }
            result[item.url] = await FileSystemService.shared.itemStatus(at: item.url).isDirectory
        }
        guard !Task.isCancelled, favorites.map(\.id) == snapshot.map(\.id) else { return }
        favoriteAvailability = result
    }

    func refreshAvailability(for item: SidebarItem) async -> Bool {
        let available = await FileSystemService.shared.itemStatus(at: item.url).isDirectory
        guard !Task.isCancelled, favorites.contains(where: { $0.id == item.id }) else { return false }
        favoriteAvailability[item.url] = available
        return available
    }

    func isAvailable(_ item: SidebarItem) -> Bool {
        if item.section == .locations {
            return true
        }
        return favoriteAvailability[item.url] ?? false
    }

    func addFavorite(url: URL) {
        let path = url.standardizedFileURL.path
        guard !favorites.contains(where: { $0.url.standardizedFileURL.path == path }) else { return }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let item = SidebarItem(id: url, url: url, name: name, systemImage: "folder", section: .favorites)
        favorites.append(item)
        saveFavorites()
    }

    func removeFavorite(id: URL) {
        if let item = favorites.first(where: { $0.id == id }) {
            favoriteAvailability.removeValue(forKey: item.url)
        }
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    // MARK: - Persistence

    private static func loadFavorites(from defaults: UserDefaults) -> [SidebarItem] {
        guard let paths = defaults.array(forKey: defaultsKey) as? [String] else {
            return SidebarItem.defaults
        }
        var seen = Set<String>()
        return paths.compactMap { path -> SidebarItem? in
            // Support both legacy .path format and .absoluteString format
            let url: URL
            if path.hasPrefix("file://") {
                guard let parsed = URL(string: path) else { return nil }
                url = parsed
            } else {
                url = URL(fileURLWithPath: path)
            }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return nil }
            let icon = defaultIcon(for: url)
            let name = icon == "house" ? "Home" : (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            return SidebarItem(id: url, url: url, name: name, systemImage: icon, section: .favorites)
        }
    }

    private func saveFavorites() {
        // Use absoluteString for lossless URL round-trip (handles percent-encoded characters)
        let paths = favorites.map(\.url.absoluteString)
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    private static func defaultIcon(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch url.standardizedFileURL.path {
        case home.standardizedFileURL.path: return "house"
        case home.appendingPathComponent("Desktop").standardizedFileURL.path: return "menubar.dock.rectangle"
        case home.appendingPathComponent("Documents").standardizedFileURL.path: return "doc"
        case home.appendingPathComponent("Downloads").standardizedFileURL.path: return "arrow.down.circle"
        default: return "folder"
        }
    }
}
