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
                Label("Back", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(!navigation.canGoBack)
            .help("Back")

            Button {
                navigation.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .disabled(!navigation.canGoForward)
            .help("Forward")

            Button {
                navigation.goUp()
            } label: {
                Label("Go Up", systemImage: "arrow.up")
            }
            .labelStyle(.iconOnly)
            .disabled(!navigation.canGoUp)
            .help("Go Up")
        }

        // Address bar — stretches to fill available space.
        // minWidth is kept small so NSToolbar never moves it to the >> overflow menu;
        // the inner ScrollView handles long paths by scrolling horizontally.
        ToolbarItem(placement: .principal) {
            AddressBarView(
                vm: addressBar,
                navigation: navigation,
                fsService: fsService,
                showHidden: browser.showHidden
            )
            .frame(minWidth: 120, idealWidth: 480, maxWidth: .infinity)
        }

        // View mode picker + controls on the right
        ToolbarItem(id: "view-mode", placement: .primaryAction) {
            Picker("View Mode", selection: $browser.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .labelStyle(.iconOnly)
            .pickerStyle(.segmented)
            .frame(width: 70)
            .help("Switch view mode")
        }

        ToolbarItem(id: "hidden-files", placement: .primaryAction) {
            Button {
                browser.showHidden.toggle()
                browser.load(url: navigation.currentURL)
            } label: {
                Label(browser.showHidden ? "Hide Hidden Files" : "Show Hidden Files",
                      systemImage: browser.showHidden ? "eye" : "eye.slash")
            }
            .labelStyle(.iconOnly)
            .help(browser.showHidden ? "Hide Hidden Files" : "Show Hidden Files")
        }

        ToolbarItem(id: "new-folder", placement: .primaryAction) {
            Button {
                browser.newFolder(in: navigation.currentURL)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .help("New Folder (⇧⌘N)")
        }
    }
}
