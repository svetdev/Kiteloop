import Foundation
import KiteloopCore

/// Read-only source access, scoped to one named project — what the Planner is
/// granted when the backlog genuinely cannot answer the question.
///
/// `ProjectInspection` and `PortfolioSnapshot` answer from what the app already
/// holds, and they are the cheap default: a queue's depth, an item's status, what
/// a run cost. This is the expensive exception, for the questions none of that
/// can reach — "is that file still there", "does this symbol exist", "what does
/// this test actually assert". It costs a model call with tools, so it is asked
/// for by name and never taken.
///
/// Four properties are load-bearing, and each is a property of *this type* rather
/// than a rule a caller is trusted to follow:
///
/// * **The grant is the scope.** A `Grant` names one project and the root it
///   resolves to, and `HeadlessAgentRunner` roots the session at that root rather
///   than at whatever directory the caller happened to pass. A question about one
///   project cannot be answered out of another project's files because there is
///   no second root to read.
/// * **Nothing in it can write, run a command, or reach the network.**
///   `allowedTools` is three read verbs; `deniedTools` is *computed* as everything
///   else the CLI's base set offers, so a tool added to that set arrives here
///   denied rather than quietly granted. The Planner's acting path is the
///   control API and stays there — a read grant must not become a second one.
/// * **What comes back is bounded, and says when the bound cost something.** A
///   search across a repository can return thousands of lines; an answer cut
///   silently at a limit reads as a complete one, which is the worse failure.
///   `bound(_:)` caps and states the cap in the same breath.
/// * **Not having looked is an answer.** The contract keeps the refusal the
///   tool-less Planner already made correctly: asked about something it has not
///   read, it says so instead of reasoning from a summary as though it had.
enum RepoRead {

    // MARK: - Scope

    /// One project, read-only: the name it was asked about by and the root that
    /// name resolved to.
    ///
    /// Built from a resolved `ControlSessionRegistry.Entry` (see
    /// `CoordinatorQueueRefill.answerFromSource`), never from a caller's string —
    /// a path nobody resolved is a path nobody checked is open.
    struct Grant: Sendable, Equatable {
        /// The project as the operator knows it — its directory's own name.
        let projectName: String
        /// The canonical root. The only directory anything under this grant reads.
        let projectPath: String

        init(projectName: String, projectPath: String) {
            self.projectName = projectName
            self.projectPath = KiteloopProject.canonicalPath(projectPath)
        }

        var root: URL { URL(fileURLWithPath: projectPath) }
    }

    // MARK: - Tools

    /// The whole grant: find files, search them, read them. Three verbs, none of
    /// which changes anything.
    static let allowedTools = ["Glob", "Grep", "Read"]

    /// Tools that put something on disk.
    static let writingTools: Set<String> = [
        "Edit", "Write", "NotebookEdit", "TaskCreate", "TaskUpdate"
    ]

    /// Tools that run something — a shell command, a subagent, a workflow, a
    /// watched process. "No shell" is not only `Bash`: a tool that can start
    /// another agent can start one holding tools this grant refuses.
    static let executingTools: Set<String> = [
        "Bash", "Agent", "Workflow", "Monitor"
    ]

    /// Tools that leave the machine.
    static let networkTools: Set<String> = ["WebSearch", "WebFetch"]

    /// The three classes together — what the item's "no writes, no shell, no
    /// network" names, as a set something can be checked against.
    static var forbiddenTools: Set<String> {
        writingTools.union(executingTools).union(networkTools)
    }

    /// Everything the CLI would otherwise offer, refused by name.
    ///
    /// Computed from `ClaudeCodeCLIRuntime.baseCLITools` rather than listed, and
    /// that is the point: a tool added to the runtime's base set lands here
    /// denied on the next build. A hand-written list would have to be remembered,
    /// and the one time it wasn't the grant would silently widen.
    ///
    /// Belt as well as braces — `allowedTools` already *bounds* the scope, so
    /// this adds nothing the allow-list doesn't already withhold. It is here
    /// because `ToolScopeResolver` gives deny precedence over every layer, so a
    /// later layer that tried to add `Bash` back could not.
    static var deniedTools: [String] {
        ClaudeCodeCLIRuntime.baseCLITools.subtracting(allowedTools).sorted()
    }

    // MARK: - Bounds

    /// How much answer a read may return. Generous enough for a quoted function
    /// and the reasoning around it, small enough that a `Grep` the model pasted
    /// wholesale cannot become the reply.
    static let answerCharacterLimit = 4000

    /// An answer and whether the bound cost anything.
    struct Answer: Sendable, Equatable {
        /// The answer as far as it goes — already cut, if it was cut.
        let text: String
        /// True when `text` is not the whole of what came back.
        let wasCapped: Bool

