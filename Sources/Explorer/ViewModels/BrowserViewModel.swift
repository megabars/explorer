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
        let toTrash = selectedItems
        guard !toTrash.isEmpty else { return }
        Task {
            do {
                try await TrashService.shared.trash(items: toTrash)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func newFolder(in url: URL) {
        Task {
            let name = uniqueName("New Folder", in: url)
            let newURL = url.appendingPathComponent(name)
            do {
                try await fs.createDirectory(at: newURL)
                // Start renaming the new folder
                if let newItem = items.first(where: { $0.url == newURL }) {
                    startRename(newItem)
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
        let items = clipboardItems
        Task {
            do {
                try await fs.copy(items: items, to: destination)
                if clipboardIsCut {
                    try await TrashService.shared.trash(items: items)
                    clipboardItems = []
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
        Task {
            do {
                _ = try await fs.rename(item: item, to: renameText)
            } catch {
                errorMessage = error.localizedDescription
            }
            renamingItem = nil
        }
    }

    func cancelRename() {
        renamingItem = nil
    }

    // MARK: - Helpers

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    private func uniqueName(_ base: String, in url: URL) -> String {
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }
}
