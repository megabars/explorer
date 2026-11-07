# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build and launch as a proper .app bundle (required — raw swift run hangs)
bash build_app.sh

# Build only
swift build

# Kill running instance
pkill -9 Explorer
```

> **Important:** Never run the binary directly via `swift run` or `.build/debug/Explorer`. The app must be launched via `Explorer.app` (which `build_app.sh` creates) to get proper NSApplication foreground status, Dock icon, and window management.

## Architecture

Swift 6 strict concurrency (`swiftLanguageMode(.v6)`), macOS 14+, SPM executable target.

### Concurrency model
- `FileSystemService` — `actor`, all `FileManager` calls isolated here. Key methods: `listDirectory`, `completions(for:showHidden:)`, `isReadable(at:)`, `volumeName(for:)`, `exists(at:)`, `itemStatus(at:)`, `rename(at:to:)`, `copy(at:to:)`, `createDirectory(at:)`. Never call `FileManager` directly on `@MainActor` — use this actor instead.
- `BrowserViewModel`, `SidebarViewModel`, `AddressBarViewModel` — `@Observable @MainActor`
- `NavigationState` — `@Observable @MainActor`, owns back/forward stack (no history list)
- `DirectoryWatcher` — `@MainActor` owner of an FSEvents stream for child file changes and a directory vnode source for entry changes. Notifications are coalesced over 250 ms. Parent vnode observations reattach the watcher when the displayed directory is replaced. A generation counter invalidates queued callbacks on stop/restart. On volumes without FSEvents, directory entry watching remains available.
- `TrashService` / `VolumeService` — `@MainActor` singletons. Trash retains successful URL mappings from the AppKit completion handler even on partial failure, retries only unmapped items, and carries successful moves in `PartialFailure` for Undo. Restore uses the exact original path and never overwrites an occupied destination. `VolumeService` observes mount/unmount notifications.

### Key data flow
`NavigationState.currentURL` is the single source of truth for the current path. `BrowserContainerView` observes it via `.onChange(of: navigation.currentURL)` and calls `BrowserViewModel.load(url:)` which reads the directory via `FileSystemService` and starts a `DirectoryWatcher`.

All view-model instances are created in `ContentView` as `@State` and passed down by reference — there is no environment injection.

### Cross-component communication
`ExplorerCommands` dispatches through a focused-scene handler owned by the active `ContentView`; file commands must never broadcast to every window. `ExplorerCommand` routes Cut, Copy, Paste, Select All, Undo, and Redo to the active AppKit text editor when one has focus. Context menus call their owning view model directly. Text editing must never fall through into file clipboard operations.

### Rename flow

`BrowserViewModel.startRename(_:)` stores the item and text. The list coordinator begins editing the Name column and preserves its displayed row snapshot while editing; pending metadata, row-order, and cut-state changes are applied when the editor ends. Selection is restored by URL with delegate feedback suppressed during synchronization.

Every rename callback carries the edited file ID. The SwiftUI adapter checks that ID against the current `renamingItem` before accepting text changes, commits, or cancellation. A stale field editor must not mutate a newer rename. Enter and focus loss commit; Escape restores the displayed name. The icon editor uses the same identity checks.

### Sorting and filtering
`BrowserViewModel` exposes `sortKey: SortKey` and `sortAscending: Bool`. The `sortedItems: [FileItem]` computed property filters by `searchQuery` (case-insensitive) then sorts — directories always first. Equal primary keys use name and URL as stable tie-breakers. Changing the filter prunes selection, and `selectedItems` independently excludes filtered-out items. `FileListNSTableView` synchronizes its actual `sortDescriptors` with the model, sets prototypes on each column, and updates the sort state via `tableView(_:sortDescriptorsDidChange:)`.

The search/filter bar is `SearchBarView` — a plain SwiftUI view shown/hidden by `ContentView` through the focused Filter command. It binds directly to `BrowserViewModel.searchQuery`.

### Multi-selection
`BrowserViewModel.lastSelectedURL` stores the shift+click anchor for range selection. The native table maintains range selection and updates this anchor for transitions to icon mode. Icon navigation derives its row stride from the viewport width and scrolls the selected item into view.

### Sidebar
`SidebarViewModel` persists favorites to `UserDefaults` as `[String]` (absolute URL strings, with legacy path support) under key `"explorerFavorites"`. On init it loads from UserDefaults, falling back to `SidebarItem.defaults` only when no saved array exists; a saved empty array stays empty. `addFavorite(url:)` and `removeFavorite(id:)` mutate and immediately save. Volumes come from `VolumeService.shared`. Favorite availability is checked asynchronously via `refreshFavoriteAvailability()` (called from `.task` in `SidebarView`) to avoid blocking the main thread with `fileExists`.

### Address bar
Two states controlled by `AddressBarViewModel.isEditing`:
- **Idle** — `PathTokenView` breadcrumbs in a horizontal `ScrollView` with `ScrollViewReader`; auto-scrolls to the last component on navigation so the current folder is always visible. Never call `deletingLastPathComponent()` in a loop — use `URL.pathComponentURLs` (defined in `URL+Extensions.swift`) which iterates `pathComponents` string array once (the loop caused a 30 GB memory hang). Volume name resolved asynchronously via `.task(id: url)`.
- **Editing** — `FocusedTextField` (`NSViewRepresentable` returning `TextFieldContainer`) activated on click or `Cmd+L`. `TextFieldContainer` is an `NSView` subclass that centers the `NSTextField` vertically via `layout()`. The field uses `cell.isScrollable = true` for horizontal scrolling of long paths. As the user types, `AddressBarViewModel` calls `FileSystemService.completions(for:showHidden:)` and shows matching subdirectories in `CompletionPopoverView` (a plain SwiftUI popover). Valid Enter exits; invalid paths keep the editor and show an error. Escape or focus loss cancels. Navigation revisions reject stale asynchronous commits.

`AddressBarView` has no custom background — the system toolbar capsule provides the visual container. The toolbar item uses `minWidth: 120` (not 500) so NSToolbar never pushes it to the `>>` overflow menu when paths are long.

### Clipboard

`NSPasteboard` is the source of truth for both keyboard and context-menu Paste. `canPaste` reads file URLs from that same pasteboard. `clipboardItems` and `clipboardIsCut` only track the app's cut indicators; an external clipboard replacement invalidates them. Cut uses an Explorer-specific pasteboard marker; external Finder copies remain copies.

Paste captures URLs, cut intent, and `changeCount` from one consistent pasteboard generation. Cut-paste moves each item once, prevents concurrent pastes, and retains only failed/unprocessed sources on partial failure. It clears the pasteboard only if its generation is still unchanged. The view model accepts a named pasteboard and directory-loader closure for tests, so tests never modify the user's general clipboard.

### Tags and compress
Tags are read via `NSURLTagNamesKey` and written to the Finder tag plist xattr while preserving existing color indices. `FileSystemService.setTags(_:for:)` writes them; `listDirectory` reads them into `FileItem.tags`. After `setTags` succeeds, `BrowserViewModel` updates the item in `items` directly for immediate feedback, before the coalesced watcher refresh. List view shows tags in a dedicated leftmost column wide enough for five tag dots; icon view shows dots below the filename. The Tags column can be toggled via right-click on any column header (macOS 13+ native API `tableView(_:userCanChangeVisibilityOf:)`); visibility is persisted to `UserDefaults` under key `"showTagsColumn"` via `BrowserViewModel.showTagsColumn`.

`BrowserViewModel.compress()` delegates to `FileSystemService.compress(_:in:)`, which runs `/usr/bin/zip` asynchronously. Filenames are literal relative paths after the option separator, symlinks are stored without following their targets, inherited zip options are removed, and output goes to a temporary log rather than unread pipes. Temporary output is cleaned up on success or failure. Archives are published with exclusive rename as `Archive.zip`, `Archive 2.zip`, etc.; existing files are preserved.

`ExplorerFileInfo` displays an information sheet for Get Info. `FileOpening` reports failures from Open, Open With, and Open in Terminal to the owning browser. Copy rejects directory destinations within the source tree, including aliases; conflict suffixes respect filesystem filename length limits.

### Non-persisted state
`BrowserViewModel.viewMode` (list vs icon) and `showHidden` reset to `.list` / `false` on each launch — they are not saved to UserDefaults. Only `showTagsColumn` (key `"showTagsColumn"`) and sidebar favorites (key `"explorerFavorites"`) persist across launches.

### Packages and directory loading

`BrowserViewModel.open(_:navigation:)` opens packages through `NSWorkspace` rather than navigating into them.

Each navigation gets a generation; each listing request also gets a sequence number. Initial loads, watcher reloads, and New Folder refreshes check both before applying results. Navigation clears stale selection and rename state. A file operation already started in an old directory may finish on disk but cannot replace the newly navigated directory's listing. Watcher events during an initial load request a subsequent refresh. Filesystem reads run on concurrent dispatch workers independently of the write actor, so a blocked metadata lookup in one directory does not queue navigation and operations on unrelated paths behind it.

### AppKit bridges and Swift 6 concurrency
- `FileListNSTableView` — `NSViewRepresentable` wrapping `NSTableView` for the list view; coordinator conforms to `NSTextFieldDelegate` for inline rename, `NSMenuDelegate` for context menu, `NSTableViewDataSource/Delegate` for drag & drop, and `NSTableViewDelegate` column-visibility methods (`userCanChangeVisibilityOf`/`userDidChangeVisibilityOf`). Drag & drop: `pasteboardWriterForRow` writes a file URL; validation records the destination and negotiated copy/move operation for the drag session. Acceptance verifies that operation is still allowed, then dispatches the corresponding filesystem call. Background drops target the current directory, including empty directories. Icon drops use an explicit SwiftUI drop proposal: Native list drags carry a move-capable marker and move by default (Option copies). Legacy SwiftUI icon drags and external providers copy because SwiftUI does not expose their source-operation mask. File providers are loaded only in performDrop; hover validation uses hasItemsConforming.
- **Swift 6 AppKit delegate pattern:** Several `NSTableViewDelegate` methods must be declared `nonisolated` because the newer SDK no longer marks the protocol `@preconcurrency`. Use `MainActor.assumeIsolated { }` inside these methods to safely access `@MainActor` state — AppKit always calls delegates on the main thread. See `userCanChangeVisibilityOf` / `userDidChangeVisibilityOf` in `FileListNSTableView` for the pattern. New AppKit delegate methods should follow the same approach.
- `FocusedTextField` — `NSViewRepresentable` returning `TextFieldContainer` (NSView subclass that centers an NSTextField via `layout()`) for address bar and icon rename editing; rename fields select the full name and handle Enter, Escape, and focus loss once
- Right-click on empty space in list view shows "New Folder" + "Paste" + "Open in Terminal" via `menuNeedsUpdate` when `clickedRow < 0`; icon view shows the same via SwiftUI `.contextMenu` on the `ScrollView`. "Open in Terminal" uses `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")` + `NSWorkspace.shared.open([url], withApplicationAt:)` — item context menu shows it only for directories, empty-space menu always shows it for the current directory. `FileListNSTableView` carries a `currentURL: URL` property for this purpose.
- "Open With ▶" submenu appears after "Open" for non-directory, non-package files. Built via `NSWorkspace.shared.urlsForApplications(toOpen:)` (all apps) + `urlForApplication(toOpen:)` (default, marked "(default)"). List view uses NSMenu with `NSWorkspace.shared.icon(forFile:)` app icons; icon view uses SwiftUI `Menu("Open With")` with `ForEach`.

