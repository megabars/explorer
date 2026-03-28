import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class BrowserViewModel {
    var items: [FileItem] = []
    var selection: Set<URL> = []
    var viewMode: ViewMode = .list
    var isLoading: Bool = false
    /// Error from loading a directory — shown inline in BrowserContainerView instead of content.
    var loadError: String?
    /// Error from file operations (rename, trash, paste, etc.) — shown as an alert.
    var errorMessage: String?
    var showHidden: Bool = false
    var showTagsColumn: Bool = UserDefaults.standard.object(forKey: "showTagsColumn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTagsColumn, forKey: "showTagsColumn") }
    }

    // Clipboard state
    var clipboardItems: [FileItem] = []
    var clipboardIsCut: Bool = false

    // Undo state — stores the last file operation for Cmd+Z
    struct UndoableAction {
        // Pairs keep original↔trashed together so zip never mismatches when only some items were trashed.
        enum Kind { case trash(pairs: [(original: URL, trashed: URL)]) }
        let kind: Kind
    }
    private(set) var lastAction: UndoableAction?

    // Rename state
    var renamingItem: FileItem?
    var renameText: String = ""

    // Sorting
    enum SortKey: String {
        case name, dateModified, size, kind
    }
    var sortKey: SortKey = .name
    var sortAscending: Bool = true

    // Search / filter
    var searchQuery: String = ""

    // Cache for "Open With" apps — keyed by file extension to avoid repeated I/O
    private var openWithCache: [String: [URL]] = [:]

    func openWithApps(for url: URL) -> [URL] {
        let ext = url.pathExtension.lowercased()
        if let cached = openWithCache[ext] { return cached }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        openWithCache[ext] = apps
        return apps
    }

    // Shift+Click anchor for range selection
    var lastSelectedURL: URL?

    private var loadTask: Task<Void, Never>?
    private let watcher = DirectoryWatcher()
    private let fs = FileSystemService.shared
    /// Suppresses watcher-triggered reloads during explicit reloads (e.g. after newFolder).
    private var suppressReload: Bool = false
    /// Tracks the URL currently being loaded so reload() can detect stale callbacks.
    private var currentLoadURL: URL?

    // MARK: - Loading

    func load(url: URL) {
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        currentLoadURL = url
        // Clear undo state on navigation — the trashed files belong to a different directory
        // and restoring them would be unexpected from the user's perspective.
        lastAction = nil

        loadTask = Task {
            do {
                let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
                if Task.isCancelled { return }
                items = loaded
                selection = []
                isLoading = false
            } catch {
                if Task.isCancelled { return }
                loadError = error.localizedDescription
                items = []
                isLoading = false
            }
        }

        if !watcher.start(watching: url, onChange: { [weak self] in
            guard let self else { return }
            Task { await self.reload(url: url) }
        }) {
            // Directory is readable but can't be watched (e.g. permission denied on kqueue).
            // Contents still load normally; live updates just won't happen.
            errorMessage = "This directory cannot be watched for changes."
        }
    }

    private func reload(url: URL) async {
        // Guard against stale watcher callbacks arriving after navigation to a different directory.
        guard !isLoading, !suppressReload, currentLoadURL == url else { return }
        do {
            let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
            // Re-check after the async call — load(url:) may have been called during the await.
            guard currentLoadURL == url else { return }
            items = loaded
            // Prune selection to only URLs still present in the new listing
            let currentURLs = Set(loaded.map(\.url))
            selection = selection.intersection(currentURLs)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func stopWatching() {
        watcher.stop()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    // MARK: - Open

    func open(_ item: FileItem, navigation: NavigationState) {
        if item.isDirectory && !item.isPackage {
            navigation.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - File Operations

    func trash(navigation: NavigationState) {
        trash(items: selectedItems)
    }

    func trash(items: [FileItem]) {
        guard !items.isEmpty else { return }
        Task {
            do {
                let mapping = try await TrashService.shared.trash(items: items)
                // Build pairs so each original is matched with its actual trashed URL.
                // compactMap drops items that were not successfully trashed (no entry in mapping).
                // Using pairs avoids the mis-zip bug that occurs when only a subset is trashed.
                let pairs: [(original: URL, trashed: URL)] = items.compactMap { item in
                    guard let trashedURL = mapping[item.url] else { return nil }
                    return (original: item.url, trashed: trashedURL)
                }
                if !pairs.isEmpty {
                    lastAction = UndoableAction(kind: .trash(pairs: pairs))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Undoes the last undoable action (currently: restoring trashed files).
    func undo() {
        guard let action = lastAction else { return }
        lastAction = nil
        switch action.kind {
        case .trash(let pairs):
            Task {
                do {
                    for (original, trashed) in pairs {
                        // restoreItem moves to the exact original URL, preserving the original filename
                        // even if the file was renamed in Trash due to a naming conflict.
                        try await fs.restoreItem(from: trashed, to: original)
                    }
                } catch {
                    errorMessage = "Undo failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func newFolder(in url: URL) {
        Task {
            // Suppress watcher-triggered reloads while we explicitly reload after creation.
            // Set before any await so it takes effect synchronously on @MainActor.
            suppressReload = true
            defer { suppressReload = false }
            do {
                var name = "New Folder"
                var counter = 2
                var newURL: URL = url.appendingPathComponent(name)
                // Atomic creation: attempt createDirectory; on name conflict retry with a counter.
                // This avoids the TOCTOU race of pre-checking existence separately.
                while true {
                    newURL = url.appendingPathComponent(name)
                    do {
                        try await fs.createDirectory(at: newURL)
                        break
                    } catch let e as NSError
                        where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
                        guard counter <= 100 else {
                            throw NSError(
                                domain: NSCocoaErrorDomain,
                                code: NSFileWriteFileExistsError,
                                userInfo: [NSLocalizedDescriptionKey: "Could not create a unique folder name."]
                            )
                        }
                        name = "New Folder \(counter)"
                        counter += 1
                    }
                }
                // Reload explicitly so the new folder appears in items before we rename
                let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
                items = loaded
                if let newItem = items.first(where: { $0.name == name && $0.isDirectory }) {
                    startRename(newItem)
                } else {
                    errorMessage = "New folder was created but could not be located for renaming."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copy() {
        clipboardItems = selectedItems
        clipboardIsCut = false
        writeToSystemPasteboard(items: selectedItems, isCut: false)
    }

    func cut() {
        clipboardItems = selectedItems
        clipboardIsCut = true
        writeToSystemPasteboard(items: selectedItems, isCut: true)
    }

    /// Writes file URLs to NSPasteboard so Finder and other apps can paste them.
    private func writeToSystemPasteboard(items: [FileItem], isCut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let urls = items.map(\.url) as [NSURL]
        pb.writeObjects(urls)
        // Finder uses "com.apple.pasteboard.promised-file-content-type" for cut;
        // we mark our cut state via a custom pasteboard type.
        if isCut {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.pasteboard.cut"))
        }
    }

    /// Reads file URLs from NSPasteboard (e.g. from Finder copy).
    func pasteFromSystemPasteboard(into destination: URL) {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            // Fall back to in-memory clipboard
            paste(into: destination)
            return
        }
        let isCut = pb.data(forType: NSPasteboard.PasteboardType("com.apple.pasteboard.cut")) != nil
        Task {
            do {
                if isCut {
                    try await fs.move(from: urls, to: destination)
                    pb.clearContents()
                } else {
                    let fileItems = urls.map { url in
                        FileItem(id: url, url: url, name: url.lastPathComponent,
                                 isDirectory: false, isPackage: false, isHidden: false,
                                 isSymlink: false, fileSize: nil, contentModificationDate: nil,
                                 creationDate: nil, kind: "", tags: [])
                    }
                    try await fs.copy(items: fileItems, to: destination)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func paste(into destination: URL) {
        guard !clipboardItems.isEmpty else { return }
        let isCut = clipboardIsCut
        let items = clipboardItems
        // For cut, clear clipboard immediately to prevent a second paste of the same items.
        // If the operation fails, we restore the clipboard below.
        if isCut {
            clipboardItems = []
            clipboardIsCut = false
        }
        Task {
            // Filter to items that still exist — clipboard may be stale
            var existing: [FileItem] = []
            for item in items {
                if await fs.exists(at: item.url) { existing.append(item) }
            }
            guard !existing.isEmpty else { return }
            do {
                try await fs.copy(items: existing, to: destination)
                if isCut {
                    do {
                        try await TrashService.shared.trash(items: existing)
                    } catch {
                        // Copy succeeded but trash failed — files are now in both locations.
                        // Restore clipboard as non-cut so the user can retry the delete manually.
                        clipboardItems = existing
                        clipboardIsCut = false
                        errorMessage = "Files were copied but could not be removed from the original location: \(error.localizedDescription)"
                    }
                }
            } catch {
                // Copy failed — restore the clipboard to its original cut state so user can retry.
                if isCut {
                    clipboardItems = items
                    clipboardIsCut = true
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func startRename(_ item: FileItem) {
        renamingItem = item
        renameText = item.name
    }

    func commitRename(navigation: NavigationState) {
        guard let item = renamingItem else {
            renamingItem = nil
            return
        }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else {
            renamingItem = nil
            return
        }
        // Validate: macOS filenames cannot contain '/' or NUL, and '.' / '..' are reserved path components.
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            errorMessage = "The name cannot contain \"/\"."
            renamingItem = nil
            return
        }
        guard trimmed != ".", trimmed != ".." else {
            errorMessage = "The name \"\(trimmed)\" is reserved and cannot be used."
            renamingItem = nil
            return
        }
        let capturedItem = item
        renamingItem = nil
        Task {
            do {
                _ = try await fs.rename(item: capturedItem, to: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelRename() {
        renamingItem = nil
    }

    func duplicate() {
        let toDuplicate = selectedItems
        guard !toDuplicate.isEmpty else { return }
        Task {
            do {
                try await fs.duplicateItems(toDuplicate)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setTags(_ tags: [String], for item: FileItem) {
        Task {
            do {
                try await fs.setTags(tags, for: item.url)
                // Tag changes write xattrs on the file, not the directory, so the watcher
                // never fires. Update the item in-place so dots appear immediately.
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    let old = items[idx]
                    items[idx] = FileItem(
                        id: old.id, url: old.url, name: old.name,
                        isDirectory: old.isDirectory, isPackage: old.isPackage,
                        isHidden: old.isHidden, isSymlink: old.isSymlink,
                        fileSize: old.fileSize, contentModificationDate: old.contentModificationDate,
                        creationDate: old.creationDate, kind: old.kind, tags: tags
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func compress(currentURL: URL) {
        let toCompress = selectedItems
        guard !toCompress.isEmpty else { return }
        Task {
            do {
                try await fs.compress(toCompress, in: currentURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    /// URLs currently marked as cut — views should display these at reduced opacity.
    var cutURLs: Set<URL> {
        clipboardIsCut ? Set(clipboardItems.map(\.url)) : []
    }

    /// Filtered and sorted view of items — use this in all views instead of `items` directly.
    var sortedItems: [FileItem] {
        let base: [FileItem]
        if searchQuery.isEmpty {
            base = items
        } else {
            base = items.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        return base.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let ascending: Bool
            switch sortKey {
            case .name:
                ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .dateModified:
                let aDate = a.contentModificationDate ?? .distantPast
                let bDate = b.contentModificationDate ?? .distantPast
                ascending = aDate < bDate
            case .size:
                ascending = (a.fileSize ?? -1) < (b.fileSize ?? -1)
            case .kind:
                ascending = a.kind.localizedCaseInsensitiveCompare(b.kind) == .orderedAscending
            }
            return sortAscending ? ascending : !ascending
        }
    }

}
