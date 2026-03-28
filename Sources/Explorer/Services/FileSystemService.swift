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
            // Retry with incremented counter on conflict (avoids TOCTOU from pre-checking existence).
            // Guard against degenerate cases with a maximum iteration limit.
            while true {
                do {
                    try FileManager.default.copyItem(at: item.url, to: candidate)
                    break
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    guard counter <= 1000 else {
                        throw NSError(
                            domain: NSCocoaErrorDomain,
                            code: NSFileWriteFileExistsError,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Could not copy \"\(item.name)\": too many conflicting files in destination."]
                        )
                    }
                    let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    candidate = destination.appendingPathComponent(newName)
                    counter += 1
                }
            }
        }
    }

    /// Returns completions for the given partial path, filtered by directory and optionally hidden files.
    func completions(for partialPath: String, showHidden: Bool = false) -> [URL] {
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

        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: options
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

    func isReadable(at url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Returns the display name for a volume URL, or nil if not a volume root.
    func volumeName(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    /// Returns existence and directory status in a single syscall, eliminating ambiguity
    /// between "does not exist" and "exists but is not a directory".
    func itemStatus(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return (exists, exists && isDir.boolValue)
    }

    /// Copies each item to the same directory with a " copy" suffix, incrementing on conflict.
    func duplicateItems(_ items: [FileItem]) throws {
        for item in items {
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            var candidate = item.url.deletingLastPathComponent().appendingPathComponent(copyName)
            var counter = 2
            while true {
                do {
                    try FileManager.default.copyItem(at: item.url, to: candidate)
                    break
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    guard counter <= 1000 else { throw error }
                    let numberedName = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
                    candidate = item.url.deletingLastPathComponent().appendingPathComponent(numberedName)
                    counter += 1
                }
            }
        }
    }

    /// Sets macOS Finder color tags on a file.
    func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    /// Moves files to a destination directory, resolving name conflicts with a counter suffix.
    func move(from sources: [URL], to destination: URL) throws {
        for source in sources {
            let name = source.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = destination.appendingPathComponent(name)
            var counter = 2
            // Retry on conflict (same pattern as copy()) to avoid TOCTOU from pre-checking existence.
            while true {
                do {
                    try FileManager.default.moveItem(at: source, to: candidate)
                    break
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    guard counter <= 1000 else {
                        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                                      userInfo: [NSLocalizedDescriptionKey: "Could not move \"\(name)\": too many conflicts."])
                    }
                    let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    candidate = destination.appendingPathComponent(newName)
                    counter += 1
                }
            }
        }
    }

    /// Compresses the given items into an Archive.zip (or Archive N.zip) in the given directory.
    /// Uses a unique temporary name during compression, then renames to the target name
    /// (with conflict resolution) to avoid TOCTOU races.
    func compress(_ items: [FileItem], in directory: URL) async throws {
        let itemNames = items.map { $0.url.lastPathComponent }

        // Create a unique temporary file name that cannot conflict
        let tempName = "Archive-\(UUID().uuidString).zip"
        let tempURL = directory.appendingPathComponent(tempName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        var args = ["-r", tempURL.path]
        args += itemNames
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Use a continuation so the actor is not blocked while zip runs.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    continuation.resume(throwing: NSError(
                        domain: "zip",
                        code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // Rename from temp to a human-readable name, resolving conflicts atomically
        var archiveName = "Archive"
        var archiveURL = directory.appendingPathComponent("\(archiveName).zip")
        var counter = 2
        while true {
            do {
                try FileManager.default.moveItem(at: tempURL, to: archiveURL)
                break
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                guard counter <= 1000 else {
                    // Clean up temp file before throwing
                    try? FileManager.default.removeItem(at: tempURL)
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteFileExistsError,
                        userInfo: [NSLocalizedDescriptionKey: "Could not find a unique archive name."]
                    )
                }
                archiveName = "Archive \(counter)"
                archiveURL = directory.appendingPathComponent("\(archiveName).zip")
                counter += 1
            }
        }
    }
}
