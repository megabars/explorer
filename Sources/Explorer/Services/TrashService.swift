import AppKit

@MainActor
final class TrashService {
    static let shared = TrashService()

    func trash(items: [FileItem]) async throws {
        let urls = items.map(\.url)
        // recycle() throws a single error if any item fails; on partial failure we get one combined error
        // from NSWorkspace. Collect individual failures for a more informative message.
        do {
            try await NSWorkspace.shared.recycle(urls)
        } catch {
            // If multiple items were requested, attempt them individually to collect all errors
            guard urls.count > 1 else { throw error }
            var failures: [String] = []
            for (item, url) in zip(items, urls) {
                do {
                    try await NSWorkspace.shared.recycle([url])
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
        }
    }
}
