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
        guard !isLoading else { return }
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
            do {
                let name = await fs.uniqueName(for: "New Folder", in: url)
                let newURL = url.appendingPathComponent(name)
                try await fs.createDirectory(at: newURL)
                // Reload explicitly so the new folder appears in items before we rename
                let loaded = try await fs.listDirectory(at: url, showHidden: showHidden)
                items = loaded
                if let newItem = items.first(where: { $0.url == newURL }) {
                    startRename(newItem)
                } else {
                    // Item not found after reload — directory watcher may have missed the event
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
                    // Clear clipboard after a successful cut+paste (fix 20)
                    clipboardItems = []
                    clipboardIsCut = false
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