        /// What a reader is shown: the answer, and — only when it was cut — the
        /// sentence saying so. A cap nobody is told about is indistinguishable
        /// from a complete answer, which is the whole reason this type exists
        /// rather than a bare `String`.
        var stated: String {
            wasCapped ? text + "\n\n" + RepoRead.capNotice : text
        }
    }

    /// The sentence a capped answer carries.
    static var capNotice: String {
        "(Capped: this answer was cut at \(answerCharacterLimit) characters. "
            + "Ask something narrower to see the rest.)"
    }

    /// Cap an answer without severing a word, and say whether it was capped.
    ///
    /// Within budget it comes back untouched and `wasCapped` is false — the
    /// notice is not appended to an answer that fits, because a reader would read
    /// it as a truncation that didn't happen. Over budget it is cut back to the
    /// last whitespace; a single unbroken token still gets the hard cut, since
    /// there is nowhere kinder to cut it.
    static func bound(_ text: String, limit: Int = answerCharacterLimit) -> Answer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(0, limit)
        guard trimmed.count > limit else { return Answer(text: trimmed, wasCapped: false) }
        let head = trimmed.prefix(limit)
        guard let lastSpace = head.lastIndex(where: { $0.isWhitespace }) else {
            return Answer(text: String(head), wasCapped: true)
        }
        let cut = head[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
        return Answer(text: cut.isEmpty ? String(head) : cut, wasCapped: true)
    }

    // MARK: - What the model is told

    /// How many matches a search may report, and how much of a file a read may
    /// take, before the model is asked to narrow instead. Stated in the contract
    /// rather than enforced from Swift — the tools are the CLI's — which is why
    /// `bound(_:)` above is the guarantee and this is the request.
    static let searchMatchLimit = 50
    static let fileLineLimit = 400

    /// The half of the system prompt this grant contributes: what it may read,
    /// what it may not do, how much to bring back, and the refusal it must keep
    /// making.
    ///
    /// Appended after the persona and the response contract, the way
    /// `CoordinatorQueueRefill.drafterContract` is — the persona says who is
    /// answering, this says what they are allowed to look at.
    static func contract(for grant: Grant) -> String {
        """
        ## Reading \(grant.projectName)'s source

        You have read-only access to **one** project — \(grant.projectName), at \
        `\(grant.projectPath)` — and to nothing else. Another project's files are \
        not yours to read, whatever the question turns out to touch; if answering \
        would need them, say so rather than reaching.

        You have exactly three tools: `Glob` to find files, `Grep` to search them, \
        `Read` to read them. You cannot write a file, run a command, or reach the \
        network, and you must not ask to — applying anything you conclude is the \
        operator's call, made through Kiteloop, not yours.

        Bring back little: cap a search at about \(searchMatchLimit) matches and a \
        read at about \(fileLineLimit) lines, and narrow the search rather than \
        pasting a long result. Quote only the lines that carry the answer, with \
        the path and line they came from so the operator can go and look.

        Reading costs money and the day has a ceiling, so read what the question \
        needs and stop.

        Say what you actually looked at. If you did not read something, say you \
        did not read it — do not answer from the backlog, from these instructions, \
        or from what a file of that name usually contains. "I haven't looked at \
        that" is a complete and useful answer; a confident guess is neither.
        """
    }

    /// The question, framed so the reply is an answer rather than a plan.
    static func prompt(question: String, grant: Grant) -> String {
        """
        A question about \(grant.projectName)'s source. Read what you need under \
        `\(grant.projectPath)` and answer it.

        \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    // MARK: - Outcome

    /// What came of asking. Cases rather than an optional, because each is told
    /// to the operator differently — and each maps to a different status on the
    /// control API.
    enum Outcome: Sendable, Equatable {
        /// The Planner read the project and answered.
        case answered(project: String, answer: Answer, costUSD: Double)
        /// The name resolved to no open project. Carries
        /// `ProjectInspection.Outcome`'s own refusal, which names the open ones.
        case unknownProject(String)
        /// The day's ceiling is spent. Reading is charged like grooming is, so
        /// an exhausted budget refuses a read the same way it holds a pass.
        case budgetExhausted(String)
        /// Nothing to read with — the Planner isn't wired into this window.
        case unavailable(String)
        /// The call happened and came back with nothing. Distinct from an
        /// answer: silence is not a finding, and reporting it as one would be
        /// exactly the invention this whole path is written to avoid.
        case noAnswer(String)

        /// The sentence to show, whichever case this is.
        var message: String {
            switch self {
            case .answered(_, let answer, _): return answer.stated
            case .unknownProject(let reason): return reason
            case .budgetExhausted(let reason): return reason
            case .unavailable(let reason): return reason
            case .noAnswer(let reason): return reason
            }
        }

        var answer: Answer? {
            guard case .answered(_, let answer, _) = self else { return nil }
            return answer
        }
    }
}
