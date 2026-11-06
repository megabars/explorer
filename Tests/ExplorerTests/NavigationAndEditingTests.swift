import AppKit
import Testing
@testable import Explorer

@MainActor
struct NavigationAndEditingTests {
    @Test
    func equivalentDirectoryURLsDoNotCreateHistory() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let location = NavigationState(startURL: folder)

        location.navigate(to: URL(fileURLWithPath: folder.path + "/."))
        location.navigate(to: URL(fileURLWithPath: folder.path, isDirectory: false))
        #expect(location.isCurrentLocation(folder))
        #expect(!location.canGoBack)
        #expect(location.revision == 0)

        location.goUp()
        location.goBack()
        #expect(location.isCurrentLocation(folder))
        #expect(location.canGoForward)
        #expect(location.revision == 2)
    }

    @Test
    func invalidAddressKeepsInputForCorrection() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = AddressBarViewModel()
        let service = FileSystemService()
        let missingPath = folder.appendingPathComponent("missing").path
        address.beginEditing(from: folder)
        address.textDidChange(missingPath, service: service, showHidden: false)

        #expect(await address.commit(service: service) == nil)
        #expect(address.isEditing)
        #expect(address.editText == missingPath)
        #expect(address.commitError != nil)

        address.textDidChange(folder.path, service: service, showHidden: false)
        #expect(address.commitError == nil)
        #expect(await address.commit(service: service)?.path == folder.path)
        #expect(!address.isEditing)
    }

    @Test
    func navigationRoundTripInvalidatesAddressCommit() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = AddressBarViewModel()
        let service = FileSystemService()
        let navigation = NavigationState(startURL: folder)
        let revision = navigation.revision
        address.beginEditing(from: folder)
        address.textDidChange(folder.deletingLastPathComponent().path, service: service, showHidden: false)

        let destination = await address.commit(service: service) {
            navigation.goUp()
            navigation.goBack()
            return navigation.revision == revision
        }
        #expect(navigation.isCurrentLocation(folder))
        #expect(destination == nil)
        #expect(address.commitError == nil)
    }

    @Test
    func removingLastFavoritePersistsAndAvailabilityCanBeRechecked() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "ExplorerTests.Favorites." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = folder.appendingPathComponent("Favorite", isDirectory: true)
        defaults.set([favorite.absoluteString], forKey: "explorerFavorites")

        let sidebar = SidebarViewModel(defaults: defaults)
        let item = try #require(sidebar.favorites.first)
        await sidebar.refreshFavoriteAvailability()
        #expect(!sidebar.isAvailable(item))

        try FileManager.default.createDirectory(at: favorite, withIntermediateDirectories: false)
        #expect(await sidebar.refreshAvailability(for: item))
        #expect(sidebar.isAvailable(item))

        try FileManager.default.removeItem(at: favorite)
        try Data().write(to: URL(fileURLWithPath: favorite.path, isDirectory: false))
        #expect(!(await sidebar.refreshAvailability(for: item)))
        #expect(!sidebar.isAvailable(item))

        sidebar.removeFavorite(id: item.id)
        #expect(SidebarViewModel(defaults: defaults).favorites.isEmpty)
    }

    @Test
    func unchangedRenamePreservesExistingTrailingSpaces() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("report ")
        try Data().write(to: original)
        let item = FileItem(
            id: original, url: original, name: original.lastPathComponent,
            isDirectory: false, isPackage: false, isHidden: false, isSymlink: false,
            fileSize: nil, contentModificationDate: nil, creationDate: nil, kind: "", tags: []
        )
        let pasteboard = NSPasteboard(name: .init("ExplorerTests.Rename." + UUID().uuidString))
        let browser = BrowserViewModel(pasteboard: pasteboard)
        let navigation = NavigationState(startURL: folder)

        browser.startRename(item)
        #expect(browser.commitRename(navigation: navigation) == nil)
        #expect(FileManager.default.fileExists(atPath: original.path))

        browser.startRename(item)
        browser.renameText = "revised "
        let rename = try #require(browser.commitRename(navigation: navigation))
        await rename.value
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("revised ").path))
        #expect(browser.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func renameTransfersSelectionOnlyIfItHasNotChanged(selectAnotherFolder: Bool) async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Original", "Other"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        let pasteboard = NSPasteboard(name: .init("ExplorerTests.RenameSelection." + UUID().uuidString))
        let browser = BrowserViewModel(pasteboard: pasteboard)
        let navigation = NavigationState(startURL: folder)
        defer { browser.stopWatching() }
        await browser.load(url: navigation.currentURL).value
        let original = try #require(browser.items.first { $0.name == "Original" })
        let other = try #require(browser.items.first { $0.name == "Other" })

        browser.selection = [original.url]
        browser.lastSelectedURL = original.url
        browser.startRename(original)
        browser.renameText = "Renamed"
        let rename = try #require(browser.commitRename(navigation: navigation))
        if selectAnotherFolder {
            browser.selection = [other.url]
            browser.lastSelectedURL = other.url
        }
        await rename.value

        let renamed = try #require(browser.items.first { $0.name == "Renamed" })
        let selected = selectAnotherFolder ? other : renamed
        #expect(browser.selection == [selected.url])
        #expect(browser.selectedItems.map(\.url) == [selected.url])
        #expect(browser.lastSelectedURL == selected.url)
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
