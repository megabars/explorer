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
- `FileSystemService` — `actor`, all `FileManager` calls isolated here. Key methods: `listDirectory`, `completions(for:showHidden:)`, `isReadable(at:)`, `volumeName(for:)`, `exists(at:)`, `itemStatus(at:)`. Never call `FileManager` directly on `@MainActor` — use this actor instead.
- `BrowserViewModel`, `SidebarViewModel`, `AddressBarViewModel` — `@Observable @MainActor`
- `NavigationState` — `@Observable @MainActor`, owns back/forward stack (no history list)
- `DirectoryWatcher` — `@unchecked Sendable` class wrapping `DispatchSource.makeFileSystemObjectSource`, delivers events debounced (250 ms) via `DispatchWorkItem` on the main queue → `Task { @MainActor in … }`
- `TrashService` / `VolumeService` — `@MainActor` singletons; `TrashService` delegates to `NSWorkspace.recycle`, `VolumeService` observes mount/unmount notifications

### Key data flow
`NavigationState.currentURL` is the single source of truth for the current path. `BrowserContainerView` observes it via `.onChange(of: navigation.currentURL)` and calls `BrowserViewModel.load(url:)` which reads the directory via `FileSystemService` and starts a `DirectoryWatcher`.

All view-model instances are created in `ContentView` as `@State` and passed down by reference — there is no environment injection.

### Cross-component communication
- `Notification.Name.newFolderRequested` — posted by the SwiftUI menu command, observed in `BrowserViewModel.newFolder(in:)` via `ContentView`.
- `Notification.Name.renameRequestedForURL` — posted by the NSTableView context menu (`menuRename`), observed in `ContentView` to call `browser.startRename(_:)`.

### Rename flow
Inline rename in the list view is handled entirely in `FileListNSTableView`:
1. `BrowserViewModel.startRename(_:)` sets `renamingItem` / `renameText`.
2. `updateNSView` detects `renamingItem != nil` → calls `Coordinator.beginEditing(row:text:in:)`.
3. `beginEditing` makes the name cell's `NSTextField` editable and first-responder (deferred one run-loop pass to ensure the cell is laid out).
4. `NSTextFieldDelegate` in the coordinator handles Enter (commit), Escape (cancel), and focus loss (commit). Each handler sets `isRenaming = false` before calling the callback so the subsequent `controlTextDidEndEditing` is a no-op.
5. `reloadData` is skipped while `isRenaming` is true to avoid destroying the editing cell.

The same rename flow is triggered from icon view via the `.contextMenu` "Rename" item, which posts `renameRequestedForURL`.

### Sidebar
`SidebarViewModel` holds a static `favorites` list (`SidebarItem.defaults`) and delegates to `VolumeService.shared` for mounted volumes. Favorite availability is checked asynchronously via `refreshFavoriteAvailability()` (called from `.task` in `SidebarView`) to avoid blocking the main thread with `fileExists`.

### Address bar
Two states controlled by `AddressBarViewModel.isEditing`:
- **Idle** — `PathTokenView` breadcrumbs built from `URL.pathComponentURLs` (uses `url.pathComponents` string array — never call `deletingLastPathComponent()` in a loop, it caused a 30 GB memory hang). Volume name is resolved asynchronously via `.task(id: url)` using `FileSystemService.volumeName(for:)`.
- **Editing** — `FocusedTextField` (`NSTextField` via `NSViewRepresentable`) activated on click or `Cmd+L`; exits on Enter, Escape, or focus loss (`controlTextDidEndEditing`). Completions respect `browser.showHidden` (passed through `AddressBarView` → `AddressBarViewModel.textDidChange(_:service:showHidden:)`).

`AddressBarView` has no custom background — the system toolbar capsule (macOS 14+) provides the visual container. `FocusedTextField` is borderless/transparent so it blends into that capsule.

### AppKit bridges
- `FileListNSTableView` — `NSViewRepresentable` wrapping `NSTableView` for the list view; coordinator conforms to `NSTextFieldDelegate` for inline rename
- `FocusedTextField` — `NSViewRepresentable` wrapping `NSTextField` for address bar editing

### .app bundle
SPM builds a raw executable, not a `.app` bundle. `build_app.sh` wraps it:
```
Explorer.app/Contents/MacOS/Explorer   ← binary
Explorer.app/Contents/Info.plist       ← from Sources/Explorer/Resources/Info.plist
```
Without this, `NSApplication` does not get foreground activation policy and the window never appears.
