import Foundation

/// Every configuration change an agent asked for through its own tools that
/// waited on a person's approval (`GlobalConfig.agentChangesNeedingApproval`),
/// approved or denied — one line each.
///
/// Project-local, JSONL-backed at `<project>/.kiteloop/config-changes.jsonl`,
/// written the way `FindingOverrideLedger` is.
package enum ConfigChangeLog {

    /// What a person decided on one requested change.
    package enum Decision: String, Codable, Sendable {
        case approved
        case denied
    }

    /// One decided request: who asked, what kind of change through which tool,
    /// the state before and the state it asked for, and the answer.
    package struct Record: Codable, Equatable, Sendable {
        package let requestedBy: String
        package let kind: String
        package let tool: String
        package let before: String
        package let after: String
        package let decision: Decision
        package let at: Date

        package init(requestedBy: String, kind: String, tool: String, before: String, after: String,
                     decision: Decision, at: Date) {
            self.requestedBy = requestedBy
            self.kind = kind
            self.tool = tool
            self.before = before
            self.after = after
            self.decision = decision
            self.at = at
        }
    }

    /// Where a project's change log lives.
    package static func url(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appending(path: ".kiteloop")
            .appending(path: "config-changes.jsonl")
    }

    /// Appends one record, making the `.kiteloop` directory on a project's
    /// first one — through `AtomicFileWriter`, so a kill mid-append costs at
    /// most this line rather than the log.
    package static func append(_ record: Record, to url: URL) throws {
        guard let line = encode(record) else { return }
        try AtomicFileWriter.append(Data(line.utf8), to: url)
    }

    /// Every record, oldest first — empty when there is no log. A line that
    /// does not decode, such as a last line cut short by a kill, is skipped
    /// and every complete record before it is still read back.
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
