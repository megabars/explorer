import Foundation

enum FileSizeFormatter {
    static func string(fromByteCount bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }
}
