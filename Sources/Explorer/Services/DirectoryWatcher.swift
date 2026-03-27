import Foundation

/// Watches a single directory for changes using DispatchSource (kqueue-based).
/// Delivers debounced change events on the main actor.
final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    /// Pending debounce work item — always accessed on the main queue.
    private var debounceItem: DispatchWorkItem?
    private static let debounceDelay: TimeInterval = 0.25
    /// Incremented on each start() call. Stale main-queue dispatches from a previous
    /// watcher cycle see a mismatched generation and discard themselves, preventing
    /// them from cancelling the new cycle's debounce or triggering reloads for old URLs.
    private var generation: Int = 0

    /// Starts watching `url` for filesystem changes.
    /// Returns `false` if the directory could not be opened (e.g. permission denied).
    @discardableResult
    func start(watching url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
        stop()
        generation &+= 1
        let currentGen = generation
        // O_CLOEXEC prevents the fd from leaking into child processes
        let rawFD = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard rawFD != -1 else { return false }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: rawFD,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        newSource.setEventHandler { [weak self] in
            // All debounceItem accesses happen on the main queue (serial), avoiding data races.
            DispatchQueue.main.async { [weak self] in
                // Discard dispatches that survived a stop()/start() cycle.
                guard let self, self.generation == currentGen else { return }
                self.debounceItem?.cancel()
                let item = DispatchWorkItem {
                    Task { @MainActor in onChange() }
                }
                self.debounceItem = item
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + DirectoryWatcher.debounceDelay,
                    execute: item
                )
            }
        }

        newSource.setCancelHandler { [rawFD] in
            close(rawFD)
        }

        newSource.resume()
        source = newSource
        return true
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
