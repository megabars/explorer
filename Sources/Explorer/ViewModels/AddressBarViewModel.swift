import Foundation
import Observation

@Observable
@MainActor
final class AddressBarViewModel {
    var isEditing: Bool = false
    var editText: String = ""
    var completions: [URL] = []
    var completionTask: Task<Void, Never>?

    func beginEditing(from url: URL) {
        editText = url.path
        isEditing = true
    }

    func cancel() {
        isEditing = false
        completions = []
        completionTask?.cancel()
    }

    /// Called when text changes — schedules a debounced completion fetch.
    func textDidChange(_ text: String, service: FileSystemService, showHidden: Bool) {
        editText = text
        completionTask?.cancel()
        guard !text.isEmpty else {
            completions = []
            return
        }
        completionTask = Task {
            // Use do/catch instead of try? so that cancellation (CancellationError)
            // exits the task immediately rather than continuing after sleep.
            do {
                try await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let results = await service.completions(for: text, showHidden: showHidden)
            // Check again after the await — task may have been cancelled while fetching.
            guard !Task.isCancelled else { return }
            completions = results
        }
    }

    /// Validates and returns the URL to navigate to (or nil on error).
    func commit(service: FileSystemService) async -> URL? {
        let expanded = (editText as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        // Always close editing regardless of whether path is valid
        isEditing = false
        completions = []
        // Single itemStatus call covers both existence and type in one syscall,
        // eliminating the ambiguity of isDirectory() returning false for non-existent paths.
        let status = await service.itemStatus(at: url)
        if status.isDirectory {
            guard await service.isReadable(at: url) else { return nil }
            return url
        }
        guard status.exists else { return nil }
        let parent = url.deletingLastPathComponent()
        guard await service.isReadable(at: parent) else { return nil }
        return parent
    }
}
