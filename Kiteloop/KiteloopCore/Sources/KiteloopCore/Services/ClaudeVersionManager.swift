import Foundation

package protocol ClaudeVersionManaging: Sendable {
    func currentVersion() async -> String?
    func isPinned() async -> Bool
    func pinnedVersion() async -> String?
    func checkMismatch() async -> VersionMismatch?
}

package struct VersionMismatch: Sendable {
    package let installed: String
    package let pinned: String

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(installed: String, pinned: String) {
        self.installed = installed
        self.pinned = pinned
    }
}

package actor ClaudeVersionManager: ClaudeVersionManaging {
    private let pinnedVersionString: String?
    private var cachedVersion: String?

    package init(pinnedVersion: String? = nil) {
        self.pinnedVersionString = pinnedVersion
    }

    package func currentVersion() -> String? {
        if let cached = cachedVersion { return cached }
        cachedVersion = detectInstalledVersion()
        return cachedVersion
    }

    package func isPinned() -> Bool { pinnedVersionString != nil }

    package func pinnedVersion() -> String? { pinnedVersionString }

    package func checkMismatch() -> VersionMismatch? {
        guard let pinned = pinnedVersionString,
              let installed = currentVersion(),
              installed != pinned else { return nil }
        return VersionMismatch(installed: installed, pinned: pinned)
    }

    private func detectInstalledVersion() -> String? {
        guard let result = try? SubprocessOutput.run(
            executable: "/usr/bin/env",
            arguments: ["claude", "--version"]
        ) else { return nil }
        return parseVersion(result.trimmedOutput)
    }

    package static func parseVersion(_ output: String) -> String? {
        let pattern = #"(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    private func parseVersion(_ output: String) -> String? {
        Self.parseVersion(output)
    }

    package static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        return .orderedSame
    }
}
