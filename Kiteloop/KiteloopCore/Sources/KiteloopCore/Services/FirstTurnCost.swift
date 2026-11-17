import Foundation

/// What an agent's configuration puts in its context before anyone speaks,
/// part by part, split by how much is known of each part:
///
/// - ``sections`` — text Kiteloop itself composes or hands over, so its size
///   is measured: the system prompt's parts, the operator-tools note, the
///   definitions of Kiteloop's own tools.
/// - ``reported`` — an MCP server a session has started: the state and the
///   tool names the CLI reported then. The CLI does not report the schemas, so
///   there is no size.
/// - ``unmeasured`` — what Kiteloop has nothing on: a server no session has
///   reported, and the CLI's own prompt and tools.
///
/// A size is in bytes of UTF-8 text, because that is what can be measured
/// without the model's tokenizer; a token count would be a guess.
/// ``ContextOccupancy`` is the measured token figure, once a turn has run.
package struct FirstTurnCost: Equatable, Sendable {
    package struct Section: Equatable, Sendable {
        package let name: String
        package let bytes: Int
    }

    /// An MCP server as a session last reported it — `mcp:<server>`.
    package struct Reported: Equatable, Sendable {
        package let name: String
        package let state: String
        package let tools: [String]
        package let reportedAt: Date
    }

    /// A part that is in the context and that Kiteloop cannot size.
    package struct Unmeasured: Equatable, Sendable {
        package let name: String
        package let reason: String
    }

    /// The Claude CLI's own share, named once: Kiteloop starts the CLI and
    /// never sees what it sends the model.
    package static let cli = Unmeasured(
        name: "cli",
        reason: "The Claude CLI's own system prompt and built-in tools are added by the CLI; Kiteloop never sees them.")

    /// The sections that have text, in the order they were given.
    package let sections: [Section]
    /// The agent's MCP servers a session has reported, in the order given.
    package let reported: [Reported]
    /// The servers no session has reported, in the order given, then ``cli``
    /// for an agent the Claude CLI runs.
    package let unmeasured: [Unmeasured]

    /// `servers` are the MCP servers the agent's sessions are started with;
    /// `status` is what a session last reported of one, nil when none has.
    /// `startedByCLI` is false for an agent on a runtime other than the Claude
    /// CLI, which is given the sections and nothing else.
    package init(sections: [(name: String, text: String)],
                 servers: [String] = [],
                 startedByCLI: Bool = true,
                 status: (String) -> ConnectorStatus? = { _ in nil }) {
        self.sections = sections
            .map { Section(name: $0.name, bytes: $0.text.utf8.count) }
            .filter { $0.bytes > 0 }
        let known = servers.map { (name: $0, status: status($0)) }
        self.reported = known.compactMap { server in
            server.status.map {
                Reported(name: Self.serverName(server.name), state: $0.state, tools: $0.tools, reportedAt: $0.reportedAt)
            }
        }
        self.unmeasured = known.filter { $0.status == nil }.map {
            Unmeasured(name: Self.serverName($0.name),
                       reason: "No session has started with this MCP server yet, so its tools are not known.")
        } + (startedByCLI ? [Self.cli] : [])
    }

    private static func serverName(_ server: String) -> String { "mcp:\(server)" }

    /// The measured sections' sum — nothing reported or unmeasured is in it.
    package var total: Int { sections.reduce(0) { $0 + $1.bytes } }

    package var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        return ["bytes": total,
                "sections": sections.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] },
                "reported": reported.map {
                    ["name": $0.name, "state": $0.state, "tools": $0.tools,
                     "reportedAt": iso.string(from: $0.reportedAt)] as [String: Any]
                },
                "unmeasured": unmeasured.map { ["name": $0.name, "reason": $0.reason] }]
    }
}
