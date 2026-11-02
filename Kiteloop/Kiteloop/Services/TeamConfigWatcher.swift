import Foundation

/// Watches the `.kiteloop/` directory for `team.json` modifications and posts a notification
/// when the file changes. This catches agents editing the config via Claude Code's Edit tool
/// or any other external modification.
final class TeamConfigWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    private let fileURL: URL
    private let debounceInterval: TimeInterval
    private var lastKnownModDate: Date?
    /// Handed what the changed file decoded to rather than a bare template
    /// array: a team.json in the package-ref shape — the one the setup wizard
    /// writes — carries refs, and only the main-actor `PackageResolver` can turn
    /// those into templates. Decoding it here and dropping it, which is what
    /// reading the file as `[AgentTemplate]` alone amounted to, left that shape
    /// unwatched despite being watched for.
    private let onChanged: @Sendable (ProjectSession.TeamConfigLoad) -> Void
    /// How the `O_EVTONLY` descriptor is released — `close(2)` in the app. A test
    /// substitutes a counting closer, which is the only way to assert the fd is
    /// released exactly once rather than by reading the code.
    private let closeDescriptor: @Sendable (Int32) -> Void

    init(
        teamConfigURL: URL,
        debounceInterval: TimeInterval = 0.8,
        closeDescriptor: @escaping @Sendable (Int32) -> Void = { close($0) },
        onChanged: @escaping @Sendable (ProjectSession.TeamConfigLoad) -> Void
    ) {
        self.fileURL = teamConfigURL
        self.debounceInterval = debounceInterval
        self.closeDescriptor = closeDescriptor
        self.onChanged = onChanged
        self.lastKnownModDate = modificationDate()
        startWatching()
    }

    deinit {
        stop()
    }

    /// Cancelling the source is the whole of it: its cancel handler owns the
    /// descriptor and closes it exactly once, whenever it happens to run.
    /// Closing here as well — which this did — closes the same number twice, and
    /// between the two closes the process can hand it to anything else that opens
    /// a file, a socket or one of the tool-bridge FIFOs, which the second close
    /// then shuts under its new owner. Idempotent: `source` is dropped here, so a
    /// second `stop()`, or the one `deinit` makes, cancels nothing.
    func stop() {
        source?.cancel()
        source = nil
    }

    func markCurrentAsKnown() {
        lastKnownModDate = modificationDate()
    }

    private func startWatching() {
        let dirPath = fileURL.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            self?.scheduleCheck()
        }

        // The fd and the closer are captured by value, not through `self`: a
        // cancel scheduled by `deinit` runs after the watcher is gone, and a
        // handler that reached for `self` would find nil and leak the descriptor.
        src.setCancelHandler { [weak self, closeDescriptor, fd] in
            closeDescriptor(fd)
            if let self, self.descriptor == fd { self.descriptor = -1 }
        }

        src.resume()
        source = src
    }

    private func scheduleCheck() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let currentMod = self.modificationDate()
            guard currentMod != self.lastKnownModDate else { return }
            self.lastKnownModDate = currentMod

            // Both team shapes are reported; a file that is gone, empty or of
            // neither shape says nothing to act on, and a live project keeps the
            // team it already has.
            let load = ProjectSession.loadTeamConfig(from: self.fileURL)
            switch load {
            case .templates, .packages:
                self.onChanged(load)
            case .absent, .unreadable:
                return
            }
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func modificationDate() -> Date? {
        let path = fileURL.path(percentEncoded: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
