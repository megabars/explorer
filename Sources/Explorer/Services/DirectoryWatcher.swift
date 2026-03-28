import Foundation

/// Watches a single directory for changes using DispatchSource (kqueue-based).
/// Delivers debounced change events on the main actor.
/// All mutable state is accessed exclusively on `@MainActor` (via start/stop),
/// so the `@unchecked Sendable` conformance is safe.
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
    /// Must be called on `@MainActor` (enforced by the caller, not annotated here
    /// to avoid Swift 6 inheriting actor isolation into DispatchSource handler closures).
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

    /// Must be called on `@MainActor` (same reasoning as start).
    func stop() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        // Capture references before self is deallocated — deinit may run on any thread,
        // but these objects are safe to cancel from any thread.
        let s = source
        let d = debounceItem
        DispatchQueue.main.async {
            d?.cancel()
            s?.cancel()
        }
    }
}
