import AppKit
import Observation

@Observable
@MainActor
final class VolumeService {
    static let shared = VolumeService()
    private(set) var volumes: [SidebarItem] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        let mounted = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let unmounted = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers = [mounted, unmounted]
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            // mountedVolumeURLs() returned nil — keep the existing volume list rather than clearing it
            print("[VolumeService] mountedVolumeURLs returned nil; retaining previous volume list")
            return
        }

        volumes = urls.compactMap { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            let isRemovable = (try? url.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) ?? false
            let image = isRemovable ? "externaldrive" : "internaldrive"
            return SidebarItem(id: url, url: url, name: name, systemImage: image, section: .locations)
        }
    }

    // VolumeService is a singleton — observers live for the app lifetime.
}
