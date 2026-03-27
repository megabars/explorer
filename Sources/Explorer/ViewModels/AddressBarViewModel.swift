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
    func textDidChange(_ text: String, service: FileSystemService) {
        editText = text
        completionTask?.cancel()
        guard !text.isEmpty else {
            completions = []
            return
        }
        completionTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            guard !Task.isCancelled else { return }
            let results = await service.completions(for: text)
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
        // Single isDirectory call covers both existence and type in one syscall
        let isDir = await service.isDirectory(at: url)
        if isDir { return url }
        guard await service.exists(at: url) else { return nil }
        return url.deletingLastPathComponent()
    }
}
