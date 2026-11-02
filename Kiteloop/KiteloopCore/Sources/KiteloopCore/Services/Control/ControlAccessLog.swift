import Foundation

/// One line per control API request, in `~/.kiteloop/logs/control-access.log`,
/// so what was driven from the phone can be read back afterwards: when, what,
/// with which credential, and how it was answered. Never a body, a query
/// string or a token. Rotated at `cap`, keeping one older file beside it.
package actor ControlAccessLog {
    private let url: URL
    private let cap: Int

    /// Big enough for weeks of a phone's polling, small enough to open in an editor.
    package static let defaultCap = 2 * 1024 * 1024

    package init(url: URL, cap: Int = ControlAccessLog.defaultCap) {
        self.url = url
        self.cap = cap
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/logs/control-access.log")
    }

    /// The line a request leaves: tab-separated time, method, path without
    /// its query, credential, status and milliseconds.
    package static func line(at date: Date, method: String, path: String, credential: String,
                             status: Int, milliseconds: Int) -> String {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return [ISO8601DateFormatter().string(from: date), method, bare, credential, String(status), "\(milliseconds)ms"]
            .joined(separator: "\t")
    }

    package func record(at date: Date, method: String, path: String, credential: String,
                        status: Int, milliseconds: Int) {
        let line = Self.line(at: date, method: method, path: path, credential: credential,
                             status: status, milliseconds: milliseconds) + "\n"
        rotateIfFull()
        let filePath = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: filePath) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The file past `cap` becomes `control-access.log.1`, replacing the one before.
    private func rotateIfFull() {
        // Asked of the file system each time: a URL caches its resource values,
        // so `resourceValues` on the stored URL would read the first size forever.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        guard size >= cap else { return }
        let older = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: older)
        try? FileManager.default.moveItem(at: url, to: older)
    }
}
