import Foundation
import KiteloopCore
import os.log

private let debateLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "debate")

struct DebateContract: Codable, Sendable {
    let topic: String
    let proposer: String
    let critic: String
    let maxRounds: Int
    let artifactFields: [String]
    let groundingCommand: String?

    init(topic: String, proposer: String, critic: String, maxRounds: Int = 3, artifactFields: [String] = [], groundingCommand: String? = nil) {
        self.topic = topic
        self.proposer = proposer
        self.critic = critic
        self.maxRounds = maxRounds
        self.artifactFields = artifactFields
        self.groundingCommand = groundingCommand
    }

    /// Valid round count. `maxRounds` is agent-supplied and unchecked at
    /// construction (including `Codable` decoding), so anything that loops
    /// over the round count must read this instead of the raw field.
    static let roundRange = 1...20

    var clampedMaxRounds: Int {
        min(max(maxRounds, Self.roundRange.lowerBound), Self.roundRange.upperBound)
    }
}

struct DebateResult: Sendable {
    let finalArtifact: String
    let rounds: Int
    let terminated: TerminationReason

    enum TerminationReason: String, Sendable {
        case criticApproved
        case roundLimit
        case error
    }
}

@MainActor
class DebateOrchestrator {
    private let orchestrator: Orchestrator
    private let projectURL: URL
    private let toolHandler: (@Sendable (String, String, String) async -> String?)?

    init(orchestrator: Orchestrator, projectURL: URL,
         toolHandler: (@Sendable (String, String, String) async -> String?)? = nil) {
        self.orchestrator = orchestrator
        self.projectURL = projectURL
        self.toolHandler = toolHandler
    }

    func run(contract: DebateContract) async -> DebateResult {
        let proposerAgent = orchestrator.agents.first { $0.name.lowercased() == contract.proposer.lowercased() }
        let criticAgent = orchestrator.agents.first { $0.name.lowercased() == contract.critic.lowercased() }

        guard let proposerID = proposerAgent?.id else {
            debateLog.error("Proposer agent '\(contract.proposer, privacy: .public)' not found")
            return DebateResult(finalArtifact: "Error: proposer agent not found", rounds: 0, terminated: .error)
        }
        guard let criticID = criticAgent?.id else {
            debateLog.error("Critic agent '\(contract.critic, privacy: .public)' not found")
            return DebateResult(finalArtifact: "Error: critic agent not found", rounds: 0, terminated: .error)
        }

        let fieldsInstruction = contract.artifactFields.isEmpty
            ? ""
            : " Your response MUST be valid JSON with these fields: \(contract.artifactFields.joined(separator: ", "))."

        var lastProposal = ""
        var lastCritique = ""

        let maxRounds = contract.clampedMaxRounds
        for round in 1...maxRounds {
            debateLog.info("Debate round \(round)/\(maxRounds)")

            // Proposer turn
            let proposerPrompt: String
            if round == 1 {
                proposerPrompt = """
                You are the PROPOSER in a structured debate. Create a proposal for the following topic:

                \(contract.topic)

                Respond with a structured JSON artifact.\(fieldsInstruction)
                """
            } else {
                proposerPrompt = """
                You are the PROPOSER in round \(round) of a structured debate. The critic provided this feedback on your previous proposal:

                \(lastCritique)

                Revise your proposal to address the critique. Respond with an updated JSON artifact.\(fieldsInstruction)
                """
            }

            lastProposal = await sendAndCollect(message: proposerPrompt, to: proposerID)

            // Grounding step
            var groundingContext = ""
            if let cmd = contract.groundingCommand, !cmd.isEmpty {
                groundingContext = await Self.runGroundingCommand(cmd)
            }

            // Critic turn
            let criticPrompt = """
            You are the CRITIC in round \(round) of a structured debate. Review this proposal:

            \(lastProposal)
            \(groundingContext.isEmpty ? "" : "\nGrounding data:\n\(groundingContext)\n")

            Respond with JSON containing:
            - "verdict": "approve" or "revise"
            - "issues": array of specific problems found (empty if approving)
            - "suggestions": array of improvement suggestions
            """

            lastCritique = await sendAndCollect(message: criticPrompt, to: criticID)

            if lastCritique.lowercased().contains("\"approve\"") {
                debateLog.info("Debate concluded: critic approved in round \(round)")
                return DebateResult(finalArtifact: lastProposal, rounds: round, terminated: .criticApproved)
            }
        }

        debateLog.info("Debate concluded: round limit reached")
        return DebateResult(finalArtifact: lastProposal, rounds: maxRounds, terminated: .roundLimit)
    }

