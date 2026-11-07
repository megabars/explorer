import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class BrowserViewModel {
    var items: [FileItem] = []
    var selection: Set<URL> {
        get { selectedURLs }
        set {
            guard selectedURLs != newValue else { return }
            selectedURLs = newValue
            selectionRevision &+= 1
        }
    }
    private var selectedURLs: Set<URL> = []
    private var selectionRevision: UInt64 = 0
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
    private(set) var clipboardItems: [FileItem] = []
    private(set) var clipboardIsCut: Bool = false

    // Undo state — stores the last file operation for Cmd+Z
    struct UndoableAction {
        struct TrashedItem {
            let originalURL: URL
            let trashedURL: URL
        }
        let items: [TrashedItem]
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
    var searchQuery: String = "" {
        didSet {
            let previousSelection = selectedURLs
            pruneSelection()
            if previousSelection != selectedURLs { selectionRevision &+= 1 }
        }
    }

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
    private let fs: FileSystemService
    private let pasteboard: NSPasteboard
    private let directoryLoader: @Sendable (URL, Bool) async throws -> [FileItem]
    private let recycle: @MainActor ([FileItem]) async throws -> [URL: URL]
    private var currentURL: URL?
    private var navigationGeneration: UInt64 = 0
    private var listingGeneration: UInt64 = 0
    private var reloadRequested = false
    private var pendingRenameName: String?
    private struct RenamedSelection {
        let originalURL: URL
        let destinationURL: URL
        let revision: UInt64
        let wasAnchor: Bool
    }
    private var renamedSelections: [RenamedSelection] = []
    private var clipboardChangeCount: Int?
    private var isPasting = false

    init(
        fileSystem: FileSystemService = .shared,
        pasteboard: NSPasteboard = .general,
        directoryLoader: (@Sendable (URL, Bool) async throws -> [FileItem])? = nil,
        recycle: (@MainActor ([FileItem]) async throws -> [URL: URL])? = nil
    ) {
        self.fs = fileSystem
        self.pasteboard = pasteboard
        self.recycle = recycle ?? { try await TrashService.shared.trash(items: $0) }
        self.directoryLoader = directoryLoader ?? { url, showHidden in
            try await fileSystem.listDirectory(at: url, showHidden: showHidden)
        }
    }

    // MARK: - Loading

    @discardableResult
    func load(url: URL) -> Task<Void, Never> {
        loadTask?.cancel()
        navigationGeneration &+= 1
        listingGeneration &+= 1
        let generation = navigationGeneration
        let request = listingGeneration
        currentURL = url.standardizedFileURL
        isLoading = true
        loadError = nil
        items = []
        selection = []
        lastSelectedURL = nil
        pendingRenameName = nil
        renamedSelections.removeAll()
        cancelRename()
        reloadRequested = false
        let hidden = showHidden

        let task = Task {
            do {
                let loaded = try await directoryLoader(url, hidden)
                guard !Task.isCancelled, isCurrent(url, generation: generation),
                      listingGeneration == request else { return }
                applyListing(loaded)
            } catch {
                guard !Task.isCancelled, isCurrent(url, generation: generation),
                      listingGeneration == request else { return }
                loadError = error.localizedDescription
                items = []
            }
            isLoading = false
            if reloadRequested {
                reloadRequested = false
                await reload(url: url, generation: generation)
            }
        }
        loadTask = task
        watcher.start(watching: url) { [weak self] in
            guard let self, self.isCurrent(url, generation: generation) else { return }
            Task { await self.reload(url: url, generation: generation) }
        }
        return task
    }

    private func isCurrent(_ url: URL, generation: UInt64) -> Bool {
        navigationGeneration == generation && currentURL == url.standardizedFileURL
    }

    private func reload(url: URL, generation: UInt64) async {
        guard isCurrent(url, generation: generation) else { return }
        guard !isLoading else {
            reloadRequested = true
            return
        }
        listingGeneration &+= 1
        let request = listingGeneration
        do {
            let loaded = try await directoryLoader(url, showHidden)
            guard isCurrent(url, generation: generation), listingGeneration == request else { return }
            applyListing(loaded)
            loadError = nil
        } catch {
            guard isCurrent(url, generation: generation), listingGeneration == request else { return }
            loadError = error.localizedDescription
        }
    }

    private func applyListing(_ loaded: [FileItem]) {
        items = loaded
        restoreRenamedSelections()
        pruneSelection()
        // Listing URLs may canonicalize a symlinked parent or add a directory slash.
        // This listing is already scoped to the current navigation generation.
        if let pending = pendingRenameName,
           let item = loaded.first(where: { $0.isDirectory && $0.name == pending }) {
            pendingRenameName = nil
            // A newly created folder must be visible before entering inline rename.
            if !searchQuery.isEmpty { searchQuery = "" }
            selection = [item.url]
            startRename(item)
        } else if let renamingItem, !loaded.contains(where: { $0.id == renamingItem.id }) {
            cancelRename()
        }
    }

    private func pruneSelection() {
        let visible = Set(filteredItems.map(\.url))
        // Keep the selection revision when a watcher removes the old row during a rename.
        selectedURLs.formIntersection(visible)
        if let lastSelectedURL, !visible.contains(lastSelectedURL) { self.lastSelectedURL = nil }
        if let renamingItem, !visible.contains(renamingItem.url) { cancelRename() }
    }

    private func restoreRenamedSelections() {
        guard !renamedSelections.isEmpty else { return }
        let visible = filteredItems
        var restored = selectedURLs
        for update in renamedSelections where update.revision == selectionRevision {
            let path = update.destinationURL.standardizedFileURL.path
            guard let item = visible.first(where: { $0.url.standardizedFileURL.path == path }) else { continue }
            restored.remove(update.originalURL)
            restored.insert(item.url)
            if lastSelectedURL == update.originalURL || (lastSelectedURL == nil && update.wasAnchor) {
                lastSelectedURL = item.url
            }
        }
        selectedURLs = restored
        renamedSelections.removeAll()
    }

    func stopWatching() {
        navigationGeneration &+= 1
        listingGeneration &+= 1
        currentURL = nil
        pendingRenameName = nil
        renamedSelections.removeAll()
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
            FileOpening.open(item.url) { [weak self] in self?.errorMessage = $0 }
        }
    }

    // MARK: - File Operations

    func trash(navigation: NavigationState) {
        trash(items: selectedItems)
    }

    @discardableResult
    func trash(items: [FileItem]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        return Task {
            do {
                let mapping = try await recycle(items)
                recordTrash(mapping: mapping, items: items)
            } catch let failure as TrashService.PartialFailure {
                recordTrash(mapping: failure.mapping, items: items)
                errorMessage = failure.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recordTrash(mapping: [URL: URL], items: [FileItem]) {
        let restoredPairs = items.compactMap { item -> UndoableAction.TrashedItem? in
            guard let trashed = mapping[item.url] else { return nil }
            return .init(originalURL: item.url, trashedURL: trashed)
        }
        if !restoredPairs.isEmpty { lastAction = UndoableAction(items: restoredPairs) }
    }

    /// Undoes the last undoable action (currently: restoring trashed files).
    @discardableResult
    func undo() -> Task<Void, Never>? {
        guard let action = lastAction else { return nil }
        lastAction = nil
        return Task {
            var remaining: [UndoableAction.TrashedItem] = []
            var failures: [String] = []
            for item in action.items {
                do {
                    try await fs.restore(from: item.trashedURL, to: item.originalURL)
                } catch {
                    remaining.append(item)
                    failures.append(L10n.format("%@: %@", item.originalURL.lastPathComponent, error.localizedDescription))
                }
            }
            if !failures.isEmpty {
                errorMessage = L10n.format("Undo failed:\n%@", failures.joined(separator: "\n"))
                // Do not overwrite a newer undo record created while restore was running.
                if lastAction == nil { lastAction = UndoableAction(items: remaining) }
            }
        }
    }

    @discardableResult
    func newFolder(in url: URL) -> Task<Void, Never> {
        let generation = navigationGeneration
        return Task {
            do {
                var name = L10n.text("New Folder")
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
                                userInfo: [NSLocalizedDescriptionKey: L10n.text("Could not create a unique folder name.")]
                            )
                        }
                        name = L10n.format("New Folder %lld", counter)
                        counter += 1
                    }
                }
                // Complete the filesystem operation even after navigation, but never apply
                // its old directory listing or rename state to the new location.
                guard isCurrent(url, generation: generation) else { return }
                pendingRenameName = name
                if isLoading { await loadTask?.value }
                guard isCurrent(url, generation: generation) else { return }
                await reload(url: url, generation: generation)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static let cutPasteboardType = NSPasteboard.PasteboardType("com.explorer.cut")

    private var pasteboardURLs: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    var canPaste: Bool { !isPasting && !pasteboardURLs.isEmpty }

    /// Called when returning from another app, which may have replaced our clipboard.
    func refreshClipboard() {
        if clipboardChangeCount != pasteboard.changeCount {
            clipboardItems = []
            clipboardIsCut = false
            clipboardChangeCount = nil
        }
    }

    func copy() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        writeToSystemPasteboard(items: selected, isCut: false)
    }

    func cut() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        writeToSystemPasteboard(items: selected, isCut: true)
    }

    private func writeToSystemPasteboard(items: [FileItem], isCut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map(\.url) as [NSURL])
        if isCut { pasteboard.setData(Data(), forType: Self.cutPasteboardType) }
        clipboardItems = items
        clipboardIsCut = isCut
        clipboardChangeCount = pasteboard.changeCount
    }

    /// Keyboard and context-menu commands deliberately share the same clipboard path.
    @discardableResult
    func pasteFromSystemPasteboard(into destination: URL) -> Task<Void, Never>? {
        paste(into: destination)
    }

    @discardableResult
    func paste(into destination: URL) -> Task<Void, Never>? {
        guard !isPasting else { return nil }
        let changeCount = pasteboard.changeCount
        let urls = pasteboardURLs
        let isCut = pasteboard.data(forType: Self.cutPasteboardType) != nil
        // URLs and cut intent must belong to the same pasteboard generation.
        guard pasteboard.changeCount == changeCount else {
            refreshClipboard()
            return nil
        }
        guard !urls.isEmpty else {
            refreshClipboard()
            return nil
        }
        isPasting = true
        return Task {
            defer { isPasting = false }
            let fileItems = urls.map { url in
                FileItem(id: url, url: url, name: url.lastPathComponent,
                         isDirectory: false, isPackage: false, isHidden: false,
                         isSymlink: false, fileSize: nil, contentModificationDate: nil,
                         creationDate: nil, kind: "", tags: [])
            }
            var completed = 0
            do {
                if isCut {
                    // Track each successful move so a partial failure can be retried
                    // without trying to move sources that have already disappeared.
                    for url in urls {
                        try await fs.move(from: [url], to: destination)
                        completed += 1
                    }
                } else {
                    try await fs.copy(items: fileItems, to: destination)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            if isCut, pasteboard.changeCount == changeCount {
                if completed == urls.count {
                    pasteboard.clearContents()
                    clipboardItems = []
                    clipboardIsCut = false
                    clipboardChangeCount = nil
                } else if completed > 0 {
                    writeToSystemPasteboard(items: Array(fileItems.dropFirst(completed)), isCut: true)
                }
            }
            refreshClipboard()
        }
    }

    func startRename(_ item: FileItem) {
        renamingItem = item
        renameText = item.name
    }

    @discardableResult
    func commitRename(navigation: NavigationState) -> Task<Void, Never>? {
        guard let item = renamingItem else { return nil }
        let name = renameText
        renamingItem = nil
        guard !name.isEmpty, name != item.name else { return nil }
        // Validate: macOS filenames cannot contain '/' or NUL
        guard !name.contains("/"), !name.contains("\0") else {
            errorMessage = L10n.text("The name cannot contain \"/\" or a NUL character.")
            return nil
        }
        let generation = navigationGeneration
        let navigationRevision = navigation.revision
        let directory = currentURL
        let revision = selectionRevision
        let wasSelected = selection.contains(item.url)
        let wasAnchor = lastSelectedURL == item.url
        return Task {
            do {
                let destination = try await fs.rename(item: item, to: name)
                guard let directory, isCurrent(directory, generation: generation),
                      navigation.revision == navigationRevision else { return }
                if wasSelected, revision == selectionRevision {
                    renamedSelections.append(.init(
                        originalURL: item.url, destinationURL: destination,
                        revision: revision, wasAnchor: wasAnchor
                    ))
                }
                await reload(url: directory, generation: generation)
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
                // Update immediately rather than waiting for the coalesced file event.
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
        guard !isLoading else { return [] }
        return filteredItems.filter { selection.contains($0.url) }
    }

    /// URLs currently marked as cut — views should display these at reduced opacity.
    var cutURLs: Set<URL> {
        clipboardIsCut && clipboardChangeCount == pasteboard.changeCount
            ? Set(clipboardItems.map(\.url)) : []
    }

    private var filteredItems: [FileItem] {
        searchQuery.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    /// Directories remain first; equal primary keys use the name and URL as stable ties.
    var sortedItems: [FileItem] {
        filteredItems.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sortKey {
            case .name:
                order = a.name.localizedCaseInsensitiveCompare(b.name)
            case .dateModified:
                order = (a.contentModificationDate ?? .distantPast).compare(b.contentModificationDate ?? .distantPast)
            case .size:
                let left = a.fileSize ?? -1
                let right = b.fileSize ?? -1
                order = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .kind:
                order = a.kind.localizedCaseInsensitiveCompare(b.kind)
            }
            if order != .orderedSame {
                return order == (sortAscending ? .orderedAscending : .orderedDescending)
            }
            let nameOrder = a.name.localizedCaseInsensitiveCompare(b.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return a.url.absoluteString < b.url.absoluteString
        }
    }
}
