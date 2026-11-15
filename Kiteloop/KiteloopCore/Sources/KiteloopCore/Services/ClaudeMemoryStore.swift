import Foundation

/// One file of the memory the Claude CLI keeps for a project: a note with
/// front matter, or the index (`MEMORY.md`) every session of that project is
/// shown.
package struct ClaudeMemoryNote: Identifiable, Equatable, Sendable {
    /// The file's name without `.md`.
    package let id: String
    /// The whole file, front matter included — what an edit replaces.
    package let text: String

    package init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    /// The index is the one file the CLI loads whole; the notes are read when
    /// a line in it looks relevant.
    package var isIndex: Bool { id == ClaudeMemoryStore.indexName }

    /// What the note calls itself, or its file name when it does not say.
    package var name: String { isIndex ? "MEMORY.md" : (field("name") ?? id) }

    /// The one line the CLI reads to decide whether the note is relevant.
    package var summary: String? { isIndex ? "The index every chat session in this project is shown." : field("description") }

    /// `user`, `feedback`, `project` or `reference`, when the note says.
    package var kind: String? { field("type") }

    /// The note without its front matter.
    package var body: String {
        let lines = text.components(separatedBy: "\n")
        guard let close = frontMatterEnd(in: lines) else { return text }
        return lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A front-matter value by key, at any indent — `type:` sits under
    /// `metadata:` in the notes the CLI writes now and at the top in older ones.
    private func field(_ key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let close = frontMatterEnd(in: lines) else { return nil }
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func frontMatterEnd(in lines: [String]) -> Int? {
        guard lines.first == "---" else { return nil }
        return lines.dropFirst().firstIndex(of: "---")
    }
}

/// The memory folder the Claude CLI keeps for a project —
/// `~/.claude/projects/<slug>/memory/` — read and edited as files.
///
/// Kiteloop does not own this folder: the CLI of a chat session writes it and
/// reads it back. Nothing here interprets a note beyond its front matter, and
/// a write replaces exactly one file.
package struct ClaudeMemoryStore: Sendable {
    package static let indexName = "MEMORY"

    /// Where the notes are. May not exist: a project nobody has chatted in has
    /// no memory yet.
    package let directory: URL

    /// - Parameter configDirectory: the CLI's own folder; `CLAUDE_CONFIG_DIR`
    ///   when the environment sets it, `~/.claude` otherwise.
    package init(projectRoot: URL, configDirectory: URL? = nil) {
        let root = Self.repositoryRoot(of: projectRoot)
        let config = configDirectory ?? Self.configDirectory(environment: ProcessInfo.processInfo.environment)
        directory = config
            .appending(path: "projects")
            .appending(path: Self.slug(for: root.path(percentEncoded: false)))
            .appending(path: "memory")
    }

    package static func configDirectory(environment: [String: String]) -> URL {
        let named = environment["CLAUDE_CONFIG_DIR"] ?? ""
        guard !named.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude") }
        return URL(fileURLWithPath: (named as NSString).expandingTildeInPath)
    }

    /// The folder name the CLI gives a path: every character that is not an
    /// ASCII letter or digit becomes `-`.
    package static func slug(for path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return String(trimmed.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The repository a folder belongs to, with symlinks resolved — the CLI
    /// keys its memory to that, so a project opened on a subfolder and a linked
    /// worktree both share their repository's notes. A folder in no repository
    /// is its own root.
    package static func repositoryRoot(of folder: URL) -> URL {
        let start = resolved(folder)
        var candidate = start
        while candidate.path(percentEncoded: false) != "/" {
            let marker = candidate.appending(path: ".git")
            if let main = mainCheckout(ofWorktreeMarker: marker) { return main }
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return start
    }

    /// A linked worktree's `.git` is a file naming `<main>/.git/worktrees/<name>`.
    private static func mainCheckout(ofWorktreeMarker marker: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let text = try? String(contentsOf: marker, encoding: .utf8),
              let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("gitdir:") }),
              let range = line.range(of: "/.git/worktrees/") else { return nil }
        let path = line[line.index(line.startIndex, offsetBy: "gitdir:".count)..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return resolved(URL(fileURLWithPath: path))
    }

    /// `realpath`, because Foundation's own resolution drops `/private` from a
    /// path and the CLI's does not.
    private static func resolved(_ url: URL) -> URL {
        guard let real = realpath(url.path(percentEncoded: false), nil) else { return url.standardizedFileURL }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    /// The index first, then every note by name. Empty when the folder is not
    /// there.
    package func notes() -> [ClaudeMemoryNote] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let notes = names.filter { $0.hasSuffix(".md") }.compactMap { name -> ClaudeMemoryNote? in
            guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
            return ClaudeMemoryNote(id: String(name.dropLast(3)), text: String(decoding: data, as: UTF8.self))
        }
        return notes.sorted { ($0.isIndex ? 0 : 1, $0.name.lowercased(), $0.id) < ($1.isIndex ? 0 : 1, $1.name.lowercased(), $1.id) }
    }

    /// One file as it is on disk now, or nil when it is gone.
    package func text(of id: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces one file's text.
    package func save(id: String, text: String) throws {
        try text.write(to: url(for: id), atomically: true, encoding: .utf8)
    }

    /// Removes a note and the index lines that point at it. The index itself
    /// is not a note and is never removed here.
    package func delete(id: String) throws {
        guard id != Self.indexName else { return }
        try FileManager.default.removeItem(at: url(for: id))
        guard let index = text(of: Self.indexName) else { return }
        let kept = index.components(separatedBy: "\n").filter { !$0.contains("(\(id).md)") }
        try save(id: Self.indexName, text: kept.joined(separator: "\n"))
    }

    private func url(for id: String) -> URL {
        directory.appending(path: "\(id).md")
    }
}
