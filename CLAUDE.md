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
- `FileSystemService` — `actor`, all `FileManager` calls isolated here. Key methods: `listDirectory`, `completions(for:showHidden:)`, `isReadable(at:)`, `volumeName(for:)`, `exists(at:)`, `itemStatus(at:)`, `rename(at:to:)`, `copy(at:to:)`, `createDirectory(at:)`, `restoreItem(from:to:)` (moves to an exact destination URL, used by undo to restore trashed files to their original paths). Never call `FileManager` directly on `@MainActor` — use this actor instead.
- `BrowserViewModel`, `SidebarViewModel`, `AddressBarViewModel` — `@Observable @MainActor`
- `NavigationState` — `@Observable @MainActor`, owns back/forward stack (no history list)
- `DirectoryWatcher` — `@unchecked Sendable` class wrapping `DispatchSource.makeFileSystemObjectSource`, delivers events debounced (250 ms) via `DispatchWorkItem` on the main queue → `Task { @MainActor in … }`. Uses a `generation` counter incremented on each `start()` to discard stale dispatches that survive a `stop()`/`start()` cycle. `start()` returns `Bool` — `false` if the directory cannot be watched (e.g. kqueue permission denied). `deinit` cancels source and debounce item directly — `DispatchSourceProtocol.cancel()` and `DispatchWorkItem.cancel()` are GCD-thread-safe, so no main-queue dispatch is needed.
- `TrashService` / `VolumeService` — `@MainActor` singletons; `TrashService` delegates to `NSWorkspace.shared.recycle` and returns a `TrashResult` (never throws). On batch failure it retries individually, skipping already-trashed files, and always returns `TrashResult(mapping:failures:)` — `mapping` covers successfully trashed items (so callers can set undo state even on partial failure), `failures` contains per-item error strings. `VolumeService` observes mount/unmount notifications.

### Key data flow
`NavigationState.currentURL` is the single source of truth for the current path. `BrowserContainerView` observes it via `.onChange(of: navigation.currentURL)` and calls `BrowserViewModel.load(url:)` which reads the directory via `FileSystemService` and starts a `DirectoryWatcher`. `BrowserViewModel` tracks `currentLoadURL` to guard against stale watcher callbacks: `reload(url:)` checks `currentLoadURL == url` both before and after the async `listDirectory` call to discard results that arrived after a navigation.

All view-model instances are created in `ContentView` as `@State` and passed down by reference — there is no environment injection.

### Cross-component communication
All clipboard and file-management commands flow through `NotificationCenter` because AppKit's responder chain intercepts `Cmd+C/V/X` before SwiftUI `onKeyPress` reaches them. `ExplorerApp` overrides these via `CommandGroup(replacing:)` which posts notifications; `ContentView` observes them via `.onReceive`.

Notification names defined in `ExplorerApp.swift`:
- `.newFolderRequested` — New Folder (Cmd+Shift+N)
- `.renameRequestedForURL` — rename a specific URL (from NSTableView context menu)
- `.cutRequested` / `.copyRequested` / `.pasteRequested` / `.duplicateRequested` — clipboard ops
- `.filterRequested` — toggle search bar (Cmd+F)
- `.selectAllRequested` — Select All (Cmd+A); registered explicitly because `CommandGroup(replacing: .textEditing)` removes the default Select All
- `.undoRequested` — Undo (Cmd+Z)
- `.getInfoRequested` — open Get Info panel for selected items (Cmd+I)
- `.goBackRequested` / `.goForwardRequested` / `.goUpRequested` / `.openSelectedRequested` — Go menu navigation (Cmd+[ / Cmd+] / Cmd+↑ / Cmd+↓)

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

The search/filter bar is `SearchBarView` — a plain SwiftUI view shown/hidden by `BrowserContainerView` in response to `.filterRequested` notification. It binds directly to `BrowserViewModel.searchQuery`.

### Multi-selection
`BrowserViewModel.lastSelectedURL` stores the shift+click anchor for range selection. Both list and icon views implement shift+click range expansion by iterating `sortedItems` between the anchor and the clicked item.

