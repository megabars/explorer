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
- Xcode 15+ or Swift 6 toolchain

## Build & Run

```bash
# Build and launch as a proper .app bundle
bash build_app.sh
```

Or open in Xcode:

```bash
open Package.swift
```

## Stack

Swift 6 + SwiftUI + AppKit. No Electron, no JVM — native macOS binary.

- `@Observable` + `@MainActor` view models
- `actor`-isolated file system service
- `DispatchSource` (kqueue) for live directory watching
- `NSTableView` via `NSViewRepresentable` for the list view
- `NSTextField` via `NSViewRepresentable` for the address bar editing state
