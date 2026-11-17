import CryptoKit
import Foundation

/// Every configuration change an agent asked for that waited on a person's
/// approval, one line each: through its own tools
/// (`GlobalConfig.agentChangesNeedingApproval`), approved or denied, or over
/// the control API (`ConfigChangeGate`), approved, denied or abandoned.
///
/// One JSONL file for every project, in the app's own directory
/// (`~/.kiteloop/config-changes.jsonl`), each line naming the project it is
/// about — not inside a project folder, where the agents it records work and
/// one with Write could edit it. That removes the easy path and no more: an
/// agent with Bash runs as the same user and can still reach the file.
///
/// Each line after the first carries `prev`, the SHA-256 of the line before
/// it, so a line edited or removed in the middle shows as a break at the next
/// one (`firstBrokenLine`). It does not show a log cut short at its end, nor
/// one rewritten whole with the hashes recomputed.
package enum ConfigChangeLog {

    /// What a person decided on one requested change.
    package enum Decision: String, Codable, Sendable {
        case approved
        case denied
        /// Nobody answered and nothing was applied: the request the card
        /// waited on ended first — the agent was stopped or restarted, or
        /// the app quit.
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
        /// The folder of the project the change is about; nil for a change to
        /// the app as a whole, and on a line written before lines carried it.
        package let project: String?

        package init(requestedBy: String, kind: String, tool: String, before: String, after: String,
                     decision: Decision, at: Date, project: String? = nil) {
            self.project = project
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
        package init(caller: String, route: String, summary: String, decision: Decision, at: Date,
                     project: String? = nil) {
            self.requestedBy = caller
            self.kind = "api"
            self.tool = route
            self.before = ""
            self.after = summary
            self.decision = decision
            self.at = at
            self.project = project
        }
    }

    /// Where the log lives: one file in the app's own directory, for changes
    /// to the app as a whole and to every project alike.
    package static func url(appDirectory: URL) -> URL {
        appDirectory.appending(path: "config-changes.jsonl")
    }

    /// Appends one record, chained to the line before it — through
    /// `AtomicFileWriter`, so a kill mid-append costs at most this line
    /// rather than the log.
    package static func append(_ record: Record, to url: URL) throws {
        let chained = Line(record: record, prev: lines(of: url).last.map(digest))
        guard let line = encode(chained) else { return }
        try AtomicFileWriter.append(Data(line.utf8), to: url)
    }

    /// The number, from 1, of the first line that does not carry the hash of
    /// the line before it — nil for a log whose chain holds. Lines written
    /// before lines were chained carry no hash and are passed over until the
    /// first that does; from there on every line must.
    package static func firstBrokenLine(in url: URL) -> Int? {
        let all = lines(of: url)
        var chained = false
        for (index, line) in all.enumerated() {
            let carried = (try? JSONDecoder().decode(Link.self, from: line))?.prev
            chained = chained || carried != nil
            let expected = index == 0 ? nil : digest(all[index - 1])
            if chained, carried != expected { return index + 1 }
        }
        return nil
    }

    /// Every record, oldest first — empty when there is no log. A line that
    /// does not decode, such as a last line cut short by a kill, is skipped
    /// and every complete record before it is still read back.
    package static func read(from url: URL) -> [Record] {
        AtomicFileWriter.loadLines(from: url, as: Record.self)
    }

    /// A record as it is written: its own fields, and the link to the line before.
    private struct Line: Encodable {
        let record: Record
        let prev: String?

        func encode(to encoder: Encoder) throws {
            try record.encode(to: encoder)
            var link = encoder.container(keyedBy: Link.CodingKeys.self)
            try link.encodeIfPresent(prev, forKey: .prev)
        }
    }

    private struct Link: Decodable {
        let prev: String?
        enum CodingKeys: String, CodingKey { case prev }
    }

    private static func lines(of url: URL) -> [Data] {
        guard let content = try? Data(contentsOf: url) else { return [] }
        return content.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    private static func digest(_ line: Data) -> String {
        SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ record: Line) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line + "\n"
    }
}
