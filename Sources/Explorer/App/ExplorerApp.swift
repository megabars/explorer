import SwiftUI

@main
enum ExplorerEntryPoint {
    @MainActor
    static func main() {
        // Repair an invalid app preference before SwiftUI starts AppKit.
        LanguagePreferences().removeInvalidOverride()
        _ = L10n.launchSelection
        ExplorerApp.main()
    }
}

struct ExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { ExplorerCommands() }

        Settings {
            SettingsView()
                .environment(\.locale, L10n.locale)
        }
    }
}

private struct ExplorerCommands: Commands {
    @FocusedValue(\.explorerCommandContext) private var context

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command("New Folder", .newFolder, key: "n", modifiers: [.command, .shift])
            command("Go to Folder…", .editAddress, key: "l")
            command("Move to Trash", .trash, key: .delete)
        }
        CommandGroup(replacing: .pasteboard) {
            command("Cut", .cut, key: "x")
            command("Copy", .copy, key: "c")
            command("Paste", .paste, key: "v")
            command("Duplicate", .duplicate, key: "d")
            command("Select All", .selectAll, key: "a")
        }
        CommandGroup(replacing: .undoRedo) {
            command("Undo", .undo, key: "z")
            command("Redo", .redo, key: "z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            command("Filter", .filter, key: "f")
        }
    }

    private func command(
        _ title: String,
        _ action: ExplorerCommand,
        key: KeyEquivalent,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(L10n.text(title)) { context?.perform(action) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(context?.available.contains(action) != true)
    }
}
