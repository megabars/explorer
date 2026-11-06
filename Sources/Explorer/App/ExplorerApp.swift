import SwiftUI

@main
struct ExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
        .commands { ExplorerCommands() }
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
        _ title: LocalizedStringKey,
        _ action: ExplorerCommand,
        key: KeyEquivalent,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) { context?.perform(action) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(context?.available.contains(action) != true)
    }
}
