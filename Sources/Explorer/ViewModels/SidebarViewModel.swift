import Foundation
import Observation

@Observable
@MainActor
final class SidebarViewModel {
    var favorites: [SidebarItem] = SidebarItem.defaults
    var volumeService = VolumeService.shared

    var volumes: [SidebarItem] { volumeService.volumes }
}
