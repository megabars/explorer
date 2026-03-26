import Foundation
import AppKit

struct FileItem: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let fileSize: Int64?
    let contentModificationDate: Date?
    let creationDate: Date?
    let kind: String
    let tags: [String]

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
