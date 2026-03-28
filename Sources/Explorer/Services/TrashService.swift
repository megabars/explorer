import AppKit

@MainActor
final class TrashService {
    static let shared = TrashService()

    /// Moves items to Trash and returns a mapping from original URL to Trash URL.
    @discardableResult
    func trash(items: [FileItem]) async throws -> [URL: URL] {
        let urls = items.map(\.url)
        // recycle() throws a single error if any item fails; on partial failure we get one combined error
        // from NSWorkspace. Collect individual failures for a more informative message.
        do {
            let result = try await NSWorkspace.shared.recycle(urls)
            return result
        } catch {
            // If multiple items were requested, attempt them individually to collect all errors
            guard urls.count > 1 else { throw error }
            var failures: [String] = []
            var combinedResult: [URL: URL] = [:]
            for (item, url) in zip(items, urls) {
                // Skip files that no longer exist — they may have been successfully
                // moved by the batch call before it reported a partial failure.
                // Use the FileSystemService actor to avoid blocking @MainActor.
                guard await FileSystemService.shared.exists(at: url) else { continue }
                do {
                    let result = try await NSWorkspace.shared.recycle([url])
                    combinedResult.merge(result) { _, new in new }
                } catch let itemError {
                    failures.append("\(item.name): \(itemError.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                let combined = failures.joined(separator: "\n")
                throw NSError(
                    domain: "TrashService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to move to Trash:\n\(combined)"]
                )
            }
            return combinedResult
        }
    }
}
