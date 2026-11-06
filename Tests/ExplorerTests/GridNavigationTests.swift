import Foundation
import AppKit
import Testing
@testable import Explorer

struct GridNavigationTests {
    @Test func externalDropsCannotSilentlyMoveTheirSources() {
        #expect(GridFileTransfer.proposed(isInternal: false, optionPressed: false) == .copy)
        #expect(GridFileTransfer.proposed(isInternal: true, optionPressed: false) == .move)
        #expect(GridFileTransfer.proposed(isInternal: true, optionPressed: true) == .copy)
        let internalProvider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/internal") as NSURL)
        internalProvider.registerDataRepresentation(forTypeIdentifier: GridFileTransfer.internalType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        let externalProvider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/external") as NSURL)
        #expect(GridFileTransfer.accepted(.move, providers: [internalProvider]) == .move)
        #expect(GridFileTransfer.accepted(.move, providers: [internalProvider, externalProvider]) == .copy)
        #expect(GridFileTransfer.accepted(.move, providers: [externalProvider]) == .copy)
        #expect(GridFileTransfer.accepted(.move, providers: []) == .copy)
    }

    @Test func arrowsUseViewportColumnsAndStartAtFirstItem() {
        #expect(GridNavigation.columns(for: 280) == 3)
        #expect(GridNavigation.columns(for: 720) == 8)
        #expect(GridNavigation.columns(for: 50) == 1)
        #expect(GridNavigation.nextIndex(current: nil, offset: 8, count: 40) == 0)
        #expect(GridNavigation.nextIndex(current: 2, offset: 3, count: 40) == 5)
        #expect(GridNavigation.nextIndex(current: 38, offset: 3, count: 40) == 39)
        #expect(GridNavigation.nextIndex(current: 5, offset: -10, count: 20) == 5)
        #expect(GridNavigation.nextIndex(current: 11, offset: 10, count: 20) == 11)
        #expect(GridNavigation.nextIndex(current: 9, offset: 10, count: 13) == 12)
        #expect(GridNavigation.nextIndex(current: 12, offset: 10, count: 13) == 12)
    }

    @Test func selectionIsDeterministicAfterSwitchingViews() {
        let urls = (0..<6).map { URL(fileURLWithPath: "/tmp/item-\($0)") }
        #expect(GridNavigation.selectedIndex(items: urls, selection: [urls[2], urls[3]], preferred: urls[0]) == 2)
        #expect(GridNavigation.selectedIndex(items: urls, selection: [urls[2], urls[3]], preferred: urls[3]) == 3)
    }

    @Test func homeAbbreviationRequiresAWholePathComponent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(home.displayPath == "~")
        #expect(home.appendingPathComponent("file").displayPath == "~/file")
        let sibling = URL(fileURLWithPath: home.path + "-other/file")
        #expect(sibling.displayPath == sibling.path)
    }
}
