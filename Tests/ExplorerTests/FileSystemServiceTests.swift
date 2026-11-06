import Foundation
import Testing
@testable import Explorer

@Suite(.serialized)
struct FileSystemServiceTests {
    @Test
    @MainActor
    func testBlockedListingDoesNotBlockPathChecksOrWrites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (started, notification) = AsyncStream<Bool>.makeStream()
        let releaseListing = DispatchSemaphore(value: 0)
        defer { releaseListing.signal() }
        let service = FileSystemService(directoryContents: { _, _, _ in
            notification.yield(Thread.isMainThread)
            guard releaseListing.wait(timeout: .now() + .seconds(5)) == .success else {
                throw POSIXError(.ETIMEDOUT)
            }
            return []
        })
        let listing = Task { try await service.listDirectory(at: directory) }
        var listingStarted = started.makeAsyncIterator()
        try #require(await listingStarted.next() == false)

        let child = directory.appendingPathComponent("New Folder", isDirectory: true)
        #expect(await service.itemStatus(at: directory).isDirectory)
        #expect(await service.isReadable(at: directory))
        try await service.createDirectory(at: child)
        #expect(await service.itemStatus(at: child).isDirectory)

        releaseListing.signal()
        _ = try await listing.value
    }

    @Test
    func testCopyRejectsItsOwnDirectoryAndDescendantsThroughSymlinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Source", isDirectory: true)
        let child = source.appendingPathComponent("Child", isDirectory: true)
        let alias = directory.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let service = FileSystemService()

        for destination in [source, child, alias] {
            do {
                try await service.copy(items: [item(at: source)], to: destination)
                Issue.record("Expected recursive copy into \(destination.path) to fail")
            } catch {
                #expect(error.localizedDescription.contains("into itself or one of its subfolders"))
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["Child"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)

        // A symlink is copied as a link even when it points to the destination.
        try await service.copy(items: [item(at: alias)], to: child)
        #expect(try child.appendingPathComponent("Alias").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test
    func testPartialCopyReportsHowManyFilesWereCopied() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("first.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        let destination = directory.appendingPathComponent("Destination", isDirectory: true)
        try Data("first".utf8).write(to: existing)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try await FileSystemService().copy(items: [item(at: existing), item(at: missing)], to: destination)
            Issue.record("Expected missing input to fail the copy")
        } catch {
            #expect(error.localizedDescription.contains("Copied 1 of 2 items."))
            #expect(error.localizedDescription.contains("missing.txt"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["first.txt"])
    }

    @Test
    func testDuplicateKeepsTheExtensionOfAMaximumLengthName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent(String(repeating: "a", count: Int(NAME_MAX) - 4) + ".txt")
        let contents = Data("duplicate me".utf8)
        try contents.write(to: original)

        let service = FileSystemService()
        try await service.duplicateItems([item(at: original)])
        try await service.duplicateItems([item(at: original)])

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.count == 3)
        #expect(entries.contains(where: { $0.hasSuffix(" copy.txt") }))
        #expect(entries.contains(where: { $0.hasSuffix(" copy 2.txt") }))
        for entry in entries {
            #expect(entry.utf8.count <= Int(NAME_MAX))
            #expect(try Data(contentsOf: directory.appendingPathComponent(entry)) == contents)
        }
    }

    @Test
    func testListingAndCompletionRecognizeDirectorySymlinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        let package = directory.appendingPathComponent("App.app", isDirectory: true)
        let file = directory.appendingPathComponent("File.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data().write(to: file)
        for (name, target) in [
            ("LinkFolder", folder),
            ("LinkPackage", package),
            ("LinkFile", file),
            ("LinkMissing", directory.appendingPathComponent("Missing"))
        ] {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: target)
        }

        let service = FileSystemService()
        let items = try await service.listDirectory(at: directory)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["LinkFolder"]?.isSymlink == true)
        #expect(byName["LinkFolder"]?.isDirectory == true)
        #expect(byName["LinkFolder"]?.isPackage == false)
        #expect(byName["LinkPackage"]?.isDirectory == true)
        #expect(byName["LinkPackage"]?.isPackage == true)
        #expect(byName["LinkFile"]?.isDirectory == false)
        #expect(byName["LinkMissing"]?.isDirectory == false)

        let matches = await service.completions(for: directory.path + "/Link")
        #expect(matches.map(\.lastPathComponent) == ["LinkFolder", "LinkPackage"])
    }

    @Test
    func testSetTagsPreservesFinderColorsAndColorsNewStandardTags() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("tags.txt")
        try Data().write(to: url)
        let key = "com.apple.metadata:_kMDItemUserTags"
        let initial = try PropertyListSerialization.data(fromPropertyList: ["Personal\n5", "Red\n6"], format: .binary, options: 0)
        let written = initial.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }
        try #require(written == 0)

        try await FileSystemService().setTags(["Personal", "Blue"], for: url)

        let size = getxattr(url.path, key, nil, 0, 0, 0)
        try #require(size > 0)
        var updated = Data(count: size)
        let bytesRead = updated.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }
        try #require(bytesRead == size)
        let tags = try PropertyListSerialization.propertyList(from: updated, options: [], format: nil) as? [String]
        #expect(tags == ["Personal\n5", "Blue\n4"])
        #expect(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Personal", "Blue"])
    }

    @Test
    func testCompressTreatsOptionAndWildcardNamesAsLiteralPaths() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let contents = Data("keep this file".utf8)
        let selectedNames = ["-m", "literal?.txt", "document.txt"]
        let existingArchive = directory.appendingPathComponent("Archive.zip")
        for name in selectedNames + ["literal1.txt", "Archive.zip"] {
            try contents.write(to: directory.appendingPathComponent(name))
        }

        let items = selectedNames.map { item(at: directory.appendingPathComponent($0)) }
        try await FileSystemService().compress(items, in: directory)

        let archive = directory.appendingPathComponent("Archive 2.zip")
        #expect(try archiveEntries(at: archive) == Set(selectedNames))
        #expect(try Data(contentsOf: existingArchive) == contents)
        for name in selectedNames {
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == contents)
        }
    }

    @Test
    func testCompressDirectoryWithThousandsOfEntries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let entryCount = 2_000
        let longName = String(repeating: "a", count: 100)
        for index in 0..<entryCount {
            try Data().write(to: folder.appendingPathComponent("\(index)-\(longName).txt"))
        }

        try await FileSystemService().compress([item(at: folder)], in: directory)

        let entries = try archiveEntries(at: directory.appendingPathComponent("Archive.zip"))
        #expect(entries.count == entryCount + 1) // Includes the folder itself.
        #expect(entries.contains("Folder/1999-\(longName).txt"))
    }

    @Test
    func testCompressStoresLinksWithoutReadingTheirTargets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        let external = directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("outside bytes".utf8).write(to: external.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("link").path,
            withDestinationPath: "../External"
        )
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("dangling").path,
            withDestinationPath: "../missing"
        )

        try await FileSystemService().compress([item(at: folder)], in: directory)

        let archive = directory.appendingPathComponent("Archive.zip")
        #expect(try archiveEntries(at: archive) == ["Folder/", "Folder/link", "Folder/dangling"])
        #expect(try unzip(["-p", archive.path, "Folder/link"]) == Data("../External".utf8))
    }

    @Test
    func testCompressReportsMissingInputAndRemovesTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing.txt")
        try Data().write(to: existing)
        let missing = directory.appendingPathComponent("missing.txt")
        do {
            try await FileSystemService().compress([item(at: existing), item(at: missing)], in: directory)
            Issue.record("Expected missing input to fail compression")
        } catch {
            #expect(error.localizedDescription.contains("missing.txt"))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.txt"])
    }

    @Test
    func testRestoreUsesOriginalFilename() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let trashed = directory.appendingPathComponent("original 2.txt")
        let original = directory.appendingPathComponent("original.txt")
        let contents = Data("restore me".utf8)
        try contents.write(to: trashed)

        try await FileSystemService().restore(from: trashed, to: original)

        #expect(try Data(contentsOf: original) == contents)
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test
    func testRestoreLeavesBothFilesIntactWhenOriginalPathIsOccupied() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let trashed = directory.appendingPathComponent("original 2.txt")
        let original = directory.appendingPathComponent("original.txt")
        let trashedContents = Data("restore me".utf8)
        let originalContents = Data("keep me".utf8)
        try trashedContents.write(to: trashed)
        try originalContents.write(to: original)

        do {
            try await FileSystemService().restore(from: trashed, to: original)
            Issue.record("Expected an occupied destination to fail restoration")
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteFileExists)
        }

        #expect(try Data(contentsOf: trashed) == trashedContents)
        #expect(try Data(contentsOf: original) == originalContents)
    }

    @Test
    func testConcurrentRestoresPreserveTheLosingSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<20 {
            let first = directory.appendingPathComponent("first-\(index).txt")
            let second = directory.appendingPathComponent("second-\(index).txt")
            let original = directory.appendingPathComponent("original-\(index).txt")
            try Data([1]).write(to: first)
            try Data([2]).write(to: second)

            async let firstRestored = restoreIfUnoccupied(from: first, to: original)
            async let secondRestored = restoreIfUnoccupied(from: second, to: original)
            let (firstWon, secondWon) = try await (firstRestored, secondRestored)

            try #require(firstWon != secondWon)
            #expect(try Data(contentsOf: original) == Data([firstWon ? 1 : 2]))
            #expect(try Data(contentsOf: firstWon ? second : first) == Data([firstWon ? 2 : 1]))
        }
    }

    private func restoreIfUnoccupied(from source: URL, to destination: URL) async throws -> Bool {
        do {
            try await FileSystemService().restore(from: source, to: destination)
            return true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func item(at url: URL) -> FileItem {
        FileItem(
            id: url, url: url, name: url.lastPathComponent, isDirectory: url.hasDirectoryPath,
            isPackage: false, isHidden: false, isSymlink: false, fileSize: nil,
            contentModificationDate: nil, creationDate: nil, kind: "", tags: []
        )
    }

    private func archiveEntries(at url: URL) throws -> Set<String> {
        let data = try unzip(["-Z1", url.path])
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    private func unzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return data
    }
}
