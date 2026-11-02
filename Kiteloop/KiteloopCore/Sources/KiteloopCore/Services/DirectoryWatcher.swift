import Foundation

/// Watches a set of directories for file system changes and debounces callbacks.
package final class DirectoryWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWork: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let debounceInterval: TimeInterval
    /// How each `O_EVTONLY` descriptor is released — `close(2)` by default. A
    /// test substitutes a counting closer, which is the only way to assert a
    /// descriptor is released exactly once, and only from the cancel handler,
    /// rather than by reading the code.
    private let closeDescriptor: @Sendable (Int32) -> Void

    package init(
        directories: [URL],
        debounceInterval: TimeInterval = 0.5,
        closeDescriptor: @escaping @Sendable (Int32) -> Void = { close($0) },
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.debounceInterval = debounceInterval
        self.closeDescriptor = closeDescriptor

        for dir in directories {
            let path = dir.path(percentEncoded: false)
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                self?.scheduleReload()
            }

            // The fd and the closer are captured by value, not through `self`:
            // a cancel scheduled by `deinit` runs after the watcher is gone,
            // and a handler that reached for `self` would find nil and leak
            // the descriptor.
            source.setCancelHandler { [closeDescriptor, fd] in
                closeDescriptor(fd)
            }

            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
