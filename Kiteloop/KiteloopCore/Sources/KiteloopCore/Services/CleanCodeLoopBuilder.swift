import Foundation

/// Compiles a clean-code loop contract into a `WorkflowGraph` — the pipeline
/// Robert C. Martin runs over agent-written code, as a workflow the app runs:
///
///     specify → implement → verify → clean → harden → review → qa → (gate) → done
///
/// Each stage is a node the shared engine drives; the deterministic stages are
/// shell nodes, the judgement stages are agents, and every failure loops back
/// to the coder with the tool's own output as its brief. Compared with the
/// improvement loop (`ImprovementLoopBuilder`) this adds the three stages that
/// make the difference between "tests pass" and "the code is clean": a
/// specifier that turns the request into acceptance scenarios and a QA
/// procedure before any code is written, a cleaner that fails on complexity
/// the tests do not pay for, and a hardener that fails on a mutation the
/// tests let through. What each of those runs is the contract's — this
/// repository's `check-complexity.sh`, `check-crap.py` and `mutate.py`,
/// but any command that exits non-zero when the code is not clean will do,
/// and a contract without a `hardenCommand` skips that stage.
package enum CleanCodeLoopBuilder {

    package struct Contract: Codable {
        package let name: String
        package let description: String
        package let goal: String
        package let scope: [String]
        package let frozenInterfaces: [String]
        /// Must pass before anything else is judged: the build, the tests.
        package let testCommand: String
        /// Fails when the code is not clean — complexity, layering, CRAP.
        package let cleanCommand: String
        /// Fails when a mutation survives; empty means no hardener stage.
        package let hardenCommand: String
        package let agents: AgentRoles
        package let limits: LoopLimits

        package struct AgentRoles: Codable {
            /// Writes the acceptance scenarios and the QA procedure.
            package let specifier: String
            package let implementer: String
            package let reviewer: String
            /// Runs the QA procedure at the end.
            package let qa: String
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(specifier: String, implementer: String, reviewer: String, qa: String) {
                self.specifier = specifier
                self.implementer = implementer
                self.reviewer = reviewer
                self.qa = qa
            }
        }

        package struct LoopLimits: Codable {
            package let maxIterations: Int
            package let timeoutMinutes: Int
            package let requireHumanApproval: Bool
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(maxIterations: Int, timeoutMinutes: Int, requireHumanApproval: Bool) {
                self.maxIterations = maxIterations
                self.timeoutMinutes = timeoutMinutes
                self.requireHumanApproval = requireHumanApproval
            }
        }

        package var hasHardener: Bool {
            !hardenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(name: String, description: String, goal: String, scope: [String], frozenInterfaces: [String], testCommand: String, cleanCommand: String, hardenCommand: String, agents: AgentRoles, limits: LoopLimits) {
            self.name = name
            self.description = description
            self.goal = goal
            self.scope = scope
            self.frozenInterfaces = frozenInterfaces
            self.testCommand = testCommand
            self.cleanCommand = cleanCommand
            self.hardenCommand = hardenCommand
            self.agents = agents
            self.limits = limits
        }
    }

    package static let tag = "clean-code-loop"

    package static func build(from contract: Contract) -> WorkflowGraph {
        WorkflowGraph(
            id: "clean-\(UUID().uuidString.prefix(8))",
            name: contract.name,
            version: 1,
            nodes: nodes(for: contract),
            edges: edges(for: contract),
            entryNode: "specify",
            terminalNodes: ["done"],
            metadata: WorkflowGraph.GraphMetadata(
                description: contract.description,
                author: nil,
                createdAt: Date(),
                tags: [tag]
            ),
            globalTimeout: contract.limits.timeoutMinutes * 60,
            maxIterations: contract.limits.maxIterations
        )
    }

    // MARK: - Nodes

    private static func nodes(for contract: Contract) -> [WorkflowGraph.NodeID: WorkflowNode] {
        var nodes: [WorkflowGraph.NodeID: WorkflowNode] = [:]
        let readOnly = ToolScopeHint(allowed: ["Read", "Glob", "Grep"], denied: ["Edit", "Write", "Bash"])
        let coding = ToolScopeHint(allowed: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"])
        let fileScope = FileScope(allowedPaths: contract.scope, frozenPaths: contract.frozenInterfaces)

        nodes["specify"] = WorkflowNode(
            id: "specify",
            agentID: contract.agents.specifier,
            prompt: specifyPrompt(contract),
            toolScopeOverride: readOnly,
            maxTurns: 5,
            timeoutSeconds: 180,
            outputSchema: OutputSchema(fields: [
                "acceptance": .init(type: "string", required: true, description: "Given/When/Then scenarios the change must satisfy"),
                "qa_procedure": .init(type: "string", required: true, description: "Steps a person takes at the UI or CLI to prove it works"),
            ])
        )
        nodes["implement"] = WorkflowNode(
            id: "implement",
            agentID: contract.agents.implementer,
            prompt: implementPrompt(contract),
            toolScopeOverride: coding,
            maxTurns: 12,
            timeoutSeconds: 900,
            outputSchema: OutputSchema(fields: [
                "changes_summary": .init(type: "string", required: true, description: "What was changed"),
                "files_modified": .init(type: "string", required: false, description: "Files touched"),
            ]),
            fileScope: fileScope
        )
        nodes["verify"] = shellNode(id: "verify", command: contract.testCommand, timeout: 900)
        nodes["clean"] = shellNode(id: "clean", command: contract.cleanCommand, timeout: 600)
        nodes["tidy"] = WorkflowNode(
            id: "tidy",
            agentID: contract.agents.implementer,
            prompt: tidyPrompt(contract),
            toolScopeOverride: coding,
            maxTurns: 8,
            timeoutSeconds: 600,
            outputSchema: OutputSchema(fields: [
                "changes_summary": .init(type: "string", required: true, description: "What was cleaned up"),
            ]),
            fileScope: fileScope
        )
        if contract.hasHardener {
            nodes["harden"] = shellNode(id: "harden", command: contract.hardenCommand, timeout: 1800)
            nodes["kill-survivors"] = WorkflowNode(
                id: "kill-survivors",
                agentID: contract.agents.implementer,
                prompt: hardenPrompt(contract),
                toolScopeOverride: coding,
                maxTurns: 10,
                timeoutSeconds: 900,
                outputSchema: OutputSchema(fields: [
                    "changes_summary": .init(type: "string", required: true, description: "Which survivors got a test, which are equivalent and why"),
                ]),
                fileScope: fileScope
            )
        }
        nodes["review"] = WorkflowNode(
            id: "review",
            agentID: contract.agents.reviewer,
            prompt: reviewPrompt(contract),
            toolScopeOverride: readOnly,
            maxTurns: 5,
            timeoutSeconds: 300,
            outputSchema: OutputSchema(fields: [
                "result": .init(type: "string", required: true, description: "approve or reject"),
                "review_feedback": .init(type: "string", required: true, description: "What to change, or what was checked"),
            ])
        )
        nodes["qa"] = WorkflowNode(
            id: "qa",
            agentID: contract.agents.qa,
            prompt: qaPrompt(contract),
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Bash", "Glob", "Grep"], denied: ["Edit", "Write"]),
            maxTurns: 8,
            timeoutSeconds: 600,
            outputSchema: OutputSchema(fields: [
                "result": .init(type: "string", required: true, description: "pass or fail"),
                "qa_report": .init(type: "string", required: true, description: "Each step of the procedure and what happened"),
            ])
        )
        if contract.limits.requireHumanApproval {
            nodes["human-gate"] = WorkflowNode(
                id: "human-gate",
                agentID: contract.agents.reviewer,
                prompt: "The change passed verify, clean, review and QA. Summary: {{state.changes_summary}}\nQA: {{state.qa_report}}\nA person decides now.",
                maxTurns: 1,
                timeoutSeconds: 60
            )
        }
        // Agentless terminal: the engine finalises it without a turn.
        nodes["done"] = WorkflowNode(id: "done", prompt: "")
        return nodes
    }

    // MARK: - Edges

    private static func edges(for contract: Contract) -> [WorkflowEdge] {
        var edges: [WorkflowEdge] = []
        edges.append(WorkflowEdge(from: "specify", to: "implement", condition: .always))
        edges.append(WorkflowEdge(from: "implement", to: "verify", condition: .always))
        edges.append(WorkflowEdge(from: "verify", to: "clean", condition: .outputMatch(key: "result", value: "pass")))
        edges.append(WorkflowEdge(from: "verify", to: "implement", condition: .outputMatch(key: "result", value: "fail"), priority: 1))
        let afterClean = contract.hasHardener ? "harden" : "review"
        edges.append(WorkflowEdge(from: "clean", to: afterClean, condition: .outputMatch(key: "result", value: "pass")))
        edges.append(WorkflowEdge(from: "clean", to: "tidy", condition: .outputMatch(key: "result", value: "fail"), priority: 1))
        edges.append(WorkflowEdge(from: "tidy", to: "verify", condition: .always))
        if contract.hasHardener {
            edges.append(WorkflowEdge(from: "harden", to: "review", condition: .outputMatch(key: "result", value: "pass")))
            edges.append(WorkflowEdge(from: "harden", to: "kill-survivors", condition: .outputMatch(key: "result", value: "fail"), priority: 1))
            edges.append(WorkflowEdge(from: "kill-survivors", to: "verify", condition: .always))
        }
        edges.append(WorkflowEdge(from: "review", to: "qa", condition: .outputMatch(key: "result", value: "approve")))
        edges.append(WorkflowEdge(from: "review", to: "implement", condition: .outputMatch(key: "result", value: "reject"), priority: 1))
        if contract.limits.requireHumanApproval {
            edges.append(WorkflowEdge(from: "qa", to: "human-gate", condition: .outputMatch(key: "result", value: "pass")))
            edges.append(WorkflowEdge(from: "human-gate", to: "done",
                                      condition: .humanApproval(question: "Accept these changes?", deniedEdge: "implement")))
        } else {
            edges.append(WorkflowEdge(from: "qa", to: "done", condition: .outputMatch(key: "result", value: "pass")))
        }
        edges.append(WorkflowEdge(from: "qa", to: "implement", condition: .outputMatch(key: "result", value: "fail"), priority: 1))
        return edges
    }

    private static func shellNode(id: String, command: String, timeout: Int) -> WorkflowNode {
        WorkflowNode(
            id: id,
            prompt: "",
            timeoutSeconds: timeout,
            outputSchema: OutputSchema(fields: [
                "result": .init(type: "string", required: true, description: "pass or fail"),
                "test_output": .init(type: "string", required: true, description: "The command's output on failure"),
                "exit_code": .init(type: "string", required: false, description: "Exit code"),
            ]),
            shellCommand: command
        )
    }

    // MARK: - Prompts

    private static func contractLines(_ contract: Contract) -> String {
        """
        - SCOPE: only files matching \(contract.scope.joined(separator: ", "))
        - FROZEN (do not modify): \(contract.frozenInterfaces.isEmpty ? "nothing" : contract.frozenInterfaces.joined(separator: ", "))
        - VERIFY: `\(contract.testCommand)` must pass
        - CLEAN: `\(contract.cleanCommand)` must pass\(contract.hasHardener ? "\n- HARDEN: `\(contract.hardenCommand)` must pass" : "")
        """
    }

    private static func specifyPrompt(_ contract: Contract) -> String {
        """
        You are the specifier. Turn this request into something a coder can be held to, without writing any code.

        ## Request
        {{state.goal}}

        ## Write two things
        1. acceptance — Given/When/Then scenarios the change must satisfy. Concrete values, observable outcomes, the edge cases.
        2. qa_procedure — the steps a person would take, at the UI or the command line, to prove the change works, written so someone who has never seen the code can follow them and say pass or fail at each step.

        Read the code as needed. Do not change it.
        """
    }

    private static func implementPrompt(_ contract: Contract) -> String {
        """
        You are the coder. Make the change and its tests; do not polish beyond what the tests ask.

        ## Request
        {{state.goal}}

        ## Acceptance
        {{state.acceptance}}

        ## Contract
        \(contractLines(contract))

        ## Context
        {{#if state.test_output}}The last VERIFY run FAILED:
        ```
        {{state.test_output}}
        ```
        Fix that first.{{/if}}
        {{#if state.review_feedback}}The reviewer sent this back:
        {{state.review_feedback}}
        Address it.{{/if}}
        {{#if state.qa_report}}QA ran the procedure and something failed:
        {{state.qa_report}}
        Make the procedure pass.{{/if}}

        Work within scope, add or update tests for every change in behaviour, then report what you changed.
        """
    }

    private static func tidyPrompt(_ contract: Contract) -> String {
        """
        You are the cleaner. The code works — VERIFY passed — but CLEAN did not:

        ```
        {{state.test_output}}
        ```

        Each line names a function and what is wrong with it: too many paths, paths no test exercises, a dependency across a layer, a test habit the suite was cleaned of. Fix what it names — split the function, cover the paths, invert the dependency — without changing behaviour, and without touching anything it does not name.

        ## Contract
        \(contractLines(contract))

        Report what you cleaned up.
        """
    }

    private static func hardenPrompt(_ contract: Contract) -> String {
        """
        You are the hardener. The tests pass and the code is clean, but mutation testing let these through:

        ```
        {{state.test_output}}
        ```

        Each survivor is a line where flipping an operator changed nothing any test could see — a path no test pins down. For each: read the source at that line, work out what the original operator guarantees, and write a test that fails under the flip and passes as written. Assert the behaviour (a boundary, an empty case, a negated condition), not the implementation. A survivor that cannot change observable behaviour is equivalent — say so, with the reason, instead of writing a vacuous test.

        ## Contract
        \(contractLines(contract))

        Report which survivors got a test and which are equivalent and why.
        """
    }

    private static func reviewPrompt(_ contract: Contract) -> String {
        """
        You are the reviewer. VERIFY and CLEAN have passed\(contract.hasHardener ? ", and HARDEN found no surviving mutant" : ""); judge what a tool cannot.

        ## Request
        {{state.goal}}

        ## Acceptance
        {{state.acceptance}}

        ## Changes
        Summary: {{state.changes_summary}}
        Files: {{state.files_modified}}

        ## Contract
        \(contractLines(contract))

        ## Judge
        1. Does the diff do what the request asks, and only that — nothing outside scope, nothing frozen touched, no default widened that the request did not ask to widen?
        2. Is every acceptance scenario actually met by the code — checked against the code, not the summary?
        3. Are the tests meaningful for the behaviour that changed, and absent where nothing did?
        4. Does it match the conventions around it?

        Approve only if all four hold. Otherwise reject with a specific reason the coder can act on.
        """
    }

    private static func qaPrompt(_ contract: Contract) -> String {
        """
        You are QA. Run the procedure the specifier wrote, step by step, against the system as it is now, and report what happened at each step. Use the command line where a step can be driven that way; say plainly where a step cannot be performed from here.

        ## Procedure
        {{state.qa_procedure}}

        ## Acceptance it is meant to prove
        {{state.acceptance}}

        Result is "pass" only if every step you could perform passed and no step that matters was skipped.
        """
    }
}