### Sidebar
`SidebarViewModel` persists favorites to `UserDefaults` as `[String]` (URL paths) under key `"explorerFavorites"`. On init it loads from UserDefaults, falling back to `SidebarItem.defaults`. `addFavorite(url:)` and `removeFavorite(id:)` mutate and immediately save. Volumes come from `VolumeService.shared`. Favorite availability is checked asynchronously via `refreshFavoriteAvailability()` (called from `.task` in `SidebarView`) to avoid blocking the main thread with `fileExists`.

### Address bar
Two states controlled by `AddressBarViewModel.isEditing`:
- **Idle** — `PathTokenView` breadcrumbs in a horizontal `ScrollView` with `ScrollViewReader`; auto-scrolls to the last component on navigation so the current folder is always visible. Never call `deletingLastPathComponent()` in a loop — use `URL.pathComponentURLs` (defined in `URL+Extensions.swift`) which iterates `pathComponents` string array once (the loop caused a 30 GB memory hang). Volume name resolved asynchronously via `.task(id: url)`.
- **Editing** — `FocusedTextField` (`NSViewRepresentable` returning `TextFieldContainer`) activated on click or `Cmd+L`. `TextFieldContainer` is an `NSView` subclass that centers the `NSTextField` vertically via `layout()`. The field uses `cell.isScrollable = true` for horizontal scrolling of long paths. As the user types, `AddressBarViewModel` calls `FileSystemService.completions(for:showHidden:)` and shows matching subdirectories in `CompletionPopoverView` (a plain SwiftUI popover). Exits on Enter, Escape, or focus loss.

`AddressBarView` has no custom background — the system toolbar capsule provides the visual container. The toolbar item uses `minWidth: 120` (not 500) so NSToolbar never pushes it to the `>>` overflow menu when paths are long.

### Clipboard
`BrowserViewModel` manages cut/copy/paste entirely in-memory — no `NSPasteboard` is used. State: `clipboardItems: [FileItem]` + `clipboardIsCut: Bool`. Cut clears the clipboard immediately on paste attempt; if the operation fails, the clipboard is restored. Pasting resolves name conflicts with a numeric suffix (retry-on-conflict pattern, same as `copy`). All clipboard commands flow through `NotificationCenter` (see Cross-component communication).

### Tags and compress
Tags are macOS Finder color tags stored via `NSURLTagNamesKey`. `FileSystemService.setTags(_:for:)` writes them; `listDirectory` reads them into `FileItem.tags`. After `setTags` succeeds, `BrowserViewModel` updates the item in `items` directly — the `DirectoryWatcher` does not fire for xattr changes. List view shows tags in a dedicated narrow leftmost column ("Tags", 16px); icon view shows dots below the filename. The Tags column can be toggled via right-click on any column header (macOS 13+ native API `tableView(_:userCanChangeVisibilityOf:)`); visibility is persisted to `UserDefaults` under key `"showTagsColumn"` via `BrowserViewModel.showTagsColumn`.

`BrowserViewModel.compress()` delegates to `FileSystemService.compress(_:in:)` which shells out to `/usr/bin/zip` via `Process` using `withCheckedThrowingContinuation` + `terminationHandler` (non-blocking — actor is free while zip runs); the archive is named `Archive.zip` (incrementing to `Archive 2.zip` etc. on conflict).

### Non-persisted state
`BrowserViewModel.viewMode` (list vs icon) and `showHidden` reset to `.list` / `false` on each launch — they are not saved to UserDefaults. Only `showTagsColumn` (key `"showTagsColumn"`) and sidebar favorites (key `"explorerFavorites"`) persist across launches.

### Get Info panel
`FileInfoWindowManager` (`Views/Info/`) — `@MainActor` singleton managing floating `NSPanel`s (one per URL). `showInfo(for:)` brings an existing panel to the front or creates a new one; closed panels are removed from the registry via `NSWindowDelegate`. Panels use `.nonactivatingPanel` so the file manager window stays key. `FileInfoView` is the SwiftUI content: three-state (loading / loaded / error), fetches `FileExtendedInfo` via `FileSystemService.extendedInfo(for:)` (which additionally reads POSIX permissions and owner via `FileManager.attributesOfItem`). Cmd+I is wired via the `NotificationCenter` pattern (`.getInfoRequested` notification, handled in `ContentView`).

