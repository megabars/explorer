import AppKit
import Testing
@testable import Explorer

private func makeBrowserItem(_ url: URL, directory: Bool = false, size: Int64 = 10) -> FileItem {
    FileItem(id: url, url: url, name: url.lastPathComponent, isDirectory: directory,
             isPackage: false, isHidden: false, isSymlink: false, fileSize: size,
             contentModificationDate: Date(timeIntervalSince1970: 100), creationDate: nil,
             kind: "Text", tags: [])
}

private actor ControlledListing {
    private var blockedURL: URL?
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func blockNext(_ url: URL) { blockedURL = url }

    func list(_ url: URL) async -> [FileItem] {
        if blockedURL == url {
            blockedURL = nil
            await withCheckedContinuation { continuation in
                pending = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        return [makeBrowserItem(url.appendingPathComponent("file-in-" + url.lastPathComponent))]
    }

    func waitUntilBlocked() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        pending?.resume()
        pending = nil
    }
}

@Suite(.serialized)
@MainActor
final class BrowserViewModelTests {
    private var temporaryURLs: [URL] = []
    private var pasteboardNames: [String] = []

    deinit {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        let names = pasteboardNames
        Task { @MainActor in
            for name in names { NSPasteboard(name: .init(name)).releaseGlobally() }
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerVMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func privatePasteboard() -> NSPasteboard {
        let name = "ExplorerTests-\(UUID().uuidString)"
        pasteboardNames.append(name)
        let pasteboard = NSPasteboard(name: .init(name))
        return pasteboard
    }

    @Test
    func testNewFolderCompletionDoesNotReplaceNavigatedDirectory() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let loader = ControlledListing()
        let vm = BrowserViewModel(pasteboard: privatePasteboard(), directoryLoader: { url, _ in await loader.list(url) })
        defer { vm.stopWatching() }
        await vm.load(url: a).value
        await loader.blockNext(a)
        let creation = vm.newFolder(in: a)
        await loader.waitUntilBlocked()
        await vm.load(url: b).value
        await loader.resume()
        await creation.value
        #expect(vm.items.map(\.name) == ["file-in-B"])
        #expect(vm.renamingItem == nil)
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("New Folder").path))
    }

    @Test
    func testCancelledInitialLoadCannotReplaceNewerLoad() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        let loader = ControlledListing()
        await loader.blockNext(a)
        let vm = BrowserViewModel(pasteboard: privatePasteboard(), directoryLoader: { url, _ in await loader.list(url) })
        defer { vm.stopWatching() }
        let stale = vm.load(url: a)
        await loader.waitUntilBlocked()
        await vm.load(url: b).value
        await loader.resume()
        await stale.value
        #expect(vm.items.map(\.name) == ["file-in-B"])
        #expect(!(vm.isLoading))
        #expect(vm.loadError == nil)
    }

    @Test
    func testNewFolderInCurrentDirectoryStartsRenameAndResolvesNameConflicts() async throws {
        let root = try temporaryDirectory()
        let fs = FileSystemService()
        let vm = BrowserViewModel(fileSystem: fs, pasteboard: privatePasteboard())
        defer { vm.stopWatching() }
        await vm.load(url: root).value
        await vm.newFolder(in: root).value
        #expect(vm.renamingItem?.name == "New Folder")
        vm.cancelRename()
        await vm.newFolder(in: root).value
        #expect(vm.renamingItem?.name == "New Folder 2")
        #expect(vm.errorMessage == nil)
    }

    @Test
    func testFilterPrunesSelectionAndExcludesHiddenOperationTargets() {
        let vm = BrowserViewModel(pasteboard: privatePasteboard())
        let hidden = makeBrowserItem(URL(fileURLWithPath: "/test/secret.txt"))
        let visible = makeBrowserItem(URL(fileURLWithPath: "/test/visible.txt"))
        vm.items = [hidden, visible]
        vm.selection = [hidden.url, visible.url]
        vm.lastSelectedURL = hidden.url
        vm.searchQuery = "visible"
        #expect(vm.selection == [visible.url])
        #expect(vm.lastSelectedURL == nil)
        // A delayed UI callback must not reintroduce hidden file operation targets.
        vm.selection.insert(hidden.url)
        #expect(vm.selectedItems.map(\.url) == [visible.url])
    }

    @Test
    func testSortingEqualKeysIsStableInBothDirectionsAndKeepsDirectoriesFirst() {
        let vm = BrowserViewModel(pasteboard: privatePasteboard())
        let files = ["c.txt", "a.txt", "b.txt"].map { makeBrowserItem(URL(fileURLWithPath: "/test/" + $0)) }
        let folder = makeBrowserItem(URL(fileURLWithPath: "/test/folder"), directory: true)
        for key: BrowserViewModel.SortKey in [.size, .dateModified, .kind] {
            for ascending in [true, false] {
                vm.items = files + [folder]
                vm.sortKey = key
                vm.sortAscending = ascending
                let first = vm.sortedItems
                #expect(first.map(\.name) == ["folder", "a.txt", "b.txt", "c.txt"])
                vm.items = first
                #expect(vm.sortedItems.map(\.url) == first.map(\.url))
            }
        }
        vm.items = files
        vm.sortKey = .name
        vm.sortAscending = false
        #expect(vm.sortedItems.map(\.name) == ["c.txt", "b.txt", "a.txt"])
    }

    @Test
    func testContextAndKeyboardPasteReadLatestSystemClipboard() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let old = source.appendingPathComponent("old.txt")
        let latest = source.appendingPathComponent("latest.txt")
        try Data("old".utf8).write(to: old)
        try Data("latest".utf8).write(to: latest)
        let pb = privatePasteboard()
        let vm = BrowserViewModel(pasteboard: pb)
        vm.items = [makeBrowserItem(old)]
        vm.selection = [old]
        vm.copy()
        pb.clearContents()
        #expect(pb.writeObjects([latest as NSURL]))
        #expect(vm.canPaste)
        await vm.paste(into: destination)?.value
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("latest.txt").path))
        #expect(!(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path)))
        await vm.pasteFromSystemPasteboard(into: destination)?.value
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("latest 2.txt").path))
        pb.clearContents()
        pb.setString("text replaces files", forType: .string)
        #expect(!(vm.canPaste))
        #expect(vm.paste(into: destination) == nil)
    }

    @Test
    func testCutPasteMovesAndClearsBothClipboardRepresentations() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("cut.txt")
        try Data("payload".utf8).write(to: source)
        let vm = BrowserViewModel(pasteboard: privatePasteboard())
        vm.items = [makeBrowserItem(source)]
        vm.selection = [source]
        vm.cut()
        #expect(vm.cutURLs == [source])
        let operation = vm.paste(into: destination)
        #expect(operation != nil)
        #expect(vm.paste(into: destination) == nil, "A second paste must not race the first cut")
        await operation?.value
        #expect(!(FileManager.default.fileExists(atPath: source.path)))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("cut.txt").path))
        #expect(!(vm.canPaste))
        #expect(vm.clipboardItems.isEmpty)
        #expect(vm.cutURLs.isEmpty)
    }

    @Test
    func testPartialCutFailureRetainsOnlyUnmovedSourcesForRetry() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let missing = root.appendingPathComponent("missing.txt")
        try Data("first".utf8).write(to: first)
        let vm = BrowserViewModel(pasteboard: privatePasteboard())
        vm.items = [makeBrowserItem(first), makeBrowserItem(missing)]
        vm.selection = [first, missing]
        vm.cut()
        await vm.paste(into: destination)?.value
        #expect(vm.errorMessage != nil)
        #expect(vm.clipboardItems.map(\.url) == [missing])
        #expect(vm.clipboardIsCut)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.txt").path))
        try Data("retry".utf8).write(to: missing)
        await vm.paste(into: destination)?.value
        #expect(!(vm.canPaste))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("missing.txt").path))
    }
    @Test
    func testUndoRestoresExactNameAndRetainsConflictingItemsForRetry() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("report.txt")
        let trashed = root.appendingPathComponent("report 2.txt")
        try Data("trashed payload".utf8).write(to: trashed)
        try Data("new original occupant".utf8).write(to: original)
        let vm = BrowserViewModel(pasteboard: privatePasteboard(), recycle: { _ in [original: trashed] })
        await vm.trash(items: [makeBrowserItem(original)])?.value
        await vm.undo()?.value
        #expect(vm.lastAction != nil)
        #expect(vm.errorMessage != nil)
        #expect(try String(contentsOf: original, encoding: .utf8) == "new original occupant")
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        try FileManager.default.removeItem(at: original)
        await vm.undo()?.value
        #expect(vm.lastAction == nil)
        #expect(!(FileManager.default.fileExists(atPath: trashed.path)))
        #expect(try String(contentsOf: original, encoding: .utf8) == "trashed payload")
    }

    @Test
    func testCutPasteDoesNotClearAClipboardReplacedDuringTheOperation() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.txt")
        let newer = root.appendingPathComponent("newer.txt")
        try Data("original".utf8).write(to: original)
        try Data("newer".utf8).write(to: newer)
        let pb = privatePasteboard()
        let vm = BrowserViewModel(pasteboard: pb)
        vm.items = [makeBrowserItem(original)]
        vm.selection = [original]
        vm.cut()
        let operation = vm.paste(into: destination)
        pb.clearContents()
        pb.writeObjects([newer as NSURL])
        let replacementCount = pb.changeCount
        await operation?.value
        #expect(pb.changeCount == replacementCount)
        #expect(vm.canPaste)
        #expect(vm.cutURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("original.txt").path))
        await vm.paste(into: destination)?.value
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("newer.txt").path))
    }

    @Test
    func testNewFolderAfterAddressBarNavigationKeepsRenameAcrossWatcherRefresh() async throws {
        let root = try temporaryDirectory()
        let addressBar = AddressBarViewModel()
        addressBar.beginEditing(from: root)
        addressBar.textDidChange(root.path + "/", service: .shared, showHidden: false)
        let destination = try #require(await addressBar.commit(service: .shared))
        let vm = BrowserViewModel(pasteboard: privatePasteboard())
        defer { vm.stopWatching() }
        await vm.load(url: destination).value
        await vm.newFolder(in: destination).value
        #expect(vm.renamingItem?.name == "New Folder")
        #expect(vm.selection.count == 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.renamingItem?.name == "New Folder")
        #expect(vm.selection.count == 1)
    }

    @Test
    func testPartialTrashFailureStillRecordsUndoForSuccessfulItems() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("restored.txt")
        let trashed = root.appendingPathComponent("restored 2.txt")
        let failed = root.appendingPathComponent("failed.txt")
        try Data("trashed".utf8).write(to: trashed)
        try Data("untouched".utf8).write(to: failed)
        let vm = BrowserViewModel(pasteboard: privatePasteboard(), recycle: { _ in
            throw TrashService.PartialFailure(mapping: [original: trashed], failures: ["failed.txt: access denied"])
        })
        await vm.trash(items: [makeBrowserItem(failed), makeBrowserItem(original)])?.value
        #expect(vm.errorMessage != nil)
        #expect(vm.lastAction?.items.count == 1)
        await vm.undo()?.value
        #expect(try String(contentsOf: original, encoding: .utf8) == "trashed")
        #expect(try String(contentsOf: failed, encoding: .utf8) == "untouched")
    }

}
