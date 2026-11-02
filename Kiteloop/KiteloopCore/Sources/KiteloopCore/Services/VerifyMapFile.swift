import Foundation
import os

/// Where a project's verify map is read from — the tracked file at its root,
/// or the old gitignored copy while that is all there is — and the map read
/// from there.
///
/// Kept apart from `VerifyCoverage.swift` on purpose: that file is the rules
/// themselves, which `scripts/verify-map-replay.sh` compiles on its own to
/// replay them over past commits, and it needs nothing of the app — a project,
/// a log — to do that.
package enum VerifyMapFile {
    /// The project's map, read from `KiteloopProject.verifyMapURL` — or,
    /// while only the old gitignored copy exists, from
    /// `legacyVerifyMapURL`, said once per path through `log`.
    package static func load(for project: KiteloopProject,
                             log: (String) -> Void = logToFile) -> VerifyCoverage.Map {
        VerifyCoverage.Map.load(from: url(for: project, log: log))
    }

    /// `loadReporting(from:)` over the file `load(for:)` reads.
    package static func loadReporting(for project: KiteloopProject,
                                      log: (String) -> Void = logToFile) -> (map: VerifyCoverage.Map, problem: String?) {
        VerifyCoverage.Map.loadReporting(from: url(for: project, log: log))
    }

    /// The root file when it is there, else the legacy file when *that* is
    /// there, else the root file — whose absence reads as `none`.
    package static func url(for project: KiteloopProject,
                            log: (String) -> Void = logToFile) -> URL {
        let fileManager = FileManager.default
        let legacy = project.legacyVerifyMapURL
        guard !fileManager.fileExists(atPath: project.verifyMapURL.path(percentEncoded: false)),
              fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else {
            return project.verifyMapURL
        }
        if legacyReported.withLock({ $0.insert(legacy.path(percentEncoded: false)).inserted }) {
            log("verify map read from \(legacy.path(percentEncoded: false)) — "
                + "move it to \(project.verifyMapURL.lastPathComponent) at the repository root")
        }
        return legacy
    }

    package static let logToFile: @Sendable (String) -> Void = { kiteloopLog($0, category: "verify-coverage") }

    /// The legacy paths already logged, so a fallback read on every run is
    /// said once rather than on every read.
    fileprivate static let legacyReported = OSAllocatedUnfairLock(initialState: Set<String>())
}
