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
- `DirectoryWatcher` — `@unchecked Sendable` class wrapping `DispatchSource.makeFileSystemObjectSource`, delivers events debounced (250 ms) via `DispatchWorkItem` on the main queue → `Task { @MainActor in … }`
- `TrashService` / `VolumeService` — `@MainActor` singletons; `TrashService` delegates to `NSWorkspace.recycle`, `VolumeService` observes mount/unmount notifications

### Key data flow
`NavigationState.currentURL` is the single source of truth for the current path. `BrowserContainerView` observes it via `.onChange(of: navigation.currentURL)` and calls `BrowserViewModel.load(url:)` which reads the directory via `FileSystemService` and starts a `DirectoryWatcher`.

All view-model instances are created in `ContentView` as `@State` and passed down by reference — there is no environment injection.

### Cross-component communication
All clipboard and file-management commands flow through `NotificationCenter` because AppKit's responder chain intercepts `Cmd+C/V/X` before SwiftUI `onKeyPress` reaches them. `ExplorerApp` overrides these via `CommandGroup(replacing:)` which posts notifications; `ContentView` observes them via `.onReceive`.

Notification names defined in `ExplorerApp.swift`:
- `.newFolderRequested` — New Folder (Cmd+Shift+N)
- `.renameRequestedForURL` — rename a specific URL (from NSTableView context menu)
- `.cutRequested` / `.copyRequested` / `.pasteRequested` / `.duplicateRequested` — clipboard ops
- `.filterRequested` — toggle search bar (Cmd+F)

### Rename flow
Inline rename in the list view is handled entirely in `FileListNSTableView`:
1. `BrowserViewModel.startRename(_:)` sets `renamingItem` / `renameText`.
2. `updateNSView` detects `renamingItem != nil` → calls `Coordinator.beginEditing(row:text:in:)`.
3. `beginEditing` makes the name cell's `NSTextField` editable and first-responder (deferred one run-loop pass to ensure the cell is laid out).
4. `NSTextFieldDelegate` in the coordinator handles Enter (commit), Escape (cancel), and focus loss (commit). Each handler sets `isRenaming = false` before calling the callback so the subsequent `controlTextDidEndEditing` is a no-op.
5. `reloadData` is skipped while `isRenaming` is true to avoid destroying the editing cell.

The same rename flow is triggered from icon view via the `.contextMenu` "Rename" item, which posts `renameRequestedForURL`.

### Sorting and filtering
`BrowserViewModel` exposes `sortKey: SortKey` and `sortAscending: Bool`. The `sortedItems: [FileItem]` computed property filters by `searchQuery` (case-insensitive) then sorts — directories always first. `FileListNSTableView` sets `NSSortDescriptor` prototypes on each column and updates the sort state via `tableView(_:sortDescriptorsDidChange:)`.

### Sidebar
`SidebarViewModel` persists favorites to `UserDefaults` as `[String]` (URL paths) under key `"explorerFavorites"`. On init it loads from UserDefaults, falling back to `SidebarItem.defaults`. `addFavorite(url:)` and `removeFavorite(id:)` mutate and immediately save. Volumes come from `VolumeService.shared`. Favorite availability is checked asynchronously via `refreshFavoriteAvailability()` (called from `.task` in `SidebarView`) to avoid blocking the main thread with `fileExists`.

### Address bar
Two states controlled by `AddressBarViewModel.isEditing`:
- **Idle** — `PathTokenView` breadcrumbs in a horizontal `ScrollView` with `ScrollViewReader`; auto-scrolls to the last component on navigation so the current folder is always visible. Never call `deletingLastPathComponent()` in a loop — use `url.pathComponents` string array (loop caused a 30 GB memory hang). Volume name resolved asynchronously via `.task(id: url)`.
- **Editing** — `FocusedTextField` (`NSViewRepresentable` returning `TextFieldContainer`) activated on click or `Cmd+L`. `TextFieldContainer` is an `NSView` subclass that centers the `NSTextField` vertically via `layout()`. The field uses `cell.isScrollable = true` for horizontal scrolling of long paths. Exits on Enter, Escape, or focus loss.

`AddressBarView` has no custom background — the system toolbar capsule provides the visual container. The toolbar item uses `minWidth: 120` (not 500) so NSToolbar never pushes it to the `>>` overflow menu when paths are long.

### Clipboard
`BrowserViewModel` manages cut/copy/paste via `NSPasteboard`. Cut items are tracked in `cutItems: Set<URL>`; pasting resolves conflicts (duplicate filenames get a numeric suffix). All clipboard commands flow through `NotificationCenter` (see Cross-component communication).

### AppKit bridges
- `FileListNSTableView` — `NSViewRepresentable` wrapping `NSTableView` for the list view; coordinator conforms to `NSTextFieldDelegate` for inline rename, `NSMenuDelegate` for context menu, and `NSTableViewDataSource/Delegate` for drag & drop
- `FocusedTextField` — `NSViewRepresentable` returning `TextFieldContainer` (NSView subclass that centers an NSTextField via `layout()`) for address bar editing
- Right-click on empty space in list view shows "New Folder" + "Paste" via `menuNeedsUpdate` when `clickedRow < 0`; icon view shows the same via SwiftUI `.contextMenu` on the `ScrollView`

### .app bundle
SPM builds a raw executable, not a `.app` bundle. `build_app.sh` wraps it:
```
Explorer.app/Contents/MacOS/Explorer   ← binary
Explorer.app/Contents/Info.plist       ← from Sources/Explorer/Resources/Info.plist
```
Without this, `NSApplication` does not get foreground activation policy and the window never appears.

## Tests

No test targets exist. The project has no automated tests.
