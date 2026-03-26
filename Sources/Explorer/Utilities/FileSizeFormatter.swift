import Foundation

enum FileSizeFormatter {
    static func string(fromByteCount bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
