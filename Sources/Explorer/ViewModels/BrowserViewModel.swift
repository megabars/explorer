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
    var errorMessage: String?
    var showHidden: Bool = false
    var showTagsColumn: Bool = UserDefaults.standard.object(forKey: "showTagsColumn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTagsColumn, forKey: "showTagsColumn") }
    }

    // Clipboard state
    var clipboardItems: [FileItem] = []
    var clipboardIsCut: Bool = false

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

    // Shift+Click anchor for range selection
    var lastSelectedURL: URL?

    private var loadTask: Task<Void, Never>?
    private let watcher = DirectoryWatcher()
    private let fs = FileSystemService.shared
    /// Suppresses watcher-triggered reloads during explicit reloads (e.g. after newFolder).
    private var suppressReload: Bool = false

    // MARK: - Loading

    func load(url: URL) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
                if Task.isCancelled { return }
                items = loaded
                selection = []
                isLoading = false
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                items = []
                isLoading = false
            }
        }

        watcher.start(watching: url) { [weak self] in
            guard let self else { return }
            Task { await self.reload(url: url) }
        }
    }

    private func reload(url: URL) async {
        guard !isLoading, !suppressReload else { return }
        do {
            let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
            items = loaded
        } catch {
            errorMessage = error.localizedDescription
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
                try await TrashService.shared.trash(items: items)
            } catch {
                errorMessage = error.localizedDescription
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
    }

    func cut() {
        clipboardItems = selectedItems
        clipboardIsCut = true
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
        // Validate: macOS filenames cannot contain '/' or NUL
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            errorMessage = "The name cannot contain \"/\"."
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
