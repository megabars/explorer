import SwiftUI

struct FileListView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState

    var body: some View {
        FileListNSTableView(
            items: browser.items,
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
            onContextMenu: { _, _ in }
        )
    }
}
