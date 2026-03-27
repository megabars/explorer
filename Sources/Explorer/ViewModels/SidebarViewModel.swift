import Foundation
import Observation

@Observable
@MainActor
final class SidebarViewModel {
    var favorites: [SidebarItem] = SidebarItem.defaults
    var volumeService = VolumeService.shared
    /// Cached availability for favorite items. Populated asynchronously to avoid main-thread I/O.
    private(set) var favoriteAvailability: [URL: Bool] = [:]

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
            // Volumes from VolumeService are always mounted (they came from mountedVolumeURLs).
            return true
        }
        // Pessimistic default (false) until the first async check completes —
        // avoids briefly showing unavailable paths as clickable on cold start.
        return favoriteAvailability[item.url] ?? false
    }
}
