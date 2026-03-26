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
        return [
            SidebarItem(
                id: home,
                url: home,
                name: "Home",
                systemImage: "house",
                section: .favorites
            ),
            SidebarItem(
                id: home.appendingPathComponent("Desktop"),
                url: home.appendingPathComponent("Desktop"),
                name: "Desktop",
                systemImage: "menubar.dock.rectangle",
                section: .favorites
            ),
            SidebarItem(
                id: home.appendingPathComponent("Documents"),
                url: home.appendingPathComponent("Documents"),
                name: "Documents",
                systemImage: "doc",
                section: .favorites
            ),
            SidebarItem(
                id: home.appendingPathComponent("Downloads"),
                url: home.appendingPathComponent("Downloads"),
                name: "Downloads",
                systemImage: "arrow.down.circle",
                section: .favorites
            ),
        ]
    }()
}
