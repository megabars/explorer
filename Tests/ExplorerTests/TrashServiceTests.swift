import Foundation
import Testing
@testable import Explorer

@MainActor
@Suite(.serialized)
struct TrashServiceTests {
    @Test
    func partialFailureKeepsBatchAndRetryMappings() async {
        let first = item(named: "first.txt")
        let second = item(named: "second.txt")
        let blocked = item(named: "blocked.txt")
        let firstTrash = recycledURL(for: first)
        let secondTrash = recycledURL(for: second)
        let batch = [first.url, second.url, blocked.url]
        var requests: [[URL]] = []
        let service = TrashService { urls in
            requests.append(urls)
            switch urls {
            case batch:
                return ([first.url: firstTrash], failure("Some files could not be moved"))
            case [second.url]:
                return ([second.url: secondTrash], nil)
            default:
                return ([:], failure("Permission denied"))
            }
        }

        do {
            _ = try await service.trash(items: [first, second, blocked])
            Issue.record("Expected a partial failure")
        } catch let error as TrashService.PartialFailure {
            #expect(error.mapping == [first.url: firstTrash, second.url: secondTrash])
            #expect(error.localizedDescription.contains("blocked.txt: Permission denied"))
        } catch {
            Issue.record("Expected a partial failure, got \(error)")
        }
        #expect(requests == [batch, [second.url], [blocked.url]])
    }

    @Test
    func successfulRetryReturnsAllRecycledPaths() async throws {
        let first = item(named: "first.txt")
        let second = item(named: "second.txt")
        let firstTrash = recycledURL(for: first)
        let secondTrash = recycledURL(for: second)
        let batch = [first.url, second.url]
        var requests: [[URL]] = []
        let service = TrashService { urls in
            requests.append(urls)
            if urls == batch {
                return ([first.url: firstTrash], failure("Some files could not be moved"))
            }
            return ([second.url: secondTrash], nil)
        }

        let mapping = try await service.trash(items: [first, second])

        #expect(mapping == [first.url: firstTrash, second.url: secondTrash])
        #expect(requests == [batch, [second.url]])
    }

    private func item(named name: String) -> FileItem {
        let url = URL(fileURLWithPath: "/fixture/original").appendingPathComponent(name)
        return FileItem(
            id: url, url: url, name: name, isDirectory: false, isPackage: false,
            isHidden: false, isSymlink: false, fileSize: nil, contentModificationDate: nil,
            creationDate: nil, kind: "", tags: []
        )
    }

    private func recycledURL(for item: FileItem) -> URL {
        URL(fileURLWithPath: "/fixture/recycled").appendingPathComponent(item.name)
    }

    private func failure(_ description: String) -> NSError {
        NSError(domain: "TrashServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
