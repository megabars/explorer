import Foundation

/// Watches a single directory for changes using DispatchSource (kqueue-based).
/// Delivers change events on the main actor.
final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start(watching url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let rawFD = open(url.path, O_EVTONLY)
        guard rawFD != -1 else { return }
        fd = rawFD

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: rawFD,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        newSource.setEventHandler {
            Task { @MainActor in
                onChange()
            }
        }

        newSource.setCancelHandler { [rawFD] in
            close(rawFD)
        }

        newSource.resume()
        source = newSource
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit {
        stop()
    }
}