    private func sendAndCollect(message: String, to agentID: String) async -> String {
        let stream = orchestrator.send(message, to: agentID)
        return await Self.collectAgentResponse(
            stream: stream,
            orchestrator: orchestrator,
            agentID: agentID,
            toolHandler: toolHandler
        )
    }

    private static nonisolated func collectAgentResponse(
        stream: AsyncStream<StreamEvent>,
        orchestrator: Orchestrator,
        agentID: String,
        toolHandler: (@Sendable (String, String, String) async -> String?)?
    ) async -> String {
        var collected = ""
        for await event in stream {
            switch event {
            // A subagent's prose is not the agent's response.
            case .assistantText(let chunk, parentToolUseID: nil):
                collected += chunk
            case .result(let payload):
                if collected.isEmpty { collected = payload.text }
            case .mcpToolCall(let call):
                let result: String
                if let handler = toolHandler {
                    result = await handler(call.toolName, call.input, agentID) ?? "Error: unhandled tool"
                } else {
                    result = "Error: tools not available during structured debate"
                }
                await orchestrator.respondToMCPToolCall(requestID: call.requestID, result: result, agentID: agentID)
            default:
                break
            }
        }
        await orchestrator.markTurnDone(agentID: agentID)
        return collected
    }

    /// How long a grounding command gets before it is killed.
    ///
    /// The command is agent-supplied — `ChatViewModel` reads `grounding_command`
    /// straight out of a tool call's JSON — so one that tails a file, waits on a
    /// network or stops to read stdin is a command the debate can be handed, and
    /// an unbounded wait for it hangs the round, the debate and the agent turn
    /// behind them. Generous enough for a grounding command that really does
    /// work (a test run, a git log over a large history); short enough that a
    /// hung one costs a round rather than the session.
    static nonisolated let groundingCommandTimeout: TimeInterval = 120

    /// How much of a grounding command's output reaches the critic prompt.
    static nonisolated let groundingOutputLimit = 4000

    /// Runs `command` through bash and returns what it printed, capped at
    /// `groundingOutputLimit` characters.
    ///
    /// On a deadline, and prompt-free: `SubprocessOutput.runWithDeadline` polls
    /// rather than blocking on a drain, gives the child the null device on stdin
    /// so a command that reads it gets EOF instead of sitting on the app's own
    /// stdin, and past the deadline kills the child *with its descendants* —
    /// which signalling it alone leaves running and reparented. The debate then
    /// carries on to the critic turn with text saying the command timed out,
    /// rather than waiting on it for ever.
    ///
    /// A command that could not be spawned at all comes back as a failed command
    /// with no output, per that runner's contract; there is nothing for the
    /// critic to ground against either way.
    ///
    /// `timeout` is a parameter so tests can drive this at a one-second ceiling.
    static nonisolated func runGroundingCommand(
        _ command: String,
        timeout: TimeInterval = groundingCommandTimeout
    ) async -> String {
        let result = await Task.detached(priority: .userInitiated) {
            SubprocessOutput.runWithDeadline(
                executable: "/bin/bash",
                arguments: ["-c", command],
                timeout: timeout
            )
        }.value

        let output = String(result.output.prefix(groundingOutputLimit))
        guard result.timedOut else { return output }
        // The notice leads rather than trails: the cap trims the tail, so a
        // command that printed its fill and *then* hung would otherwise hand the
        // critic output that never mentions the deadline. What it managed to
        // print still follows — a partial answer is usually the useful part.
        return "Grounding command timed out after \(Int(timeout))s.\n\(output)"
    }
}
