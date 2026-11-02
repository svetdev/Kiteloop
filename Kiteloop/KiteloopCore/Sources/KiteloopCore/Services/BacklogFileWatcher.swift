import Foundation
import os.log

private let watcherLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-watcher")

/// Watches a backlog file for edits made outside the app.
///
/// Two dispatch sources, because one is not enough:
///
/// - The **file** source (an `O_EVTONLY` fd) sees ordinary in-place writes.
/// - The **directory** source sees replacements. A write-to-temp + rename — what
///   most editors do, and what every `write(…, atomically: true)` does — unlinks
///   the inode the fd names, so the fd goes deaf and every later edit lands on a
///   file it can no longer see. Watching the containing directory survives that,
///   and it also catches a file that is removed now and recreated a moment later,
///   where re-opening the path straight away would simply fail.
///
/// Directory events are noisy — any sibling file in the project root counts — so
/// they only wake the callback when the backlog file's own identity (inode, size,
/// mtime) actually changed.
///
/// One rule the rest of this file exists to protect: **re-arming must never cancel
/// a pending reload.** Re-arming used to go through `stop()`, which cancels the
/// debounced callback, so an atomic replace fired its own event and then swallowed
/// the notification — the watcher looked alive and the app never saw an external
/// edit until it was restarted.
package final class BacklogFileWatcher: @unchecked Sendable {

    /// Identity of the watched file, so a directory event can tell a real edit
    /// from churn in a sibling file.
    private struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private let onChange: @Sendable () -> Void
    private let debounceInterval: TimeInterval
    /// Serial, so an event, a re-arm and the debounced callback never interleave.
    private let queue = DispatchQueue(label: "ai.kasatkin.kiteloop.backlog-watcher", qos: .utility)

    private let lock = NSLock()
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var lastSignature: Signature?
    private var currentURL: URL?

    package var watchedURL: URL? { lock.withLock { currentURL } }

    package init(debounceInterval: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounceInterval = debounceInterval
    }

    package func watch(url: URL) {
        stop()
        let signature = Self.signature(of: url)
        lock.withLock {
            currentURL = url
            lastSignature = signature
        }
        armFileSource(url: url)
        armDirectorySource(for: url)
        watcherLog.info("Watching backlog file: \(url.path(percentEncoded: false))")
    }

    package func stop() {
        let (file, directory, work) = lock.withLock {
            let taken = (fileSource, directorySource, debounceWork)
            fileSource = nil
            directorySource = nil
            debounceWork = nil
            currentURL = nil
            lastSignature = nil
            return taken
        }
        work?.cancel()
        file?.cancel()
        directory?.cancel()
    }

    deinit {
        stop()
    }

    // MARK: - Sources

    private func armFileSource(url: URL) {
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Not fatal: the directory source picks the file up when it appears,
            // which is exactly the window between a delete and its rewrite.
            watcherLog.info("Backlog file not available to watch yet: \(path)")
            replaceFileSource(with: nil)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let url = self.watchedURL else { return }
            // Re-arm on *every* event rather than inspecting the event flags: a
            // rename or delete orphans this fd, and re-opening a path that hasn't
            // moved costs two syscalls. Reading the flags would mean holding a
            // reference to the source from its own handler, which is either a
            // retain cycle or a race — and getting that wrong means going deaf.
            self.armFileSource(url: url)
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        replaceFileSource(with: source)
    }

    private func armDirectorySource(for url: URL) {
        let directory = url.deletingLastPathComponent()
        let path = directory.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            watcherLog.error("Cannot watch backlog directory: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.directoryChanged()
        }
        source.setCancelHandler { close(fd) }
        source.resume()

        var stale: DispatchSourceFileSystemObject?
        lock.withLock {
            if currentURL == nil {
                stale = source          // stopped while we were arming
            } else {
                stale = directorySource
                directorySource = source
            }
        }
        stale?.cancel()
    }

    /// Installs `source` as the file source, handing back whatever it displaced
    /// so it can be cancelled outside the lock.
    private func replaceFileSource(with source: DispatchSourceFileSystemObject?) {
        var stale: DispatchSourceFileSystemObject?
        lock.withLock {
            if currentURL == nil {
                stale = source          // stopped while we were arming
            } else {
                stale = fileSource
                fileSource = source
            }
        }
        stale?.cancel()
    }

    // MARK: - Change handling

    /// Something in the watched directory moved. Only the backlog file matters,
    /// and only if its identity changed — a replace gives it a new inode, so the
    /// file source has to be rebound to it before the reload is reported.
    private func directoryChanged() {
        guard let url = watchedURL else { return }
        let current = Self.signature(of: url)
        let changed = lock.withLock { () -> Bool in
            guard current != lastSignature else { return false }
            lastSignature = current
            return true
        }
        guard changed else { return }
        armFileSource(url: url)
        scheduleReload()
    }

    private func scheduleReload() {
        guard let url = watchedURL else { return }
        let signature = Self.signature(of: url)
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        let scheduled = lock.withLock { () -> Bool in
            guard currentURL != nil else { return false }
            lastSignature = signature
            debounceWork?.cancel()
            debounceWork = work
            return true
        }
        guard scheduled else { return }
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private static func signature(of url: URL) -> Signature? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return Signature(
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
