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

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All") {
                    // handled by NSTableView default behaviour
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let newFolderRequested = Notification.Name("newFolderRequested")
}