### Undo
`BrowserViewModel` maintains a single `lastAction: UndoableAction?` — currently only trash operations are undoable (`UndoableAction.Kind.trash(pairs: [(original: URL, trashed: URL)])`). Pairs keep each original↔trashed URL together so a partial trash (some items fail) never mismatches via `zip`. Undo calls `FileSystemService.restoreItem(from:to:)` which moves to the exact original URL (preserving the original filename even if Trash renamed the file due to a conflict). On partial undo failure, `lastAction` is restored with only the failed pairs so the user can retry Cmd+Z for the remaining items. Undo state is cleared on navigation. There is no undo stack.

### Packages and `suppressReload`
`BrowserViewModel.open(_:navigation:)` checks `item.isPackage` — packages (`.app` bundles, etc.) are opened with `NSWorkspace.shared.open` rather than navigated into, same as regular files.

`suppressReload: Bool` on `BrowserViewModel` prevents the `DirectoryWatcher` callback from triggering a redundant reload while `newFolder(in:)` is performing an explicit reload after directory creation. It is set synchronously on `@MainActor` before any `await` so the watcher callback (which also runs on `@MainActor`) cannot fire between the set and the reload.

### AppKit bridges and Swift 6 concurrency
- `FileListNSTableView` — `NSViewRepresentable` wrapping `NSTableView` for the list view; coordinator conforms to `NSTextFieldDelegate` for inline rename, `NSMenuDelegate` for context menu, `NSTableViewDataSource/Delegate` for drag & drop, and `NSTableViewDelegate` column-visibility methods (`userCanChangeVisibilityOf`/`userDidChangeVisibilityOf`). Drag & drop: `pasteboardWriterForRow` writes the file URL path into an `NSPasteboardItem`; `validateDrop` allows `.on` only for directory rows (non-directory drops redirect to end-of-list); `acceptDrop` moves or copies via `BrowserViewModel.move/copy` depending on `draggingSourceOperationMask`.
- **Swift 6 AppKit delegate pattern:** Several `NSTableViewDelegate` methods must be declared `nonisolated` because the newer SDK no longer marks the protocol `@preconcurrency`. Use `MainActor.assumeIsolated { }` inside these methods to safely access `@MainActor` state — AppKit always calls delegates on the main thread. See `userCanChangeVisibilityOf` / `userDidChangeVisibilityOf` in `FileListNSTableView` for the pattern. New AppKit delegate methods should follow the same approach.
- `FocusedTextField` — `NSViewRepresentable` returning `TextFieldContainer` (NSView subclass that centers an NSTextField via `layout()`) for address bar editing
- Right-click on empty space in list view shows "New Folder" + "Paste" + "Open in Terminal" via `menuNeedsUpdate` when `clickedRow < 0`; icon view shows the same via SwiftUI `.contextMenu` on the `ScrollView`. "Open in Terminal" uses `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")` + `NSWorkspace.shared.open([url], withApplicationAt:)` — item context menu shows it only for directories, empty-space menu always shows it for the current directory. `FileListNSTableView` carries a `currentURL: URL` property for this purpose.
- "Open With ▶" submenu appears after "Open" for non-directory, non-package files. Built via `NSWorkspace.shared.urlsForApplications(toOpen:)` (all apps) + `urlForApplication(toOpen:)` (default, marked "(default)"). List view uses NSMenu with `NSWorkspace.shared.icon(forFile:)` app icons; icon view uses SwiftUI `Menu("Open With")` with `ForEach`.

### .app bundle
SPM builds a raw executable, not a `.app` bundle. `build_app.sh` wraps it:
```
Explorer.app/Contents/MacOS/Explorer   ← binary
Explorer.app/Contents/Info.plist       ← from Sources/Explorer/Resources/Info.plist
```
Without this, `NSApplication` does not get foreground activation policy and the window never appears.

## Tests

No test targets exist. The project has no automated tests.