### .app bundle
SPM builds a raw executable, not a `.app` bundle. `build_app.sh` wraps it:
```
Explorer.app/Contents/MacOS/Explorer   ← binary
Explorer.app/Contents/Info.plist       ← from Sources/Explorer/Resources/Info.plist
```
Without this, `NSApplication` does not get foreground activation policy and the window never appears.

## Localization

`ExplorerEntryPoint.main()` normalizes invalid app language overrides and freezes
`L10n` before starting the SwiftUI app. `LanguagePreferences` reads the app's own
`AppleLanguages` domain for a manual selection and the global domain separately
for system mode; it only writes/removes the app-domain value. Settings changes
take effect on the next launch and must not reset active browser/window state.

Use `L10n.text` for English source keys, `L10n.format` for argument-bearing strings,
and `L10n.plural` for the `items.count`/`results.count` catalogs. Resource tables are
in `Resources/Localization/{en,ru,es}.lproj`. Keep keys and format specifiers in
sync, and keep actual paths, filenames, third-party app names and stored Finder
tag values out of translation lookups. Standard palette *labels* are localized.
Use `L10n.locale` when formatting UI dates and sizes.

SwiftPM creates `Explorer_Explorer.bundle`; `build_app.sh` copies it into
`Explorer.app/Contents/Resources`. `LocalizedStrings` resolves this embedded
bundle before the development-only `Bundle.module` fallback. Both the app's
`CFBundleLocalizations` and the package's `defaultLocalization` must stay current.

## Tests

`Tests/ExplorerTests` uses Swift Testing. Run `swift test --disable-xctest`. Tests use temporary directories, named pasteboards, and simulated trash outcomes. They cover archive safety, restore conflicts, partial trash failures, directory events, stale loads, selection/filtering, clipboard ownership, sort ordering, AppKit row/rename/drop behavior, text commands, and address completion.

Tests that use pasteboards, AppKit, LaunchServices, or FSEvents need access to the normal macOS user session. A restrictive process sandbox can block those services independently of app correctness. See README for Command Line Tools SDK/framework overrides when a full Xcode installation is unavailable.
