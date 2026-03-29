import AppKit

/// Result of a trash operation.
struct TrashResult {
    /// Maps each successfully trashed original URL to its Trash URL.
    let mapping: [URL: URL]
    /// Human-readable error messages for items that could not be trashed.
    let failures: [String]
}

@MainActor
final class TrashService {
    static let shared = TrashService()

    /// Moves items to Trash and returns a TrashResult with the mapping and any per-item failures.
    /// Never throws — errors are reported via TrashResult.failures so callers can set undo state
    /// even when only a subset of items was successfully trashed.
    @discardableResult
    func trash(items: [FileItem]) async -> TrashResult {
        let urls = items.map(\.url)
        do {
            let result = try await NSWorkspace.shared.recycle(urls)
            return TrashResult(mapping: result, failures: [])
        } catch {
            // Batch call failed. If there was only one item, report it directly.
            guard urls.count > 1 else {
                return TrashResult(mapping: [:], failures: ["\(items[0].name): \(error.localizedDescription)"])
            }
            // Retry individually to separate successes from failures so the caller can
            // set undo state for successfully trashed items even when some fail.
            var failures: [String] = []
            var combinedResult: [URL: URL] = [:]
            for (item, url) in zip(items, urls) {
                // Skip files that no longer exist — they may have been successfully
                // moved by the batch call before it reported a partial failure.
                guard await FileSystemService.shared.exists(at: url) else { continue }
                do {
                    let result = try await NSWorkspace.shared.recycle([url])
                    combinedResult.merge(result) { _, new in new }
                } catch let itemError {
                    failures.append("\(item.name): \(itemError.localizedDescription)")
                }
            }
            return TrashResult(mapping: combinedResult, failures: failures)
        }
    }
}
