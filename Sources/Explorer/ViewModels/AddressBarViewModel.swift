import Foundation
import Observation

@Observable
@MainActor
final class AddressBarViewModel {
    private(set) var isEditing = false
    private(set) var editText = ""
    private(set) var completions: [URL] = []
    private(set) var commitError: String?
    private var completionTask: Task<Void, Never>?
    private var revision = 0

    func beginEditing(from url: URL) {
        invalidateCompletions()
        dismissError()
        editText = url.path
        isEditing = true
    }

    func cancel() {
        isEditing = false
        invalidateCompletions()
        dismissError()
    }

    func dismissCompletions() {
        completions = []
    }

    func dismissError() {
        commitError = nil
    }

    private func invalidateCompletions() {
        revision += 1
        dismissCompletions()
        completionTask?.cancel()
        completionTask = nil
    }

    /// Called when text changes — schedules a debounced completion fetch.
    func textDidChange(_ text: String, service: FileSystemService, showHidden: Bool) {
        guard isEditing else { return }
        editText = text
        dismissError()
        invalidateCompletions()
        guard !text.isEmpty else { return }
        completionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            let results = await service.completions(for: text, showHidden: showHidden)
            guard !Task.isCancelled else { return }
            completions = results
            completionTask = nil
        }
    }

    /// Tab bypasses the debounce and resolves the current input even if suggestions are still loading.
    func completeUsingTab(service: FileSystemService, showHidden: Bool) async {
        guard isEditing, !editText.isEmpty else { return }
        let text = editText
        invalidateCompletions()
        let request = revision
        let results = await service.completions(for: text, showHidden: showHidden)
        guard revision == request, !Task.isCancelled, let first = results.first else { return }

        let expanded = (text as NSString).expandingTildeInPath
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        let exact = text.hasSuffix("/") ? nil : results.first { $0.lastPathComponent == name }
        applyCompletion(exact ?? first, service: service, showHidden: showHidden)
    }

    func selectCompletion(_ url: URL, service: FileSystemService, showHidden: Bool) -> Bool {
        guard completions.contains(url) else { return false }
        applyCompletion(url, service: service, showHidden: showHidden)
        return true
    }

    private func applyCompletion(_ url: URL, service: FileSystemService, showHidden: Bool) {
        let path = url.path
        textDidChange(path.hasSuffix("/") ? path : path + "/", service: service, showHidden: showHidden)
    }

    /// Validates and returns the URL to navigate to (or nil on error).
    func commit(service: FileSystemService, isCurrent: () -> Bool = { true }) async -> URL? {
        guard isEditing else { return nil }
        let text = editText
        guard !text.isEmpty else {
            cancel()
            return nil
        }

        invalidateCompletions()
        dismissError()
        let request = revision
        let expanded = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let status = await service.itemStatus(at: url)
        guard revision == request, isCurrent(), !Task.isCancelled else { return nil }
        guard status.exists else {
            commitError = "This path does not exist."
            return nil
        }
        let directory = status.isDirectory ? url : url.deletingLastPathComponent()
        let readable = await service.isReadable(at: directory)
        guard revision == request, isCurrent(), !Task.isCancelled else { return nil }
        guard readable else {
            commitError = "This folder cannot be read."
            return nil
        }
        cancel()
        return directory
    }
}
