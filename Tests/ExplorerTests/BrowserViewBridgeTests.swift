import AppKit
import SwiftUI
import Testing
@testable import Explorer

@Suite(.serialized)
@MainActor
struct BrowserViewBridgeTests {
    @Test
    func testRowsKeepTheirIdentityDuringRenameAndApplyPendingChangesOnExit() throws {
        let first = item(named: "first")
        let second = item(named: "second")
        let third = item(named: "third")
        let selection = Selection([first.url])
        let parent = list(items: [first, second], selection: selection, renaming: first)
        let (table, coordinator) = makeTable(for: parent)

        coordinator.parent = list(items: [third, second, first], selection: selection, renaming: first)
        coordinator.updateRows(in: table)

        #expect(table.numberOfRows == 2)
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        let draggedItem = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0))
        let pasteboard = NSPasteboard(name: .init("ExplorerDragTest-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([draggedItem]))
        let draggedURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(draggedURLs == [first.url])
        #expect(pasteboard.data(forType: .init(GridFileTransfer.internalType)) != nil)

        coordinator.parent = list(items: [third, second, first], selection: selection)
        coordinator.updateRows(in: table)

        #expect(table.numberOfRows == 3)
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(selection.urls == [first.url])
    }

    @Test(arguments: [true, false])
    func testStaleFieldCannotChangeOrFinishNewRename(commit: Bool) async throws {
        let first = item(named: "first")
        let second = item(named: "second")
        let pasteboard = NSPasteboard(name: .init("ExplorerRenameTest-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let browser = BrowserViewModel(pasteboard: pasteboard)
        browser.items = [first, second]
        browser.startRename(first)
        let view = FileListView(browser: browser, navigation: NavigationState(), sidebar: SidebarViewModel())
        let parent = try #require(view.body as? FileListNSTableView)
        let (table, coordinator) = makeTable(for: parent)
        let nameColumn = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(nameColumn)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView()
        scrollView.documentView = table
        window.contentView = scrollView
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        let nameColumnIndex = table.column(withIdentifier: nameColumn.identifier)
        let cell = try #require(table.view(atColumn: nameColumnIndex, row: 0, makeIfNecessary: false) as? NSTableCellView)
        let field = try #require(cell.textField)
        let editor = try #require(field.currentEditor() as? NSTextView)

        // Simulate the model starting a new rename before SwiftUI refreshes the bridge.
        browser.startRename(second)
        editor.string = "Stale draft"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(browser.renameText == second.name)

        let command = commit ? #selector(NSResponder.insertNewline(_:)) : #selector(NSResponder.cancelOperation(_:))
        #expect(coordinator.control(field, textView: editor, doCommandBy: command))
        #expect(browser.renamingItem?.id == second.id)
        #expect(browser.renameText == second.name)
    }

    @Test
    func testSameURLUpdatesCellMetadataAndCutOpacity() throws {
        let file = item(named: "note.txt", kind: "Text")
        let selection = Selection([file.url])
        let (table, coordinator) = makeTable(for: list(items: [file], selection: selection))
        let kind = try #require(table.tableColumn(withIdentifier: .init("kind")))

        let updated = item(named: "note.txt", kind: "Updated")
        coordinator.parent = list(items: [updated], selection: selection)
        coordinator.updateRows(in: table)
        let updatedCell = try #require(coordinator.tableView(table, viewFor: kind, row: 0) as? NSTableCellView)
        #expect(updatedCell.textField?.stringValue == "Updated")
        #expect(updatedCell.alphaValue == 1.0)

        coordinator.parent = list(items: [updated], selection: selection, cutURLs: [file.url])
        coordinator.updateRows(in: table)
        let cutCell = try #require(coordinator.tableView(table, viewFor: kind, row: 0) as? NSTableCellView)
        #expect(abs(cutCell.alphaValue - 0.4) < 0.01)
        #expect(selection.urls == [file.url])
    }

    @Test
    func testCopyOnlyDragToEmptyListUsesCurrentDirectoryAndCopy() {
        let source = URL(fileURLWithPath: "/tmp/elsewhere/note.txt")
        var accepted: (urls: [URL], destination: URL, transfer: FileListNSTableView.DropTransfer)?
        let parent = list(items: [], selection: Selection([])) { urls, destination, transfer in
            accepted = (urls, destination, transfer)
        }
        let (table, coordinator) = makeTable(for: parent)
        let drag = FileDrag(url: source, mask: .copy)

        #expect(coordinator.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .copy)
        #expect(coordinator.tableView(table, acceptDrop: drag, row: -1, dropOperation: .on))
        #expect(accepted?.urls == [source])
        #expect(accepted?.destination == directory)
        #expect(accepted?.transfer == .copy)
    }

    @Test
    func testDropRejectsUnsupportedOperationAndDoesNotReuseEarlierValidation() {
        let folder = item(named: "folder", directory: true)
        let parent = list(items: [folder], selection: Selection([])) { _, _, _ in
            Issue.record("An unsupported operation should never transfer a file.")
        }
        let (table, coordinator) = makeTable(for: parent)
        let drag = FileDrag(url: URL(fileURLWithPath: "/tmp/elsewhere/note.txt"), mask: .move)

        #expect(coordinator.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on) == .move)
        drag.draggingSourceOperationMask = .link
        #expect(coordinator.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on).isEmpty)
        #expect(!coordinator.tableView(table, acceptDrop: drag, row: 0, dropOperation: .on))
    }

    private let directory = URL(fileURLWithPath: "/tmp/browser-tests-\(UUID())", isDirectory: true)

    private func item(named name: String, kind: String = "", directory isDirectory: Bool = false) -> FileItem {
        let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
        return FileItem(id: url, url: url, name: name, isDirectory: isDirectory, isPackage: false,
                        isHidden: false, isSymlink: false, fileSize: nil, contentModificationDate: nil,
                        creationDate: nil, kind: kind, tags: [])
    }

    private func list(
        items: [FileItem],
        selection: Selection,
        renaming: FileItem? = nil,
        cutURLs: Set<URL> = [],
        onDrop: @escaping ([URL], URL, FileListNSTableView.DropTransfer) -> Void = { _, _, _ in }
    ) -> FileListNSTableView {
        FileListNSTableView(
            items: items, selection: Binding(get: { selection.urls }, set: { selection.urls = $0 }),
            renamingItem: renaming, renameText: { id in renaming?.id == id ? renaming?.name : nil },
            onOpen: { _ in }, onNewFolder: {}, onRename: { _ in },
            onRenameTextChange: { _, _ in }, onCommitRename: { _, _ in },
            onCancelRename: { _ in }, onTrash: { _ in }, onSelectionAnchorChanged: { _ in }, onError: { _ in },
            onCut: {}, onCopy: {}, onPaste: {}, canPaste: { false }, onDuplicate: {}, onCompress: {},
            onSetTags: { _, _ in }, onAddToSidebar: nil, currentURL: directory, onDrop: onDrop,
            tagsColumnVisible: true, onTagsColumnVisibilityChanged: { _ in }, cutURLs: cutURLs,
            sortKey: .name, sortAscending: true, onSortChange: { _, _ in }
        )
    }

    private func makeTable(for parent: FileListNSTableView) -> (NSTableView, FileListNSTableView.Coordinator) {
        _ = NSApplication.shared
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("kind")))
        let coordinator = parent.makeCoordinator()
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.tableView = table
        coordinator.updateRows(in: table)
        return (table, coordinator)
    }

    @MainActor
    private final class Selection {
        var urls: Set<URL>

        init(_ urls: Set<URL>) { self.urls = urls }
    }
}

@MainActor
private final class FileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation
    let draggingSequenceNumber = 1
    let draggingDestinationWindow: NSWindow? = nil
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(url: URL, mask: NSDragOperation) {
        draggingSourceOperationMask = mask
        super.init()
        draggingPasteboard.writeObjects([url as NSURL])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func resetSpringLoading() {}
}
