import Foundation

actor FileSystemService {
    static let shared = FileSystemService()

    private let resourceKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .localizedTypeDescriptionKey,
        .tagNamesKey
    ]

    func listDirectory(at url: URL, showHidden: Bool = false) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )
        // compactMap intentionally drops items whose metadata cannot be read (e.g. TOCTOU races,
        // permission errors on individual files) to keep the listing partial rather than failing entirely.
        return contents.compactMap { makeFileItem(from: $0) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func makeFileItem(from url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        return FileItem(
            id: url,
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isHidden: values.isHidden ?? false,
            isSymlink: values.isSymbolicLink ?? false,
            fileSize: values.fileSize.map { Int64($0) },
            contentModificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            kind: values.localizedTypeDescription ?? "Unknown",
            tags: values.tagNames ?? []
        )
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func rename(item: FileItem, to newName: String) throws -> URL {
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: item.url, to: newURL)
        return newURL
    }

    func copy(items: [FileItem], to destination: URL) throws {
        for item in items {
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var candidate = destination.appendingPathComponent(item.name)
            var counter = 2
            // Retry with incremented counter on conflict (avoids TOCTOU from pre-checking existence)
            while true {
                do {
                    try FileManager.default.copyItem(at: item.url, to: candidate)
                    break
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    candidate = destination.appendingPathComponent(newName)
                    counter += 1
                }
            }
        }
    }

    /// Returns a unique folder/file name inside `url` by appending a counter if needed.
    func uniqueName(for base: String, in url: URL) -> String {
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    func completions(for partialPath: String) -> [URL] {
        let expanded = (partialPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let parentURL: URL
        let prefix: String

        if partialPath.hasSuffix("/") {
            parentURL = url
            prefix = ""
        } else {
            parentURL = url.deletingLastPathComponent()
            prefix = url.lastPathComponent
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            // Filter out symlinks whose targets are not readable (broken or permission-denied symlinks)
            .filter { url in
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return true }
                return FileManager.default.isReadableFile(atPath: url.resolvingSymlinksInPath().path)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12)
            .map { $0 }
    }

    func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
