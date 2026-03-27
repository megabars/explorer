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

    // Clipboard state
    var clipboardItems: [FileItem] = []
    var clipboardIsCut: Bool = false

    // Rename state
    var renamingItem: FileItem?
    var renameText: String = ""

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
                guard !Task.isCancelled else { return }
                items = loaded
                selection = []
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                items = []
            }
            isLoading = false
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
                if let newItem = items.first(where: { $0.url == newURL }) {
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
        // Clear cut clipboard synchronously before the Task to prevent a second paste
        // from copying the same items if called rapidly.
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
                    try await TrashService.shared.trash(items: existing)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startRename(_ item: FileItem) {
        renamingItem = item
        renameText = item.name
    }

    func commitRename(navigation: NavigationState) {
        guard let item = renamingItem, !renameText.isEmpty, renameText != item.name else {
            renamingItem = nil
            return
        }
        // Clear renamingItem immediately before the async operation to avoid state race
        let capturedItem = item
        let capturedName = renameText
        renamingItem = nil
        Task {
            do {
                _ = try await fs.rename(item: capturedItem, to: capturedName)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelRename() {
        renamingItem = nil
    }

    // MARK: - Helpers

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

}
