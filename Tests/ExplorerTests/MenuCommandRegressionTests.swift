import AppKit
import SwiftUI
import Testing
@testable import Explorer

@Suite(.serialized)
@MainActor
struct MenuCommandRegressionTests {
    @Test
    func selectAllAndRedoUseTheFocusedTextEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let editor = TestEditor(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        editor.string = "before"
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: editor) { target in
            MainActor.assumeIsolated {
                target.undoManager?.registerUndo(withTarget: target) { editor in
                    MainActor.assumeIsolated { editor.string = "after" }
                }
            }
        }
        undo.endUndoGrouping()
        undo.undo()

        var browserActions: [ExplorerCommand] = []
        ExplorerCommand.redo.perform(in: window) { browserActions.append(.redo) }
        ExplorerCommand.selectAll.perform(in: window) { browserActions.append(.selectAll) }
        #expect(editor.string == "after")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
        #expect(browserActions.isEmpty)

        window.makeFirstResponder(nil)
        ExplorerCommand.selectAll.perform(in: window) { browserActions.append(.selectAll) }
        ExplorerCommand.redo.perform(in: window) { browserActions.append(.redo) }
        #expect(browserActions == [.selectAll])
    }

    @Test
    func listTrashUsesTheVisibleSelectionWhenOpeningTheMenuOnASelectedRow() {
        let first = item("first")
        let second = item("second")
        let unselected = item("unselected")
        let hidden = item("filtered-out")
        var trashed: [URL] = []
        let bridge = list(items: [first, second, unselected], selection: [first.url, second.url, hidden.url]) {
            trashed = $0.map(\.url)
        }
        let coordinator = bridge.makeCoordinator()
        let menuItem = NSMenuItem()

        menuItem.representedObject = first.url
        coordinator.menuTrash(menuItem)
        #expect(trashed == [first.url, second.url])

        menuItem.representedObject = unselected.url
        coordinator.menuTrash(menuItem)
        #expect(trashed == [unselected.url])
    }

    @Test
    func listInitializesTheNativeSortStateFromTheModel() {
        _ = NSApplication.shared
        let bridge = list(items: [], selection: []) { _ in }
        let table = NSTableView()
        let coordinator = bridge.makeCoordinator()
        table.delegate = coordinator
        coordinator.syncSortDescriptors(in: table)
        #expect(table.sortDescriptors.first?.key == "dateModified")
        #expect(table.sortDescriptors.first?.ascending == false)
    }

    private let directory = URL(fileURLWithPath: "/tmp/explorer-menu-tests", isDirectory: true)

    private func item(_ name: String) -> FileItem {
        let url = directory.appendingPathComponent(name)
        return FileItem(id: url, url: url, name: name, isDirectory: false, isPackage: false,
                        isHidden: false, isSymlink: false, fileSize: nil, contentModificationDate: nil,
                        creationDate: nil, kind: "", tags: [])
    }

    private func list(items: [FileItem], selection: Set<URL>, onTrash: @escaping ([FileItem]) -> Void) -> FileListNSTableView {
        FileListNSTableView(
            items: items, selection: .constant(selection), renameText: { _ in nil }, onOpen: { _ in },
            onNewFolder: {}, onRename: { _ in }, onRenameTextChange: { _, _ in }, onCommitRename: { _, _ in },
            onCancelRename: { _ in }, onTrash: onTrash, onSelectionAnchorChanged: { _ in }, onError: { _ in },
            onCut: {}, onCopy: {}, onPaste: {}, canPaste: { false }, onDuplicate: {}, onCompress: {},
            onSetTags: { _, _ in }, currentURL: directory, onDrop: { _, _, _ in }, tagsColumnVisible: true,
            onTagsColumnVisibilityChanged: { _ in }, cutURLs: [], sortKey: .dateModified, sortAscending: false,
            onSortChange: { _, _ in Issue.record("Synchronizing from the model must not write back to it.") }
        )
    }
}

@MainActor
private final class TestEditor: NSTextView {
    let testUndoManager = UndoManager()

    override var undoManager: UndoManager? { testUndoManager }
}
