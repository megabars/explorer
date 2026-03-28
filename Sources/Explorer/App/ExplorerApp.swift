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
            // Override system clipboard commands for file operations.
            // AppKit intercepts Cmd+C/V/X via the responder chain before SwiftUI onKeyPress,
            // so we must replace them at the Commands level.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NotificationCenter.default.post(name: .cutRequested, object: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                Button("Copy") {
                    NotificationCenter.default.post(name: .copyRequested, object: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    NotificationCenter.default.post(name: .pasteRequested, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Duplicate") {
                    NotificationCenter.default.post(name: .duplicateRequested, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
            // Undo
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoRequested, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
            }
            // Override Find to open our filter bar instead of the system Find panel.
            CommandGroup(replacing: .textEditing) {
                Button("Filter") {
                    NotificationCenter.default.post(name: .filterRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // Note: "Select All" (Cmd+A) is intentionally not overridden here.
            // NSTableView handles it natively via the AppKit responder chain.
        }
    }
}

extension Notification.Name {
    static let newFolderRequested = Notification.Name("newFolderRequested")
    static let renameRequestedForURL = Notification.Name("renameRequestedForURL")
    static let cutRequested = Notification.Name("cutRequested")
    static let copyRequested = Notification.Name("copyRequested")
    static let pasteRequested = Notification.Name("pasteRequested")
    static let duplicateRequested = Notification.Name("duplicateRequested")
    static let filterRequested = Notification.Name("filterRequested")
    static let undoRequested = Notification.Name("undoRequested")
}
