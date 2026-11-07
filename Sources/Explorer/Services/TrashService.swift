import AppKit

@MainActor
final class TrashService {
    struct PartialFailure: LocalizedError {
        let mapping: [URL: URL]
        let failures: [String]

        var errorDescription: String? {
            L10n.format("Failed to move to Trash:\n%@", failures.joined(separator: "\n"))
        }
    }

    typealias Recycle = @MainActor ([URL]) async -> (mapping: [URL: URL], error: (any Error)?)

    static let shared = TrashService()
    private let recycle: Recycle

    init(recycle: Recycle? = nil) {
        self.recycle = recycle ?? { urls in
            // The completion handler can report both successful moves and an overall error.
            await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle(urls) { mapping, error in
                    continuation.resume(returning: (mapping, error))
                }
            }
        }
    }

    /// Moves items to Trash and returns a mapping from original URL to Trash URL.
    @discardableResult
    func trash(items: [FileItem]) async throws -> [URL: URL] {
        guard !items.isEmpty else { return [:] }
        let batch = await recycle(items.map(\.url))
        guard let batchError = batch.error else { return batch.mapping }

        var mapping = batch.mapping
        let remaining = items.filter { mapping[$0.url] == nil }
        guard items.count > 1, !remaining.isEmpty else {
            if mapping.isEmpty { throw batchError }
            throw PartialFailure(mapping: mapping, failures: [batchError.localizedDescription])
        }

        // Retry only the items the batch did not move, collecting errors by item.
        var failures: [String] = []
        for item in remaining {
            let retry = await recycle([item.url])
            mapping.merge(retry.mapping) { original, _ in original }
            if let error = retry.error {
                failures.append(L10n.format("%@: %@", item.name, error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            throw PartialFailure(mapping: mapping, failures: failures)
        }
        return mapping
    }
}
