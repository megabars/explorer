import SwiftUI

struct FileListView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState
    let sidebar: SidebarViewModel

    var body: some View {
        FileListNSTableView(
            items: browser.sortedItems,
            selection: $browser.selection,
            renamingItem: browser.renamingItem,
            renameText: { id in browser.renamingItem?.id == id ? browser.renameText : nil },
            onOpen: { item in
                browser.open(item, navigation: navigation)
            },
            onNewFolder: { browser.newFolder(in: navigation.currentURL) },
            onRename: { browser.startRename($0) },
            onRenameTextChange: { id, text in
                guard browser.renamingItem?.id == id else { return }
                browser.renameText = text
            },
            onCommitRename: { id, text in
                guard browser.renamingItem?.id == id else { return }
                browser.renameText = text
                browser.commitRename(navigation: navigation)
            },
            onCancelRename: { id in
                guard browser.renamingItem?.id == id else { return }
                browser.cancelRename()
            },
            onTrash: { browser.trash(items: $0) },
            onSelectionAnchorChanged: { browser.lastSelectedURL = $0 },
            onError: { browser.errorMessage = $0 },
            onCut: { browser.cut() },
            onCopy: { browser.copy() },
            onPaste: { browser.paste(into: navigation.currentURL) },
            canPaste: { browser.canPaste },
            onDuplicate: { browser.duplicate() },
            onCompress: { browser.compress(currentURL: navigation.currentURL) },
            onSetTags: { item, tags in browser.setTags(tags, for: item) },
            onAddToSidebar: { url in sidebar.addFavorite(url: url) },
            currentURL: navigation.currentURL,
            onDrop: { urls, destination, transfer in
                Task {
                    do {
                        switch transfer {
                        case .copy:
                            let items = urls.map { url in
                                FileItem(id: url, url: url, name: url.lastPathComponent,
                                         isDirectory: false, isPackage: false, isHidden: false,
                                         isSymlink: false, fileSize: nil, contentModificationDate: nil,
                                         creationDate: nil, kind: "", tags: [])
                            }
                            try await FileSystemService.shared.copy(items: items, to: destination)
                        case .move:
                            try await FileSystemService.shared.move(from: urls, to: destination)
                        }
                    } catch {
                        browser.errorMessage = error.localizedDescription
                    }
                }
            },
            tagsColumnVisible: browser.showTagsColumn,
            onTagsColumnVisibilityChanged: { browser.showTagsColumn = $0 },
            cutURLs: browser.cutURLs,
            sortKey: browser.sortKey,
            sortAscending: browser.sortAscending,
            onSortChange: { key, ascending in
                browser.sortKey = key
                browser.sortAscending = ascending
            }
        )
    }
}
