import Foundation

/// The QA flow, added around a run's ordinary graph for a `flow:qa` item:
///
///     specify → worker → clean → harden → reviewer → qa → done
///
/// The specifier writes Given/When/Then acceptance scenarios and a QA
/// procedure before any code; the worker builds the feature and the flow that
/// exercises it; the project's clean and harden commands run on the result;
/// the reviewer reads the diff as it always does; and a QA agent runs the flow,
/// opens every screenshot it left and judges each step as the person using the
/// app would. Any stage that fails sends the work back to the worker with what
/// failed.
///
/// It extends the graph rather than replacing it: the `worker` and `reviewer`
/// nodes, their prompts, turn budgets and edges between themselves are the
/// autopilot's own, so everything the run machinery assumes about them —
/// empty-diff refusal on the worker's handoff, the reviewer's verdict — still
/// holds. A graph with no reviewer works the same way: whatever reached `done`
/// reaches QA first.
package enum QAFlowStages {
    package static let specifyNodeID = "specify"
    package static let cleanNodeID = "clean"
    package static let hardenNodeID = "harden"
    package static let qaNodeID = "qa"
    static let workerNodeID = "worker"
    static let doneNodeID = "done"
    static let blockedNodeID = "blocked"
    /// QA's verdict, under a key no other stage writes. An edge condition falls
    /// back to the run's state when the answer lacks its key, and the clean and
    /// harden stages leave `result: pass` there — so a QA answer that came back
    /// without a verdict read as a pass and reached `done`.
    package static let verdictKey = "qa_result"

    /// How long and how many turns each added stage gets.
    package struct Budget: Equatable, Sendable {
        package var specifyTurns = 15
        package var qaTurns = 40
        /// The specifier reads; the clean stage runs the project's gates.
        package var specifySeconds = 900
        package var cleanSeconds = 900
        /// Mutation testing and bringing the app up are the slow ones.
        package var hardenSeconds = 2700
        package var qaSeconds = 2700
        package init() {}
    }

    /// `graph` with the QA flow added for `itemID`, its stages run by `agentID`
    /// and driven by `profile`.
    package static func apply(to graph: WorkflowGraph, profile: QAProfile, itemID: String,
                              agentID: String, budget: Budget = Budget()) -> WorkflowGraph {
        var nodes = graph.nodes
        if let worker = nodes[workerNodeID] {
            nodes[workerNodeID] = withPrompt(worker, worker.prompt + workerSection(profile: profile, itemID: itemID))
        }
        nodes[specifyNodeID] = specifyNode(agentID: agentID, budget: budget)
        let checks = checkNodes(profile: profile, budget: budget)
        for node in checks { nodes[node.id] = node }
        nodes[qaNodeID] = qaNode(profile: profile, itemID: itemID, agentID: agentID, budget: budget)

        return WorkflowGraph(
            id: graph.id, name: graph.name, version: graph.version,
            nodes: nodes,
            edges: edges(from: graph.edges, checks: checks.map(\.id),
                         blocked: graph.terminalNodes.contains(blockedNodeID) ? blockedNodeID : nil),
            entryNode: specifyNodeID,
            terminalNodes: graph.terminalNodes,
            metadata: graph.metadata,
            globalTimeout: graph.globalTimeout,
            maxIterations: graph.maxIterations
        )
    }

    /// The note a finished QA run leaves on its item: whether QA passed, where
    /// the storyboard is, and the report step by step. Nil when QA never ran;
    /// when it ran and its answer carried no report, the note says so. A
    /// storyboard that was not `found` is named as reported and said missing.
    package static func note(report: String?, storyboard: String?, passed: Bool, reachedQA: Bool = false,
                             found: Bool = true) -> String? {
        guard let report = report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty else {
            return reachedQA ? "QA gave no verdict — its answer carried no `\(verdictKey)` or report, so the run stopped rather than pass unjudged work" : nil
        }
        let board = storyboard.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let named = board.map { found ? $0 : "\($0) (not found — nothing was kept)" } ?? "none"
        return "QA \(passed ? "passed" : "did not pass") — storyboard: \(named)\n\n\(report)"
    }

    // MARK: - Edges

    /// The ordinary graph's edges, rewired: the specifier leads into the
    /// worker; the worker's handoff runs through the checks before reaching
    /// what it reached before; and whatever reached `done` reaches QA instead.
    static func edges(from original: [WorkflowEdge], checks: [String], blocked: String? = nil) -> [WorkflowEdge] {
        var edges = [WorkflowEdge(from: specifyNodeID, to: workerNodeID, condition: .always)]
        for edge in original where edge.from != workerNodeID {
            edges.append(edge.to == doneNodeID ? retargeted(edge, to: qaNodeID) : edge)
        }
        edges += handoffs(original.filter { $0.from == workerNodeID }, through: checks)
        edges.append(WorkflowEdge(from: qaNodeID, to: doneNodeID, condition: qaPass))
        edges.append(WorkflowEdge(from: qaNodeID, to: workerNodeID, condition: qaFail, priority: 1))
        // No verdict is neither: the run stops where a person will look.
        if let blocked { edges.append(WorkflowEdge(from: qaNodeID, to: blocked, condition: .always, priority: 10)) }
        return edges
    }

    /// The worker's handoffs, routed through `checks` in order — each passing
    /// on to the next and failing back to the worker — before reaching what
    /// they reached before, with `done` read as QA.
    private static func handoffs(_ workerHandoffs: [WorkflowEdge], through checks: [String]) -> [WorkflowEdge] {
        guard let first = checks.first, let last = checks.last else {
            return workerHandoffs.map { $0.to == doneNodeID ? retargeted($0, to: qaNodeID) : $0 }
        }
        var edges = [WorkflowEdge(from: workerNodeID, to: first, condition: .always)]
        for (check, next) in zip(checks, checks.dropFirst()) {
            edges += passOrBack(check, next: next)
        }
        for handoff in workerHandoffs {
            let to = handoff.to == doneNodeID ? qaNodeID : handoff.to
            edges.append(WorkflowEdge(from: last, to: to, condition: pass, priority: handoff.priority))
        }
        edges.append(WorkflowEdge(from: last, to: workerNodeID, condition: fail, priority: 1))
        return edges
    }

    private static let pass = EdgeCondition.outputMatch(key: "result", value: "pass")
    private static let fail = EdgeCondition.outputMatch(key: "result", value: "fail")
    private static let qaPass = EdgeCondition.outputMatch(key: verdictKey, value: "pass")
    private static let qaFail = EdgeCondition.outputMatch(key: verdictKey, value: "fail")

    private static func passOrBack(_ check: String, next: String) -> [WorkflowEdge] {
        [WorkflowEdge(from: check, to: next, condition: pass),
         WorkflowEdge(from: check, to: workerNodeID, condition: fail, priority: 1)]
    }

    private static func retargeted(_ edge: WorkflowEdge, to: String) -> WorkflowEdge {
        WorkflowEdge(from: edge.from, to: to, condition: edge.condition,
                     priority: edge.priority, carryForwardSource: edge.carryForwardSource)
    }

    // MARK: - Nodes

    private static func specifyNode(agentID: String, budget: Budget) -> WorkflowNode {
        WorkflowNode(
            id: specifyNodeID,
            agentID: agentID,
            prompt: specifyPrompt(),
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Glob", "Grep"], denied: ["Edit", "Write", "Bash"]),
            maxTurns: budget.specifyTurns,
            timeoutSeconds: budget.specifySeconds,
            outputSchema: OutputSchema(fields: [
                "acceptance": OutputSchema.SchemaField(type: "string", required: true,
                                    description: "Given/When/Then scenarios the feature must satisfy"),
                "qa_procedure": OutputSchema.SchemaField(type: "string", required: true,
                                      description: "Numbered steps a person takes at the UI, each with what they should see"),
            ])
        )
    }

    /// The clean and harden stages the profile names, in that order.
    private static func checkNodes(profile: QAProfile, budget: Budget) -> [WorkflowNode] {
        var nodes: [WorkflowNode] = []
        if let clean = nonBlank(profile.clean) {
            nodes.append(shellNode(id: cleanNodeID, command: clean, timeout: budget.cleanSeconds))
        }
        if let harden = nonBlank(profile.harden) {
            nodes.append(shellNode(id: hardenNodeID, command: harden, timeout: budget.hardenSeconds))
        }
        return nodes
    }

    private static func shellNode(id: String, command: String, timeout: Int) -> WorkflowNode {
        WorkflowNode(
            id: id,
            prompt: "",
            timeoutSeconds: timeout,
            outputSchema: OutputSchema(fields: [
                "result": OutputSchema.SchemaField(type: "string", required: true, description: "pass or fail"),
                "test_output": OutputSchema.SchemaField(type: "string", required: true, description: "The command's output on failure"),
                "exit_code": OutputSchema.SchemaField(type: "string", required: false, description: "Exit code"),
            ]),
            shellCommand: command
        )
    }

    private static func qaNode(profile: QAProfile, itemID: String, agentID: String, budget: Budget) -> WorkflowNode {
        WorkflowNode(
            id: qaNodeID,
            agentID: agentID,
            prompt: qaPrompt(profile: profile, itemID: itemID),
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Bash", "Glob", "Grep"], denied: ["Edit", "Write"]),
            maxTurns: budget.qaTurns,
            timeoutSeconds: budget.qaSeconds,
            outputSchema: OutputSchema(fields: [
                verdictKey: OutputSchema.SchemaField(type: "string", required: true, description: "pass or fail"),
                "qa_report": OutputSchema.SchemaField(type: "string", required: true,
                                   description: "Each QA step: what it should show, what the screenshot shows, pass or fail"),
                "storyboard": OutputSchema.SchemaField(type: "string", required: false, description: "The storyboard the run left"),
            ])
        )
    }

    /// `node` as it is, with `prompt` in place of its own.
    private static func withPrompt(_ node: WorkflowNode, _ prompt: String) -> WorkflowNode {
        WorkflowNode(
            id: node.id, agentID: node.agentID, subGraphID: node.subGraphID, prompt: prompt,
            toolScopeOverride: node.toolScopeOverride, maxTurns: node.maxTurns,
            timeoutSeconds: node.timeoutSeconds, outputSchema: node.outputSchema,
            preloadKnowledge: node.preloadKnowledge, allowFreeform: node.allowFreeform,
            fileScope: node.fileScope, shellCommand: node.shellCommand, timeoutFallback: node.timeoutFallback
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Prompts

    static func specifyPrompt() -> String {
        """
    You are the specifier for a UI feature. Before anyone writes code, turn this item into two things a coder and a QA person can be held to. Read the code as needed; change nothing.

    Working on: {{state.title}}

    {{#if state.what}}## What
    {{state.what}}{{/if}}

    ## Validation (acceptance criteria)
    {{state.acceptanceCriteria}}

    ## Write
    1. acceptance — Given/When/Then scenarios the feature must satisfy: concrete values, what the person sees, the edge cases.
    2. qa_procedure — numbered steps a person takes in the app to prove it works. Each step says what to do and what the screen must show afterwards, so someone who has never seen the code can look at a screenshot of that moment and say pass or fail.

    ## Answer
    End with one JSON object, and nothing after it — the worker and QA are handed only what it holds, so prose around it reaches neither:
    ```json
    {"acceptance": "Given … When … Then …\\n…", "qa_procedure": "1. … — the screen shows …\\n2. …"}
    ```
    """
    }

    static func workerSection(profile: QAProfile, itemID: String) -> String {
        """


        ## QA flow
        This item runs through QA after you: a QA agent will run the flow you write and judge its screenshots against the procedure below, as the person using the app would.

        ### Acceptance (from the specifier)
        {{state.acceptance}}

        ### QA procedure
        {{state.qa_procedure}}

        Write the flow that walks through that procedure at `\(profile.specPath(itemID: itemID))`, taking one screenshot per step, so its storyboard lands at `\(profile.storyboardPath(itemID: itemID))`. It runs with `\(profile.runCommand(itemID: itemID))`.\(profile.guide.map { "\n\n\($0)" } ?? "")

        {{#if state.test_output}}### The last check failed — fix this first
        ```
        {{state.test_output}}
        ```{{/if}}
        {{#if state.qa_report}}### QA failed the last attempt
        {{state.qa_report}}{{/if}}
        """
    }

    static func qaPrompt(profile: QAProfile, itemID: String) -> String {
        """
        You are QA for a UI feature: a person proving it works by using the app. You do not fix anything; you report what you saw.

        Working on: {{state.title}}

        ## QA procedure
        {{state.qa_procedure}}

        ## Do this
        1. From the repository root run `\(profile.runCommand(itemID: itemID))`. It brings the app up from this tree and runs the item's flow, leaving a storyboard at `\(profile.storyboardPath(itemID: itemID))` — one screenshot per step.
        2. The command's exit status is part of the verdict: if it exits non-zero, \(verdictKey) is fail whatever the screenshots show — the flow asserted something the app did not do. Put its error lines in qa_report. The storyboard then ends at the step that failed, marked FAILED.
        3. Open the storyboard and every screenshot in it with Read. For each step of the procedure, find its screenshot and judge it as a person would: is what the step promises on screen — the text, the numbers, the state, nothing broken, nothing overlapping, no error where there should be none?
        4. A step of the procedure with no screenshot, or a screenshot that does not show what the step promises, fails — count the procedure's steps, not the storyboard's.

        ## Answer
        End with one JSON object, and nothing after it — the run reads only that:
        ```json
        {"\(verdictKey)": "pass", "qa_report": "1. … — pass\\n2. … — pass", "storyboard": "\(profile.storyboardPath(itemID: itemID))"}
        ```
        \(verdictKey) — "pass" only when every step passes, else "fail".
        qa_report — one line per step: what it should show, what the screenshot shows, pass or fail.
        storyboard — the storyboard's path.
        """
    }
}
