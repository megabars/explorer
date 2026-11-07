# Explorer

A macOS file manager built as a Finder replacement, inspired by Windows Explorer.

## Why

Finder lacks an editable address bar. Explorer adds one — click anywhere on the breadcrumb path or press `Cmd+L` to type a path directly, with Tab completion.

## Features

- **Editable address bar** — breadcrumb tokens in idle mode, full path editing with filesystem completion on `Cmd+L`
- **Back / Forward / Up** navigation with history
- **List view** — sortable columns: Name, Date Modified, Size, Kind
- **Icon view** — grid with file icons
- **Sidebar** — Favorites (Home, Desktop, Documents, Downloads) + mounted Volumes
- **Live directory watching** — contents refresh automatically on file system changes
- **File operations** — New Folder (`⇧⌘N`), Move to Trash (`⌘⌫`), Copy/Paste
- **Status bar** — item count and selection info

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ or Swift 6 toolchain

## Build & Run

```bash
# Build and launch as a proper .app bundle
bash build_app.sh
```

To build an optimized app for personal use without launching it:

```bash
bash script/package_release.sh
```

The app is `Explorer.app`; a versioned ZIP and SHA-256 checksum are written to
`dist/`. Copy `Explorer.app` to your Applications folder to keep it independently
of the checkout. `build_app.sh --no-launch` also supports build-only workflows.

SwiftPM build options can be passed through to the script. For example, if the
selected SDK is missing the SwiftUI macro plugin, use a compatible installed SDK:

```bash
bash build_app.sh --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

Or open in Xcode:

```bash
open Package.swift
```

## Releases

The current version is **1.0.2 (build 3)**. Download packaged builds from
[GitHub Releases](https://github.com/megabars/explorer/releases).

GitHub Actions runs the regression suite and builds a universal Apple Silicon +
Intel app for version tags (`v*`), pull requests, and manual workflow runs.
Version tags must match `CFBundleShortVersionString` in `Info.plist`; successful
tag builds publish the ZIP and checksum to a GitHub Release. Update both bundle
version fields and `RELEASE_NOTES.md` before creating the next tag.

Builds have an ad hoc code signature, without Developer ID signing or Apple
notarization. Local builds are intended for personal use.

## Stack

Swift 6 + SwiftUI + AppKit. No Electron, no JVM — native macOS binary.

- `@Observable` + `@MainActor` view models
- Concurrent filesystem reads with actor-isolated writes
- FSEvents plus `DispatchSource` (kqueue) for live directory and file updates
- `NSTableView` via `NSViewRepresentable` for the list view
- `NSTextField` via `NSViewRepresentable` for the address bar editing state

## Tests

The Swift Testing suite uses temporary files, private named pasteboards, and
simulated Trash responses. It covers archive safety, restore conflicts, partial
failures, directory watching, navigation races, filtering, clipboard operations,
sorting, AppKit row updates and drag/drop, focused-window/text commands, icon navigation,
Finder tag colors, symlinks, favorites persistence, and path completion.

```bash
swift test --disable-xctest
```

Run in a normal macOS user session: AppKit, pasteboard, LaunchServices, and
FSEvents tests need access to their system services. A process sandbox can block
these services even when compilation succeeds.

For a Command Line Tools installation that does not discover Swift Testing
automatically, the following command explicitly supplies its bundled framework
and macro plugin. Adjust the SDK path to a compatible SDK installed locally:

```bash
swift test --build-system native --disable-xctest \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
