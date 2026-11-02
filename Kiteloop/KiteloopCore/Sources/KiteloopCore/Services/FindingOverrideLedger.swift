import Foundation

/// One instance of a human approving an item at the gate whose last review
/// still carried a blocking finding — the strongest signal a project has about
/// which finding classes are worth blocking on, since the human saw the
/// objection and approved anyway.
///
/// Project-local, JSONL-backed at `<project>/.kiteloop/finding-overrides.jsonl`
/// — beside `coordinator-knowledge.md` rather than in the app-wide
/// `~/.kiteloop/` ledgers, because `RunKnowledgeDistiller` reads both by the
/// same `projectPath` and writes only that project's notes.
package enum FindingOverrideLedger {

    /// One override, written when the gate approves an item over a blocking
    /// finding of `findingClass` (`ReviewFindings.Finding.overrideClass`).
    package struct Record: Codable, Equatable, Sendable {
        package let itemID: String
        package let findingClass: String
        package let at: Date

        package init(itemID: String, findingClass: String, at: Date) {
            self.itemID = itemID
            self.findingClass = findingClass
            self.at = at
        }
    }

    /// Where a project's override ledger lives.
    package static func url(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appending(path: ".kiteloop")
            .appending(path: "finding-overrides.jsonl")
    }

    /// Appends one override, making the `.kiteloop` directory on a project's
    /// first one — through `AtomicFileWriter`, so a kill mid-append costs at
    /// most this line rather than corrupting the ledger.
    package static func append(_ record: Record, to url: URL) throws {
        guard let line = encode(record) else { return }
        try AtomicFileWriter.append(Data(line.utf8), to: url)
    }

    /// Every override on record, oldest first — empty when the project has
    /// never had one, and empty for a file that cannot be read at all. Read
    /// through `AtomicFileWriter.loadLines`, the read side of the `append`
    /// above: the bytes are split on the newline and each line is decoded on
    /// its own, so a line the decoder refuses is dropped and every complete
    /// override before it is still read back — a distiller run has nothing
    /// better to do with an unreadable line than skip it. That includes the
    /// truncation `append` is written to survive: a kill part-way through a
    /// multi-byte character leaves a last line that is not valid UTF-8, and
    /// reading the file as one string used to lose the whole ledger to it. A
    /// blank line contributes no entry and is not an error.
    package static func read(from url: URL) -> [Record] {
        AtomicFileWriter.loadLines(from: url, as: Record.self)
    }

    private static func encode(_ record: Record) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line + "\n"
    }
}
