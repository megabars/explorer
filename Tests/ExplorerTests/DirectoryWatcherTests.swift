import Foundation
import Testing
@testable import Explorer

@MainActor
@Suite(.serialized)
struct DirectoryWatcherTests {
    @Test
    func reportsInPlaceWriteToExistingChild() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("existing.txt")
        try Data("initial contents".utf8).write(to: file)

        var changed = false
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        try #require(watcher.start(watching: directory) { changed = true })

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" updated".utf8))
        try handle.close()

        try await waitForChange { changed }
        #expect(changed)
    }

    @Test
    func restartSuppressesOldCallbacksAndReportsNewChanges() async throws {
        let first = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: second) }

        var oldChange = false
        var newChange = false
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        try #require(watcher.start(watching: first) { oldChange = true })
        try Data().write(to: first.appendingPathComponent("old.txt"))
        // Let the old change queue while its delivery is still pending.
        try await Task.sleep(for: .milliseconds(100))
        try #require(watcher.start(watching: second) { newChange = true })
        try Data().write(to: second.appendingPathComponent("new.txt"))

        try await waitForChange { newChange }
        #expect(newChange)
        #expect(!oldChange)
    }

    @Test
    func followsTheDisplayedPathWhenTheDirectoryIsReplaced() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("original", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        var changes = 0
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        try #require(watcher.start(watching: directory) { changes += 1 })

        try FileManager.default.moveItem(at: directory, to: moved)
        try await waitForChange { changes > 0 }
        try #require(changes > 0)

        let beforeRecreation = changes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try await waitForChange { changes > beforeRecreation }
        try #require(changes > beforeRecreation)

        let beforeWrite = changes
        try Data().write(to: directory.appendingPathComponent("new.txt"))
        try await waitForChange { changes > beforeWrite }
        #expect(changes > beforeWrite)
    }

    private func waitForChange(_ didChange: () -> Bool) async throws {
        for _ in 0..<50 {
            if didChange() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
