import AppKit

@MainActor
final class TrashService {
    static let shared = TrashService()

    func trash(items: [FileItem]) async throws {
        let urls = items.map(\.url)
        try await NSWorkspace.shared.recycle(urls)
    }
}
