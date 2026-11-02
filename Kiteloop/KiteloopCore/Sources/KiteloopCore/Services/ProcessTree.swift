import Foundation

/// Collects and sweeps a `Process`'s descendants — shared by every caller that
/// signals a subprocess directly rather than an entire tree.
///
/// Signalling a `Process` alone only reaches the shell (or whatever it exec'd
/// into) — never anything that process forked, which TERM and KILL both leave
/// running and reparented. `descendantPIDs(of:)` must run *before* the root is
/// signalled: it walks parent links with `pgrep -P`, which only the
/// still-running child reports; a killed or reparented process no longer does.
package enum ProcessTree {
    /// Every pid descended from `pid`, walked breadth-first with `pgrep -P`.
    /// Must run before `pid` is signalled: `pgrep -P` reads the parent link off
    /// the still-running child, and a killed or reparented process no longer
    /// reports one.
    package static func descendantPIDs(of pid: pid_t) -> [pid_t] {
        var all: [pid_t] = []
        var frontier = [pid]
        while !frontier.isEmpty {
            let next = frontier.flatMap { children(of: $0) }
            all.append(contentsOf: next)
            frontier = next
        }
        return all
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0) }
    }

    /// TERMs every pid still alive, gives it the same grace period the root
    /// process got, then KILLs whatever didn't take the hint. Only ever called
    /// with pids collected as descendants of the process this call started —
    /// nothing here matches on command text.
    package static func killDescendants(_ pids: [pid_t]) {
        let alive = pids.filter { kill($0, 0) == 0 }
        guard !alive.isEmpty else { return }
        for pid in alive { kill(pid, SIGTERM) }
        usleep(500_000)
        for pid in alive where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Tears down several roots together — every process this app started
    /// still running, not one it merely knows about. Each root's descendants
    /// are collected *before any root is signalled*, same as a lone call to
    /// `descendantPIDs(of:)` requires, so the tree is still intact for
    /// `pgrep -P` to walk. Roots and their collected descendants are then
    /// TERMed together, given one shared grace period, and whatever is still
    /// alive across both sets is KILLed — exactly one grace period per call,
    /// whatever it is handed. That matters because the whole sweep is
    /// synchronous and `Orchestrator` is `@MainActor`: every `usleep` here is a
    /// frozen window. Nothing in this call matches on command text; the
    /// descendants swept are only the pids collected above.
    package static func terminateAll(_ processes: [Process]) {
        let roots = processes.filter { $0.isRunning }
        guard !roots.isEmpty else { return }

        let descendants = roots.flatMap { descendantPIDs(of: $0.processIdentifier) }

        for root in roots { root.terminate() }
        sendSignal(SIGTERM, toAliveIn: descendants)
        usleep(500_000)
        for root in roots where root.isRunning {
            kill(root.processIdentifier, SIGKILL)
        }
        sendSignal(SIGKILL, toAliveIn: descendants)
    }

    /// Sends `signalNumber` to whichever of `pids` is still alive.
    private static func sendSignal(_ signalNumber: Int32, toAliveIn pids: [pid_t]) {
        for pid in pids where kill(pid, 0) == 0 { kill(pid, signalNumber) }
    }
}
