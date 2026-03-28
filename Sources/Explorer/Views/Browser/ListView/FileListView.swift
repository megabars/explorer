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
            renameText: Binding(
                get: { browser.renameText },
                set: { browser.renameText = $0 }
            ),
            onOpen: { item in
                browser.open(item, navigation: navigation)
            },
            onCommitRename: {
                browser.commitRename(navigation: navigation)
            },
            onCancelRename: {
                browser.cancelRename()
            },
            onTrash: { item in
                browser.trash(items: [item])
            },
            onCut: { browser.cut() },
            onCopy: { browser.copy() },
            onPaste: { browser.paste(into: navigation.currentURL) },
            hasPasteContent: !browser.clipboardItems.isEmpty,
            onDuplicate: { browser.duplicate() },
            onCompress: { browser.compress(currentURL: navigation.currentURL) },
            onSetTags: { item, tags in browser.setTags(tags, for: item) },
            onAddToSidebar: { url in sidebar.addFavorite(url: url) },
            onMove: { urls, destination in
                Task {
                    do {
                        try await FileSystemService.shared.move(from: urls, to: destination)
                    } catch {
                        browser.errorMessage = error.localizedDescription
                    }
                }
            },
            tagsColumnVisible: browser.showTagsColumn,
            onTagsColumnVisibilityChanged: { browser.showTagsColumn = $0 },
            sortKey: browser.sortKey,
            sortAscending: browser.sortAscending,
            onSortChange: { key, ascending in
                browser.sortKey = key
                browser.sortAscending = ascending
            }
        )
    }
}
