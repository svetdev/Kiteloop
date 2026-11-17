import Foundation

/// Every configuration change an agent asked for that waited on a person's
/// approval, one line each: through its own tools
/// (`GlobalConfig.agentChangesNeedingApproval`), approved or denied, or over
/// the control API (`ConfigChangeGate`), approved, denied or abandoned.
///
/// Project-local, JSONL-backed at `<project>/.kiteloop/config-changes.jsonl`,
/// written the way `FindingOverrideLedger` is.
package enum ConfigChangeLog {

    /// What a person decided on one requested change.
    package enum Decision: String, Codable, Sendable {
        case approved
        case denied
        /// A change asked for over the control API whose caller hung up
        /// before the answer: nothing was applied, whatever was answered.
        case abandoned
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

        /// A change asked for over the control API, in the same columns: the
        /// credential's name as who asked, `api` as the kind, the method and
        /// path as the tool, and the request's summary as what it asked for.
        package init(caller: String, route: String, summary: String, decision: Decision, at: Date) {
            self.init(requestedBy: caller, kind: "api", tool: route, before: "", after: summary,
                      decision: decision, at: at)
        }
    }

    /// Where the log of changes to the app as a whole lives: those a call
    /// names no open project for, such as an MCP server or an app setting.
    package static func url(appDirectory: URL) -> URL {
        appDirectory.appending(path: "config-changes.jsonl")
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
