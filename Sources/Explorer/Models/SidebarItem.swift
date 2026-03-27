import Foundation
import AppKit

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

    static let defaults: [SidebarItem] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        let candidates: [(URL, String, String)] = [
            (home, "Home", "house"),
            (home.appendingPathComponent("Desktop"), "Desktop", "menubar.dock.rectangle"),
            (home.appendingPathComponent("Documents"), "Documents", "doc"),
            (home.appendingPathComponent("Downloads"), "Downloads", "arrow.down.circle"),
        ]
        var seen = Set<URL>()
        return candidates.compactMap { url, name, image -> SidebarItem? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            // Deduplicate by standardized URL to handle symlinks and relative-path aliases
            let key = url.standardizedFileURL
            guard seen.insert(key).inserted else { return nil }
            return SidebarItem(id: url, url: url, name: name, systemImage: image, section: .favorites)
        }
    }()
}
