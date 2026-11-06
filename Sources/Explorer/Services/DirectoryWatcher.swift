import CoreServices
import Foundation

/// Watches the current directory and delivers coalesced changes on the main actor.
@MainActor
final class DirectoryWatcher {
    private var observation: Observation?
    private var parentObservations: [Observation] = []
    private var pendingChange: Task<Void, Never>?
    private var generation = 0

    /// Returns false if the directory could not be opened.
    @discardableResult
    func start(watching url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
        stop()
        observeParents(of: url, generation: generation, onChange: onChange)
        observation = observe(url, watching: url, generation: generation, onChange: onChange)
        return observation != nil
    }

    private func observe(
        _ observedURL: URL,
        watching url: URL,
        generation currentGeneration: Int,
        parent: Bool = false,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) -> Observation? {
        Observation(url: observedURL, fileEvents: !parent) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, self.pendingChange == nil else { return }
                // Parent writes can be unrelated. Only a new or missing directory at the
                // displayed path should invalidate a listing.
                if parent, Observation.identity(at: url) == self.observation?.identity { return }
                self.pendingChange = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    guard let self, self.generation == currentGeneration else { return }
                    self.pendingChange = nil
                    if Observation.identity(at: url) != self.observation?.identity {
                        self.observation = self.observe(url, watching: url, generation: currentGeneration, onChange: onChange)
                        if self.observation != nil {
                            self.observeParents(of: url, generation: currentGeneration, onChange: onChange)
                        }
                    }
                    onChange()
                }
            }
        }
    }

    private func observeParents(
        of url: URL,
        generation: Int,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        // The lexical parent notices symlink replacement. The physical parent also
        // notices replacement of the target at the other end of the symlink.
        let parents = Set([url, url.resolvingSymlinksInPath()].compactMap { directory -> URL? in
            let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath()
            return parent.path.isEmpty || parent.path == directory.path ? nil : parent
        })
        parentObservations = parents.compactMap { observe($0, watching: url, generation: generation, parent: true, onChange: onChange) }
    }

    func stop() {
        generation &+= 1
        pendingChange?.cancel()
        pendingChange = nil
        observation = nil
        parentObservations = []
    }

    private final class Observation {
        struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t

            init(_ info: stat) {
                device = info.st_dev
                inode = info.st_ino
            }
        }

        private static let queue = DispatchQueue(label: "Explorer.DirectoryWatcher", qos: .utility)
        private let directorySource: DispatchSourceFileSystemObject
        private let stream: FSEventStreamRef?
        let identity: Identity

        static func identity(at url: URL) -> Identity? {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return stat(path, &info)
            }
            return result == 0 && info.st_mode & S_IFMT == S_IFDIR ? Identity(info) : nil
        }

        init?(url: URL, fileEvents: Bool, onChange: @escaping @Sendable () -> Void) {
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
            }
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                close(descriptor)
                return nil
            }
            identity = Identity(info)

            // Keep vnode notifications for directory entry changes, including on volumes
            // where FSEvents may be unavailable.
            directorySource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: Self.queue
            )
            directorySource.setEventHandler(handler: onChange)
            directorySource.setCancelHandler { close(descriptor) }
            directorySource.resume()

            guard fileEvents else {
                stream = nil
                return
            }
            // Use the opened directory's path so the event filter handles symlinks and case aliases.
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let path = fcntl(descriptor, F_GETPATH, &buffer) == 0
                ? buffer.withUnsafeBufferPointer { $0.baseAddress.flatMap(String.init(validatingCString:)) }
                : nil
            stream = Self.startFileEvents(at: path ?? url.resolvingSymlinksInPath().path, onChange: onChange)
        }

        deinit {
            directorySource.cancel()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }

        private static func startFileEvents(
            at path: String,
            onChange: @escaping @Sendable () -> Void
        ) -> FSEventStreamRef? {
            let context = EventContext(path: path, onChange: onChange)
            var streamContext = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(context).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<EventContext>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    if let pointer { Unmanaged<EventContext>.fromOpaque(pointer).release() }
                },
                copyDescription: nil
            )
            let stream = withExtendedLifetime(context) {
                FSEventStreamCreate(
                    kCFAllocatorDefault,
                    { _, info, count, paths, flags, _ in
                        guard let info else { return }
                        let context = Unmanaged<EventContext>.fromOpaque(info).takeUnretainedValue()
                        let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                        for index in 0..<count {
                            if context.affectsListing(path: String(cString: paths[index]), flags: flags[index]) {
                                context.onChange()
                                return
                            }
                        }
                    },
                    &streamContext,
                    [path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    0.1,
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
                )
            }
            guard let stream else { return nil }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return nil
            }
            return stream
        }
    }

    private final class EventContext {
        let path: String
        let prefix: String
        let onChange: @Sendable () -> Void

        init(path: String, onChange: @escaping @Sendable () -> Void) {
            self.path = path
            self.prefix = path == "/" ? path : path + "/"
            self.onChange = onChange
        }

        func affectsListing(path eventPath: String, flags: FSEventStreamEventFlags) -> Bool {
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
            )
            if flags & rescan != 0 || eventPath == path { return true }
            guard eventPath.hasPrefix(prefix) else { return false }
            let relativePath = eventPath.dropFirst(prefix.count)
            guard let separator = relativePath.firstIndex(of: "/") else { return true }
            // Creating, removing or renaming a grandchild changes the listed directory's metadata.
            let entryChange = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            )
            return flags & entryChange != 0 && !relativePath[relativePath.index(after: separator)...].contains("/")
        }
    }
}
