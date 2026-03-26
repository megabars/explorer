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
        let isDir = await service.isDirectory(at: url)
        let exists = await service.exists(at: url)
        guard exists else { return nil }
        isEditing = false
        completions = []
        return isDir ? url : url.deletingLastPathComponent()
    }
}
