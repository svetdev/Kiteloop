import Foundation

/// Compiles a high-level improvement loop contract into a WorkflowGraph.
/// The contract specifies: scope, frozen interfaces, test command, goal, agents, limits.
/// The builder generates the standard implement → test → review → done graph with back-edges.
package enum ImprovementLoopBuilder {

    package struct Contract: Codable {
        package let name: String
        package let description: String
        package let contract: ContractScope
        package let goal: String
        package let agents: AgentRoles
        package let limits: LoopLimits

        package struct ContractScope: Codable {
            package let scope: [String]
            package let frozenInterfaces: [String]
            package let testCommand: String

            package enum CodingKeys: String, CodingKey {
                case scope
                case frozenInterfaces = "frozen_interfaces"
                case testCommand = "test_command"
            }
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(scope: [String], frozenInterfaces: [String], testCommand: String) {
                self.scope = scope
                self.frozenInterfaces = frozenInterfaces
                self.testCommand = testCommand
            }
        }

        package struct AgentRoles: Codable {
            package let implementer: String
            package let reviewer: String
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(implementer: String, reviewer: String) {
                self.implementer = implementer
                self.reviewer = reviewer
            }
        }

        package struct LoopLimits: Codable {
            package let maxIterations: Int
            package let timeoutMinutes: Int
            package let requireHumanApproval: Bool

            package enum CodingKeys: String, CodingKey {
                case maxIterations = "max_iterations"
                case timeoutMinutes = "timeout_minutes"
                case requireHumanApproval = "require_human_approval"
            }
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(maxIterations: Int, timeoutMinutes: Int, requireHumanApproval: Bool) {
                self.maxIterations = maxIterations
                self.timeoutMinutes = timeoutMinutes
                self.requireHumanApproval = requireHumanApproval
            }
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(name: String, description: String, contract: ContractScope, goal: String, agents: AgentRoles, limits: LoopLimits) {
            self.name = name
            self.description = description
            self.contract = contract
            self.goal = goal
            self.agents = agents
            self.limits = limits
        }
    }

    package static func build(from contract: Contract) -> WorkflowGraph {
        let implementNode = WorkflowNode(
            id: "implement",
            agentID: contract.agents.implementer,
            prompt: buildImplementPrompt(contract: contract),
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"]),
            maxTurns: 10,
            timeoutSeconds: 300,
            outputSchema: OutputSchema(fields: [
                "changes_summary": .init(type: "string", required: true, description: "What was changed"),
                "files_modified": .init(type: "string", required: false, description: "Files touched"),
            ]),
            fileScope: FileScope(
                allowedPaths: contract.contract.scope,
                frozenPaths: contract.contract.frozenInterfaces
            )
        )

        let testNode = WorkflowNode(
            id: "test",
            prompt: "",
            timeoutSeconds: 120,
            outputSchema: OutputSchema(fields: [
                "result": .init(type: "string", required: true, description: "pass or fail"),
                "test_output": .init(type: "string", required: true, description: "Failure output"),
                "exit_code": .init(type: "string", required: false, description: "Exit code"),
            ]),
            shellCommand: contract.contract.testCommand
        )

        let reviewNode = WorkflowNode(
            id: "review",
            agentID: contract.agents.reviewer,
            prompt: buildReviewPrompt(contract: contract),
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Glob", "Grep"], denied: ["Edit", "Write", "Bash"]),
            maxTurns: 5,
            timeoutSeconds: 180,
            outputSchema: OutputSchema(fields: [
                "result": .init(type: "string", required: true, description: "approve or reject"),
                "review_feedback": .init(type: "string", required: true, description: "Review comments"),
            ])
        )

        let doneNode = WorkflowNode(
            id: "done",
            agentID: contract.agents.reviewer,
            prompt: "Improvement loop complete. Summarize: goal={{state.goal}}, changes={{state.changes_summary}}, review={{state.review_feedback}}",
            maxTurns: 1,
            timeoutSeconds: 30
        )

        var nodes: [WorkflowGraph.NodeID: WorkflowNode] = [:]
        nodes["implement"] = implementNode
        nodes["test"] = testNode
        nodes["review"] = reviewNode
        nodes["done"] = doneNode

        var edges: [WorkflowEdge] = [
            // implement → test (always)
            WorkflowEdge(from: "implement", to: "test", condition: .always),
            // test → review (pass)
            WorkflowEdge(from: "test", to: "review", condition: .outputMatch(key: "result", value: "pass")),
            // test → implement (fail — loop back)
            WorkflowEdge(from: "test", to: "implement", condition: .outputMatch(key: "result", value: "fail"), priority: 1),
            // review → done (approve)
            WorkflowEdge(from: "review", to: "done", condition: .outputMatch(key: "result", value: "approve")),
            // review → implement (reject — loop back)
            WorkflowEdge(from: "review", to: "implement", condition: .outputMatch(key: "result", value: "reject"), priority: 1),
        ]

        // Optional human gate before final acceptance
        if contract.limits.requireHumanApproval {
            let approvalNode = WorkflowNode(
                id: "human-gate",
                agentID: contract.agents.reviewer,
                prompt: "Changes are ready for human review. Summary: {{state.changes_summary}}",
                maxTurns: 1
            )
            nodes["human-gate"] = approvalNode

            // Replace review→done with review→human-gate→done
            edges.removeAll { $0.from == "review" && $0.to == "done" }
            edges.append(WorkflowEdge(
                from: "review",
                to: "human-gate",
                condition: .outputMatch(key: "result", value: "approve")
            ))
            edges.append(WorkflowEdge(
                from: "human-gate",
                to: "done",
                condition: .humanApproval(question: "Accept these changes?", deniedEdge: "implement")
            ))
        }

        return WorkflowGraph(
            id: "loop-\(UUID().uuidString.prefix(8))",
            name: contract.name,
            version: 1,
            nodes: nodes,
            edges: edges,
            entryNode: "implement",
            terminalNodes: ["done"],
            metadata: WorkflowGraph.GraphMetadata(
                description: contract.description,
                author: nil,
                createdAt: Date(),
                tags: ["improvement-loop"]
            ),
            globalTimeout: contract.limits.timeoutMinutes * 60,
            maxIterations: contract.limits.maxIterations
        )
    }

    // MARK: - Prompt Builders

    private static func buildImplementPrompt(contract: Contract) -> String {
        """
        You are improving code within a frozen contract.

        ## Goal
        {{state.goal}}

        ## Contract
        - SCOPE: Only modify files matching: \(contract.contract.scope.joined(separator: ", "))
        - FROZEN (do NOT modify): \(contract.contract.frozenInterfaces.joined(separator: ", "))
        - Tests must pass: `\(contract.contract.testCommand)`

        ## Context
        {{#if state.test_output}}Previous test run FAILED:
        ```
        {{state.test_output}}
        ```
        Fix the failing tests.{{/if}}
        {{#if state.review_feedback}}Reviewer feedback:
        {{state.review_feedback}}
        Address this feedback.{{/if}}

        Make your changes within scope, then report what you changed.
        """
    }

    private static func buildTestPrompt(contract: Contract) -> String {
        """
        Run the test suite and report results.

        Command: `\(contract.contract.testCommand)`

        Report structured output:
        - result: "pass" if ALL tests pass, "fail" if any fail
        - test_output: the failure messages (empty string if passing)
        - tests_run: count of tests executed
        """
    }

    private static func buildReviewPrompt(contract: Contract) -> String {
        """
        Review changes made to the codebase.

        ## Contract Constraints
        - Allowed scope: \(contract.contract.scope.joined(separator: ", "))
        - Frozen interfaces: \(contract.contract.frozenInterfaces.joined(separator: ", "))

        ## Changes
        Summary: {{state.changes_summary}}
        Files: {{state.files_modified}}
        Tests: PASSING

        ## Review Checklist
        1. Contract violation? (files outside scope, frozen interfaces changed)
        2. Quality improvement? (is this actually better than before?)
        3. Correctness risk? (could this break existing behavior?)

        Approve if all checks pass. Reject with specific feedback if not.
        """
    }
}
