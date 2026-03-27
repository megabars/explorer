import SwiftUI

struct ExplorerToolbar: ToolbarContent {
    let navigation: NavigationState
    @Bindable var browser: BrowserViewModel
    @Bindable var addressBar: AddressBarViewModel
    let fsService: FileSystemService

    var body: some ToolbarContent {
        // Back / Forward / Up
        ToolbarItemGroup(placement: .navigation) {
            Button {
                navigation.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!navigation.canGoBack)
            .help("Back")

            Button {
                navigation.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigation.canGoForward)
            .help("Forward")

            Button {
                navigation.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!navigation.canGoUp)
            .help("Go Up")
        }

        // Address bar — stretches to fill available space
        ToolbarItem(placement: .principal) {
            AddressBarView(
                vm: addressBar,
                navigation: navigation,
                fsService: fsService,
                showHidden: browser.showHidden
            )
            .frame(minWidth: 500, maxWidth: .infinity)
        }

        // View mode picker + controls on the right
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View Mode", selection: $browser.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 70)
            .help("Switch view mode")

            Button {
                browser.showHidden.toggle()
                browser.load(url: navigation.currentURL)
            } label: {
                Image(systemName: browser.showHidden ? "eye" : "eye.slash")
            }
            .help(browser.showHidden ? "Hide Hidden Files" : "Show Hidden Files")

            Button {
                browser.newFolder(in: navigation.currentURL)
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")
        }
    }
}
