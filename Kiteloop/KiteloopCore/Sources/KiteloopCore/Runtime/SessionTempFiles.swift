import Foundation

/// Naming and teardown for the per-session scratch files the CLI runtime drops
/// in the temp directory — the tool bridge's FIFOs and the MCP config that
/// points Claude Code at them.
///
/// Creation and removal used to build these paths independently at four call
/// sites, and nothing removed them when the app died without running its
/// termination handlers (crash, force quit, the XCTest host taking the app
/// down). Every name now carries the pid that created it, so a later launch can
/// tell its own live files apart from the wreckage of a previous one and reap
/// the rest.
package enum SessionTempFiles {

    /// The per-session artifacts a session can own. The raw value is the
    /// filename suffix, which is also what makes each kind distinguishable on
    /// disk — keep them mutually non-prefixing.
    package enum Kind: String, CaseIterable {
        case toolResponsePipe = "tools-res.pipe"
        case toolRequestPipe = "tools-req.pipe"
        case toolMCPConfig = "tools-mcp.json"
        case globalMCPConfig = "global-mcp.json"
    }

    /// Which end of a FIFO Kiteloop itself holds. Teardown opens the *opposite*
    /// end briefly, so a peer parked in `open(2)` is released before the path
    /// disappears.
    package enum Role {
        case kiteloopReads
        case kiteloopWrites
    }

    package static let prefix = "kiteloop-"

    /// The tool bridge's script is shared by every session and rewritten on each
    /// spawn, so it is never session garbage.
    package static let sharedScriptNames: Set<String> = [
        "kiteloop-tool-bridge.js"
    ]

    /// Session artifacts written before names carried a pid — including the
    /// permission bridge's FIFO and config, which no build writes any more. Only
    /// a build older than this one can have produced them, so at launch they are
    /// orphans by definition.
    package static let legacyPrefixes = ["kiteloop-perm-", "kiteloop-mcp-", "kiteloop-tools-"]

    // MARK: - Naming

    package static func fileName(for kind: Kind, sessionID: String, pid: pid_t = getpid()) -> String {
        "\(prefix)\(pid)-\(sessionID)-\(kind.rawValue)"
    }

    package static func path(
        for kind: Kind,
        sessionID: String,
        in directory: URL = FileManager.default.temporaryDirectory,
        pid: pid_t = getpid()
    ) -> String {
        directory
            .appendingPathComponent(fileName(for: kind, sessionID: sessionID, pid: pid))
            .path(percentEncoded: false)
    }

    // MARK: - Teardown

    /// Removes a FIFO, first waking anything parked on the other end.
    ///
    /// A blocking FIFO `open(2)` only returns once a peer opens the opposite
    /// end, and `unlink` does not wake it — the reader thread and its descriptor
    /// would stay parked for the life of the app. Opening the other end for a
    /// moment releases the peer, which then sees EOF and unwinds.
    package static func removeFIFO(at path: String, role: Role) {
        // O_NONBLOCK so this call never parks in turn: opening the read end of a
        // FIFO always succeeds, and opening the write end fails immediately with
        // ENXIO when there is no reader to release.
        let flags = (role == .kiteloopReads ? O_WRONLY : O_RDONLY) | O_NONBLOCK
        let fd = open(path, flags)
        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    package static func remove(at path: String) {
        unlink(path)
    }

    // MARK: - Reaping

    /// True when `name` is a session artifact left behind by a process that is
    /// no longer running.
    ///
    /// The pid in the name only identifies its owner within one boot: pids are
    /// handed out from low numbers again after a restart, so a file left by a
    /// crash before a reboot very often names a pid some unrelated process now
    /// holds — and the per-user temp directory survives the reboot, so it would
    /// read as live at every launch from then on. An artifact written before the
    /// machine booted therefore cannot belong to anything running now, whatever
    /// its pid says. Both dates are optional: with either missing the pid rule
    /// decides on its own, as it always has.
    package static func isOrphan(
        _ name: String,
        isAlive: (pid_t) -> Bool = processIsAlive,
        modified: Date? = nil,
        bootedAt: Date? = nil
    ) -> Bool {
        guard name.hasPrefix(prefix), !sharedScriptNames.contains(name) else { return false }
        if let owner = owningPID(name) {
            if let modified, let bootedAt, modified < bootedAt { return true }
            return !isAlive(owner)
        }
        return legacyPrefixes.contains { name.hasPrefix($0) }
    }

    /// Extracts the pid from `kiteloop-<pid>-<sessionID>-<kind>`. Returns nil for
    /// any name that does not carry one, including the legacy scheme and the
    /// unrelated `kiteloop-test-*` scratch files the test suite makes.
    package static func owningPID(_ name: String) -> pid_t? {
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return pid_t(rest[rest.startIndex..<dash])
    }

    package static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to someone else.
        return errno == EPERM
    }

    /// When the machine last booted, from `kern.boottime` — the same value
    /// `sysctl -n kern.boottime` prints. Nil when the sysctl cannot be read, in
    /// which case the sweep falls back to the pid rule alone rather than
    /// deleting something it cannot justify.
    package static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }

    /// Deletes every session artifact whose owning process is gone. Called at
    /// launch so a crash or force quit costs one generation of leaked FIFOs
    /// rather than accumulating them until the descriptor limit bites.
    /// Returns the number of files removed.
    @discardableResult
    package static func reapOrphans(
        in directory: URL = FileManager.default.temporaryDirectory,
        isAlive: (pid_t) -> Bool = processIsAlive,
        bootDate: () -> Date? = bootDate
    ) -> Int {
        let path = directory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return 0 }

        // Read once for the whole sweep: it is one number for the machine, not
        // a property of any file.
        let bootedAt = bootDate()

        var reaped = 0
        for name in names {
            let url = directory.appendingPathComponent(name)
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard isOrphan(name, isAlive: isAlive, modified: modified, bootedAt: bootedAt) else { continue }
            // The owner is dead, so nothing can be parked on these FIFOs.
            if unlink(url.path(percentEncoded: false)) == 0 {
                reaped += 1
            }
        }
        return reaped
    }
}
