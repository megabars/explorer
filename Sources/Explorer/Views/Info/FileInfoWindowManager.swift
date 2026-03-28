import AppKit
import SwiftUI

@MainActor
final class FileInfoWindowManager {
    static let shared = FileInfoWindowManager()
    private init() {}

    private var openPanels: [URL: NSPanel] = [:]

    func showInfo(for url: URL) {
        let key = url.standardizedFileURL
        if let existing = openPanels[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = url.lastPathComponent
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FileInfoView(url: key))
        panel.center()

        let delegate = PanelCloseDelegate(url: key, manager: self)
        panel.delegate = delegate
        // Retain delegate — NSWindow.delegate is weak
        objc_setAssociatedObject(panel, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        openPanels[key] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    fileprivate func remove(url: URL) {
        openPanels.removeValue(forKey: url)
    }

    private static var delegateKey: UInt8 = 0
}

private final class PanelCloseDelegate: NSObject, NSWindowDelegate {
    let url: URL
    weak var manager: FileInfoWindowManager?

    init(url: URL, manager: FileInfoWindowManager) {
        self.url = url
        self.manager = manager
    }

    func windowWillClose(_ notification: Notification) {
        let u = url
        Task { @MainActor [weak manager] in
            manager?.remove(url: u)
        }
    }
}
