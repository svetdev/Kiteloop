import Foundation
import os

private let tokenStoreLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "token-store")

/// The provider API keys — the Anthropic key and the `jira` token — in
/// `~/.kiteloop/tokens.json`.
///
/// The static entry points are the whole of the app's use of this type;
/// `shared` is what they delegate to. The instance exists so a test can point
/// the store at a temp directory rather than the developer's own keys.
package struct TokenStore {

    /// The three states the file can be in. Two of them used to be one: any
    /// failure to decode came back as an empty dictionary, so a single value the
    /// decoder could not read made *every* token read as absent — and the next
    /// `set` then wrote a dictionary holding only the key just saved over the
    /// top of it. The key was not merely unreadable at that point, it was gone,
    /// and the app fell back as though it had never been configured.
    package enum Contents: Equatable {
        case absent
        case decoded([String: String])
        /// The file is there and its bytes are not a `[String: String]`.
        case unreadable
    }

    package let fileURL: URL

    package static let shared = TokenStore(fileURL: defaultFileURL)

    private static let defaultFileURL: URL = {
        let home = KiteloopHome.url
        let dir = home.appending(path: ".kiteloop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "tokens.json")
    }()

    // MARK: - Static call sites

    package static func get(_ key: String) -> String? { shared.get(key) }

    package static func set(_ key: String, value: String) -> Bool { shared.set(key, value: value) }

    package static func remove(_ key: String) -> Bool { shared.remove(key) }

    // MARK: - Instance

    package func get(_ key: String) -> String? {
        guard case .decoded(let dict) = load() else { return nil }
        return dict[key]
    }

    /// Answers whether the new tokens reached disk.
    @discardableResult
    package func set(_ key: String, value: String) -> Bool { update { $0[key] = value } }

    @discardableResult
    package func remove(_ key: String) -> Bool { update { $0.removeValue(forKey: key) } }

    /// Reads the file, applies `change`, and writes the result back.
    ///
    /// A file that did not decode is moved aside first, and the write is
    /// abandoned if it could not be: the bytes are somebody's API keys, and
    /// replacing them with a dictionary holding one key is the one step that
    /// cannot be undone — the same choice `RunRecordStore` makes for a line it
    /// cannot decode. A move that fails means a directory nothing can write to,
    /// so false covers both the save it skips and a write that did not land.
    private func update(_ change: (inout [String: String]) -> Void) -> Bool {
        var dict: [String: String] = [:]
        switch load() {
        case .absent:
            break
        case .decoded(let existing):
            dict = existing
        case .unreadable:
            guard moveAsideUnreadableFile() else { return false }
        }
        change(&dict)
        return Self.save(dict, to: fileURL)
    }

    /// Distinguishes "no file" from "a file nobody can read" — see `Contents`.
    package func load() -> Contents {
        guard let data = try? Data(contentsOf: fileURL) else { return .absent }
        guard let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .unreadable
        }
        return .decoded(dict)
    }

    /// Renames the file to a `tokens.json.corrupt-<stamp>` sibling, so the app
    /// starts over with a file it can read while the old content stays on disk
    /// for someone to recover the keys from. Answers whether it worked.
    ///
    /// A sibling rather than a temp directory: the rename has to stay on one
    /// volume, and it keeps the salvage next to the file it came from.
    private func moveAsideUnreadableFile() -> Bool {
        let name = fileURL.lastPathComponent
        let destination = Self.unusedSibling(of: fileURL, named: "\(name).corrupt-\(Self.stamp())")

        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            kiteloopLog(
                """
                [token-store] \(name) could not be decoded and could not be moved \
                aside to \(destination.lastPathComponent): \(error.localizedDescription) \
                — leaving it in place rather than overwriting it, so this save is skipped
                """,
                category: "token-store",
                level: .error
            )
            return false
        }

        kiteloopLog(
            """
            [token-store] \(name) could not be decoded; moved it aside to \
            \(destination.lastPathComponent) and started a new one. The tokens it \
            held will have to be entered again, and are still recoverable from that file.
            """,
            category: "token-store",
            level: .error
        )
        return true
    }

    /// The first of `name`, `name-2`, `name-3`… that nothing occupies.
    ///
    /// `moveItem` refuses to replace an existing file, and the stamp resolves to
    /// the second — so without this, two unreadable files in one second would
    /// leave the second move failing and its save skipped.
    private static func unusedSibling(of url: URL, named name: String) -> URL {
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appending(path: name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(name)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Sortable, filename-safe, and second-resolution.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Writing

    /// Writes the provider tokens owner-only in one step, rather than writing at
    /// whatever the umask gives and chmod'ing after.
    ///
    /// This file holds API keys, and an atomic write renames a *new* file into
    /// place on every save — so a write-then-chmod pair reopens the window each
    /// time, not only on the first save, and a chmod that failed said nothing.
    ///
    /// The URL is a parameter so a test can write somewhere other than the
    /// user's own `~/.kiteloop/tokens.json`. Answers whether the bytes landed.
    @discardableResult
    package static func save(_ dict: [String: String], to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do { try AtomicFileWriter.write(data, to: url, mode: 0o600) } catch {
            tokenStoreLog.error("""
                provider tokens could not be written to \
                \(url.path(percentEncoded: false), privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return false
        }
        return true
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(fileURL: URL) {
        self.fileURL = fileURL
    }
}
