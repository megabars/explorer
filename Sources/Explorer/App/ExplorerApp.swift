import SwiftUI

@main
struct ExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Replace default New Window with New Folder
            CommandGroup(replacing: .newItem) {
                Button("New Folder") {
                    NotificationCenter.default.post(name: .newFolderRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Note: "Select All" (Cmd+A) is intentionally not overridden here.
            // NSTableView handles it natively via the AppKit responder chain.
        }
    }
}

extension Notification.Name {
    static let newFolderRequested = Notification.Name("newFolderRequested")
    static let renameRequestedForURL = Notification.Name("renameRequestedForURL")
}
