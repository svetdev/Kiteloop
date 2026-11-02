import Foundation

/// What a reviewer's prompt is handed about the diff's shape, ahead of the
/// verdict — a per-file line-count list, and the two facts a rubric asks a
/// reader to notice by their *absence*: whether any changed file is a test,
/// and whether `CHANGELOG.md` is among them. Both are computed here rather
/// than left for the reviewer to reconstruct after reading hundreds of lines
/// that are all present — the one shape a diff's negative space never is.
///
/// States, does not gate: nothing here is a verdict. A documentation-only
/// diff answers "no" to both questions and that is the correct answer, not a
/// defect — `DiffRules` already treats a missing changelog line as advisory
/// for exactly that reason, and this type draws no conclusion at all.
package enum ReviewerDiffFacts {

    /// A changed file with the line counts `git diff --numstat` reported for
    /// it. Both are `nil` for a binary file, matching numstat's own `-`
    /// placeholder rather than inventing a zero.
    package struct ChangedFile: Equatable, Sendable {
        package let path: String
        package let added: Int?
        package let deleted: Int?

        package init(path: String, added: Int?, deleted: Int?) {
            self.path = path
            self.added = added
            self.deleted = deleted
        }
    }

    /// True for a path this repo's own layout puts under a test target:
    /// `KiteloopTests/`, a `Tests/` directory inside a Swift package (e.g.
    /// `KiteloopCore/Tests/`), or a `*Tests.swift` file wherever it lives.
    package static func isTestFile(_ path: String) -> Bool {
        path.contains("KiteloopTests/") || path.contains("/Tests/") || path.hasSuffix("Tests.swift")
    }

    /// Parses `git diff --numstat` output — tab-separated
    /// `added\tdeleted\tpath` per line, `-` where numstat reports a binary
    /// file's counts. A line that doesn't split into exactly three fields is
    /// skipped rather than guessed at: this is read, not inferred.
    package static func parseNumstat(_ raw: String) -> [ChangedFile] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return ChangedFile(path: String(parts[2]), added: Int(parts[0]), deleted: Int(parts[1]))
        }
    }

    /// A new file's `added` count, counted the way numstat counts one: every
    /// newline byte, plus one for a last line with no trailing newline. Read
    /// as bytes, so one invalid UTF-8 byte in a text file does not make it
    /// binary; nil only for content git itself would call binary — a NUL byte.
    package static func newFileLineCount(_ data: Data) -> Int? {
        guard !data.contains(0x00) else { return nil }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last.map { $0 == 0x0A ? newlines : newlines + 1 } ?? 0
    }

    /// The block put in the reviewer's prompt. Nil for no changed files: an
    /// empty diff has nothing to summarise, and the reviewer's own prompt
    /// already refuses to pass one on other grounds.
    ///
    /// Bounded by file count, not by how many lines a run changed, so it
    /// stays whole — and both statements below stay correct — on a diff too
    /// large for its own body to reach a reader in full (`RunQualityJudge`'s
    /// `diffStat` answers the same need on the quality judge's side).
    package static func block(changedFiles: [ChangedFile]) -> String? {
        guard !changedFiles.isEmpty else { return nil }
        let testChanged = changedFiles.contains { isTestFile($0.path) }
        let changelogChanged = changedFiles.contains { $0.path == DiffRules.changelogPath }
        var lines = ["## Changed files"]
        for file in changedFiles {
            let added = file.added.map(String.init) ?? "-"
            let deleted = file.deleted.map(String.init) ?? "-"
            lines.append("- \(file.path) (+\(added)/-\(deleted))")
        }
        lines.append("")
        lines.append("Test files changed: \(testChanged ? "yes" : "no")")
        lines.append("CHANGELOG.md changed: \(changelogChanged ? "yes" : "no")")
        // Read against HEAD, so every file above is one the worker did not
        // commit. Said outright: a reviewer reading a diff has no way to notice
        // that the tree it reads was never committed, and teardown committing
        // it afterwards under the app's own subject is an advisory finding.
        lines.append("Uncommitted at handoff: \(changedFiles.count) file(s) — the worker did not commit; teardown will")
        return lines.joined(separator: "\n")
    }
}
