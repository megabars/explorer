import Foundation

actor FileSystemService {
    static let shared = FileSystemService()

    typealias DirectoryContents = @Sendable (URL, [URLResourceKey], Bool) throws -> [URL]

    private nonisolated let directoryContents: DirectoryContents
    private static let entryKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey
    ]

    init(directoryContents: DirectoryContents? = nil) {
        self.directoryContents = directoryContents ?? { url, keys, showHidden in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
        }
    }

    nonisolated func listDirectory(at url: URL, showHidden: Bool = false) async throws -> [FileItem] {
        try Task.checkCancellation()
        let result = await Self.performRead {
            Result { try self.readDirectory(at: url, showHidden: showHidden) }
        }
        return try result.get()
    }

    private nonisolated func readDirectory(at url: URL, showHidden: Bool) throws -> [FileItem] {
        let contents = try directoryContents(url, Array(Self.entryKeys), showHidden)
        // compactMap intentionally drops items whose metadata cannot be read (e.g. TOCTOU races,
        // permission errors on individual files) to keep the listing partial rather than failing entirely.
        return contents.compactMap { Self.makeFileItem(from: $0) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private static func makeFileItem(from url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: entryKeys) else { return nil }
        let isSymlink = values.isSymbolicLink ?? false
        let target = isSymlink ? url.resolvingSymlinksInPath() : url
        let isDirectory = isSymlink ? fileStatus(at: target).isDirectory : values.isDirectory ?? false
        // Kind and tags are optional metadata. A LaunchServices or xattr error should not hide the entry.
        let kind = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames
        return FileItem(
            id: url,
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isDirectory && (try? target.resourceValues(forKeys: [.isPackageKey]).isPackage) == true,
            isHidden: values.isHidden ?? false,
            isSymlink: isSymlink,
            fileSize: values.fileSize.map { Int64($0) },
            contentModificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            kind: kind ?? "Unknown",
            tags: tags ?? []
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
        let destination = destination.resolvingSymlinksInPath()
        let ancestors = directoryAncestors(of: destination)
        for item in items {
            guard let identity = directoryIdentity(at: item.url, followLink: false),
                  ancestors.contains(identity) else { continue }
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot copy “\(item.url.lastPathComponent)” into itself or one of its subfolders."
            ])
        }
        var copied = 0
        do {
            for item in items {
                var candidate = destination.appendingPathComponent(item.name)
                var counter = 2
                // Retry with incremented counter on conflict (avoids TOCTOU from pre-checking existence).
                while true {
                    do {
                        try FileManager.default.copyItem(at: item.url, to: candidate)
                        copied += 1
                        break
                    } catch let error as NSError
                        where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        guard counter <= 1000 else {
                            throw CocoaError(.fileWriteFileExists, userInfo: [
                                NSLocalizedDescriptionKey: "Could not copy “\(item.name)”: too many conflicting files in destination."
                            ])
                        }
                        let newName = name(item.name, adding: " \(counter)")
                        candidate = destination.appendingPathComponent(newName)
                        counter += 1
                    }
                }
            }
        } catch {
            guard copied > 0 else { throw error }
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Copied \(copied) of \(items.count) items.\n\(error.localizedDescription)",
                NSUnderlyingErrorKey: error
            ])
        }
    }

    /// Returns completions for the given partial path, filtered by directory and optionally hidden files.
    nonisolated func completions(for partialPath: String, showHidden: Bool = false) async -> [URL] {
        await Self.performRead { self.directoryCompletions(for: partialPath, showHidden: showHidden) }
    }

    private nonisolated func directoryCompletions(for partialPath: String, showHidden: Bool) -> [URL] {
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

        guard let contents = try? directoryContents(parentURL, [.isDirectoryKey, .isSymbolicLinkKey], showHidden)
        else { return [] }

        return contents
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    return false
                }
                if values.isSymbolicLink == true {
                    let target = url.resolvingSymlinksInPath()
                    return Self.fileStatus(at: target).isDirectory && FileManager.default.isReadableFile(atPath: target.path)
                }
                return values.isDirectory == true
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12)
            .map { $0 }
    }

    nonisolated func exists(at url: URL) async -> Bool {
        await Self.performRead { FileManager.default.fileExists(atPath: url.path) }
    }

    nonisolated func isReadable(at url: URL) async -> Bool {
        await Self.performRead { FileManager.default.isReadableFile(atPath: url.path) }
    }

    /// Returns the display name for a volume URL, or nil if not a volume root.
    nonisolated func volumeName(for url: URL) async -> String? {
        await Self.performRead { try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName }
    }

    /// Returns existence and directory status in a single syscall, eliminating ambiguity
    /// between "does not exist" and "exists but is not a directory".
    nonisolated func itemStatus(at url: URL) async -> (exists: Bool, isDirectory: Bool) {
        await Self.performRead { Self.fileStatus(at: url) }
    }

    private static func fileStatus(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return (exists, exists && isDir.boolValue)
    }

    private static func performRead<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        // Foundation filesystem calls can block indefinitely. Keep each read off the
        // caller, the write actor, and Swift's cooperative executor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    /// Copies each item to the same directory with a " copy" suffix, incrementing on conflict.
    func duplicateItems(_ items: [FileItem]) throws {
        for item in items {
            let copyName = name(item.name, adding: " copy")
            var candidate = item.url.deletingLastPathComponent().appendingPathComponent(copyName)
            var counter = 2
            while true {
                do {
                    try FileManager.default.copyItem(at: item.url, to: candidate)
                    break
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    guard counter <= 1000 else { throw error }
                    let numberedName = name(item.name, adding: " copy \(counter)")
                    candidate = item.url.deletingLastPathComponent().appendingPathComponent(numberedName)
                    counter += 1
                }
            }
        }
    }

    /// Sets macOS Finder color tags on a file.
    func setTags(_ tags: [String], for url: URL) throws {
        // NSURL's tag setter rewrites every tag as uncolored. Finder stores color
        // indices after a newline in the same binary plist as the tag names.
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let palette = ["Gray": 1, "Green": 2, "Purple": 3, "Blue": 4, "Yellow": 5, "Red": 6, "Orange": 7]
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw POSIXError(.EINVAL) }
            let existing = try readTags(at: path, attribute: attribute)
            var entriesByName: [String: String] = [:]
            for entry in existing {
                var name = entry
                if let newline = entry.lastIndex(of: "\n"),
                   let color = Int(entry[entry.index(after: newline)...]), (0...7).contains(color) {
                    name = String(entry[..<newline])
                }
                entriesByName[name] = entry
            }
            let entries = tags.map { name in entriesByName[name] ?? "\(name)\n\(palette[name, default: 0])" }
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            let result = data.withUnsafeBytes { buffer in
                setxattr(path, attribute, buffer.baseAddress, buffer.count, 0, 0)
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func readTags(at path: UnsafePointer<CChar>, attribute: String) throws -> [String] {
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        if size == 0 || (size < 0 && errno == ENOATTR) { return [] }
        guard size > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, attribute, buffer.baseAddress, buffer.count, 0, 0)
        }
        if read < 0 && errno == ENOATTR { return [] }
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return (try? PropertyListSerialization.propertyList(from: data.prefix(read), options: [], format: nil))
            as? [String] ?? []
    }

    /// Moves files to a destination directory, resolving name conflicts with a counter suffix.
    func move(from sources: [URL], to destination: URL) throws {
        for source in sources {
            let sourceName = source.lastPathComponent
            var candidate = destination.appendingPathComponent(sourceName)
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
                                      userInfo: [NSLocalizedDescriptionKey: "Could not move \"\(sourceName)\": too many conflicts."])
                    }
                    let newName = name(sourceName, adding: " \(counter)")
                    candidate = destination.appendingPathComponent(newName)
                    counter += 1
                }
            }
        }
    }

    /// Restores a trashed item to its exact original path, failing if that path is occupied.
    func restore(from trashedURL: URL, to originalURL: URL) throws {
        do {
            try renameExclusively(from: trashedURL, to: originalURL)
        } catch let error as POSIXError where error.code == .EXDEV {
            // Stage across volumes, then publish with the same exclusive rename on the target volume.
            let workDirectory = try makeWorkDirectory(in: originalURL.deletingLastPathComponent(), purpose: "restore")
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let stagedURL = workDirectory.appendingPathComponent(originalURL.lastPathComponent)
            try FileManager.default.copyItem(at: trashedURL, to: stagedURL)
            try renameExclusively(from: stagedURL, to: originalURL)
            try FileManager.default.removeItem(at: trashedURL)
        }
    }

    /// Compresses the given items into an Archive.zip (or Archive N.zip) in the given directory.
    func compress(_ items: [FileItem], in directory: URL) async throws {
        // Keep partial archives and subprocess output together so any failure cleans up both.
        let workDirectory = try makeWorkDirectory(in: directory, purpose: "archive")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let tempURL = workDirectory.appendingPathComponent("Archive.zip")
        let outputURL = workDirectory.appendingPathComponent("zip.log")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        // Treat names as literal paths, including names like "-m", "-", or "*.txt".
        process.arguments = ["-q", "-r", "-y", "-MM", "-nw", tempURL.path, "--"]
            + items.map { "./\($0.url.lastPathComponent)" }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZIPOPT")
        environment.removeValue(forKey: "ZIP")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // zip reports errors on stdout too. A file cannot fill up like an unread pipe.
        process.standardOutput = output
        process.standardError = output

        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = (try? zipDiagnostics(at: outputURL)) ?? ""
            throw NSError(
                domain: "zip",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "zip failed with status \(status)." : message]
            )
        }

        // Rename from temp to a human-readable name, resolving conflicts atomically
        var archiveName = "Archive"
        var archiveURL = directory.appendingPathComponent("\(archiveName).zip")
        var counter = 2
        while true {
            do {
                try renameExclusively(from: tempURL, to: archiveURL)
                break
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                guard counter <= 1000 else {
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

    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private func directoryIdentity(at url: URL, followLink: Bool) -> DirectoryIdentity? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return followLink ? stat(path, &info) : lstat(path, &info)
        }
        guard result == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func directoryAncestors(of url: URL) -> Set<DirectoryIdentity> {
        Set(url.pathComponentURLs.compactMap { directoryIdentity(at: $0, followLink: true) })
    }

    private func name(_ original: String, adding suffix: String) -> String {
        let extensionName = (original as NSString).pathExtension
        let extensionSuffix = extensionName.isEmpty ? "" : "." + extensionName
        let base = (original as NSString).deletingPathExtension
        let budget = Int(NAME_MAX) - suffix.utf8.count - extensionSuffix.utf8.count
        if budget > 0 {
            return prefix(of: base, fitting: budget) + suffix + extensionSuffix
        }
        return prefix(of: original, fitting: Int(NAME_MAX) - suffix.utf8.count) + suffix
    }

    private func prefix(of name: String, fitting byteLimit: Int) -> String {
        var remaining = byteLimit
        return String(name.prefix { character in
            remaining -= String(character).utf8.count
            return remaining >= 0
        })
    }

    private func makeWorkDirectory(in parent: URL, purpose: String) throws -> URL {
        let directory = parent.appendingPathComponent(".explorer-\(purpose)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func renameExclusively(from source: URL, to destination: URL) throws {
        // Foundation's move can race an external writer between its existence check and rename.
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        let userInfo = [NSFilePathErrorKey: destination.path]
        switch status {
        case 0:
            return
        case EEXIST:
            throw CocoaError(.fileWriteFileExists, userInfo: userInfo)
        default:
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO, userInfo: userInfo)
        }
    }

    private func zipDiagnostics(at url: URL) throws -> String {
        let log = try FileHandle(forReadingFrom: url)
        defer { try? log.close() }
        let length = try log.seekToEnd()
        try log.seek(toOffset: length - min(length, 8_192))
        let data = try log.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
