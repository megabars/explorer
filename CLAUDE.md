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
- `FileSystemService` — `actor`, all `FileManager` calls isolated here
- `BrowserViewModel`, `SidebarViewModel`, `AddressBarViewModel` — `@Observable @MainActor`
- `NavigationState` — `@Observable @MainActor`, owns back/forward stack
- `DirectoryWatcher` — `@unchecked Sendable` class wrapping `DispatchSource.makeFileSystemObjectSource`, delivers events via `Task { @MainActor in … }`
- `TrashService` / `VolumeService` — `@MainActor` singletons; `TrashService` delegates to `NSWorkspace.recycle`, `VolumeService` observes mount/unmount notifications

### Key data flow
`NavigationState.currentURL` is the single source of truth for the current path. `BrowserContainerView` observes it via `.onChange(of: navigation.currentURL)` and calls `BrowserViewModel.load(url:)` which reads the directory via `FileSystemService` and starts a `DirectoryWatcher`.

All view-model instances are created in `ContentView` as `@State` and passed down by reference — there is no environment injection.

### Cross-component communication
`Notification.Name.newFolderRequested` (posted via `NotificationCenter.default`) bridges SwiftUI menu commands to `BrowserViewModel.newFolder(in:)`.

### Sidebar
`SidebarViewModel` holds a static `favorites` list (`SidebarItem.defaults`) and delegates to `VolumeService.shared` for mounted volumes. Both sections are rendered by `SidebarView`.

### Address bar
Two states controlled by `AddressBarViewModel.isEditing`:
- **Idle** — `PathTokenView` breadcrumbs built from `URL.pathComponentURLs` (uses `url.pathComponents` string array — never call `deletingLastPathComponent()` in a loop, it caused a 30 GB memory hang)
- **Editing** — `FocusedTextField` (`NSTextField` via `NSViewRepresentable`) activated on click or `Cmd+L`; exits on Enter, Escape, or focus loss (`controlTextDidEndEditing`)

`AddressBarView` has no custom background — the system toolbar capsule (macOS 14+) provides the visual container. `FocusedTextField` is borderless/transparent so it blends into that capsule.

### AppKit bridges
- `FileListNSTableView` — `NSViewRepresentable` wrapping `NSTableView` for the list view
- `FocusedTextField` — `NSViewRepresentable` wrapping `NSTextField` for address bar editing

### .app bundle
SPM builds a raw executable, not a `.app` bundle. `build_app.sh` wraps it:
```
Explorer.app/Contents/MacOS/Explorer   ← binary
Explorer.app/Contents/Info.plist       ← from Sources/Explorer/Resources/Info.plist
```
Without this, `NSApplication` does not get foreground activation policy and the window never appears.
