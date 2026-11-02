import XCTest
@testable import KiteloopCore

final class WorkflowGraphTests: XCTestCase {
    func testToolScopeHintDecodeWithAllFields() throws {
        let json = """
        {"allowed": ["read_file", "write_file"], "denied": ["bash"]}
        """.data(using: .utf8)!
        let hint = try JSONDecoder().decode(ToolScopeHint.self, from: json)
        XCTAssertEqual(hint.allowed, ["read_file", "write_file"])
        XCTAssertEqual(hint.denied, ["bash"])
    }

    func testToolScopeHintDecodeNilAllowed() throws {
        let json = """
        {"denied": ["bash"]}
        """.data(using: .utf8)!
        let hint = try JSONDecoder().decode(ToolScopeHint.self, from: json)
        XCTAssertNil(hint.allowed)
        XCTAssertEqual(hint.denied, ["bash"])
    }

    func testToolScopeHintDecodeEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let hint = try JSONDecoder().decode(ToolScopeHint.self, from: json)
        XCTAssertNil(hint.allowed)
        XCTAssertEqual(hint.denied, [])
    }

    func testOutputSchemaRoundTrip() throws {
        let schema = OutputSchema(fields: [
            "status": OutputSchema.SchemaField(type: "string", required: true, description: "Result status"),
            "count": OutputSchema.SchemaField(type: "int", required: false, description: nil)
        ])
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(OutputSchema.self, from: data)
        XCTAssertEqual(decoded.fields.count, 2)
        XCTAssertEqual(decoded.fields["status"]?.type, "string")
        XCTAssertEqual(decoded.fields["status"]?.required, true)
        XCTAssertEqual(decoded.fields["count"]?.required, false)
    }

    func testWorkflowNodeDecodeMinimalJSON() throws {
        let json = """
        {"id": "research", "agentID": "researcher", "prompt": "Do research"}
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(WorkflowNode.self, from: json)
        XCTAssertEqual(node.id, "research")
        XCTAssertEqual(node.agentID, "researcher")
        XCTAssertNil(node.subGraphID)
        XCTAssertEqual(node.prompt, "Do research")
        XCTAssertNil(node.toolScopeOverride)
        XCTAssertNil(node.maxTurns)
        XCTAssertNil(node.timeoutSeconds)
        XCTAssertNil(node.outputSchema)
        XCTAssertNil(node.preloadKnowledge)
        XCTAssertEqual(node.allowFreeform, false)
    }

    func testWorkflowNodeDecodeFullJSON() throws {
        let json = """
        {
            "id": "impl",
            "agentID": "engineer",
            "prompt": "Implement the feature",
            "toolScopeOverride": {"allowed": ["bash", "write_file"], "denied": []},
            "maxTurns": 10,
            "timeoutSeconds": 300,
            "outputSchema": {"fields": {"result": {"type": "string", "required": true}}},
            "preloadKnowledge": ["api-docs.md"],
            "allowFreeform": true
        }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(WorkflowNode.self, from: json)
        XCTAssertEqual(node.id, "impl")
        XCTAssertEqual(node.agentID, "engineer")
        XCTAssertEqual(node.maxTurns, 10)
        XCTAssertEqual(node.timeoutSeconds, 300)
        XCTAssertNotNil(node.toolScopeOverride)
        XCTAssertEqual(node.toolScopeOverride?.allowed, ["bash", "write_file"])
        XCTAssertEqual(node.preloadKnowledge, ["api-docs.md"])
        XCTAssertEqual(node.allowFreeform, true)
    }

    func testWorkflowNodeWithSubGraphID() throws {
        let json = """
        {"id": "sub", "subGraphID": "review-flow", "prompt": "Run review"}
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(WorkflowNode.self, from: json)
        XCTAssertNil(node.agentID)
        XCTAssertEqual(node.subGraphID, "review-flow")
    }

    func testWorkflowGraphRoundTrip() throws {
        let graph = WorkflowGraph(
            id: "test-graph",
            name: "Test Workflow",
            version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "researcher", prompt: "Begin"),
                "end": WorkflowNode(id: "end", agentID: "writer", prompt: "Finish")
            ],
            edges: [
                WorkflowEdge(from: "start", to: "end", condition: .always)
            ],
            entryNode: "start",
            terminalNodes: ["end"],
            metadata: .empty,
            globalTimeout: 600
        )
        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: data)
        XCTAssertEqual(decoded.id, "test-graph")
        XCTAssertEqual(decoded.name, "Test Workflow")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.nodes.count, 2)
        XCTAssertEqual(decoded.edges.count, 1)
        XCTAssertEqual(decoded.entryNode, "start")
        XCTAssertEqual(decoded.terminalNodes, ["end"])
        XCTAssertEqual(decoded.globalTimeout, 600)
    }

    func testGraphMetadataDefaults() throws {
        let json = """
        {
            "id": "g1", "name": "G", "version": 1,
            "nodes": {"a": {"id": "a", "agentID": "x", "prompt": "p"}},
            "edges": [], "entryNode": "a", "terminalNodes": ["a"],
            "metadata": {"description": "A test graph"}
        }
        """.data(using: .utf8)!
        let graph = try JSONDecoder().decode(WorkflowGraph.self, from: json)
        XCTAssertEqual(graph.metadata.description, "A test graph")
        XCTAssertNil(graph.metadata.author)
        XCTAssertEqual(graph.metadata.tags, [])
    }

    // MARK: - Node lookup

    /// The engine resolves the node to run with `graph.nodes[id]` on every step,
    /// so the dictionary key must be the node's own `id`.
    func testNodeLookupByIDReturnsMatchingNode() {
        let graph = Self.branchingGraph()
        let node = graph.nodes["review"]
        XCTAssertEqual(node?.id, "review")
        XCTAssertEqual(node?.agentID, "reviewer")
        XCTAssertEqual(node?.prompt, "Review it")
    }

    func testNodeLookupUnknownIDReturnsNil() {
        let graph = Self.branchingGraph()
        XCTAssertNil(graph.nodes["nope"])
        XCTAssertNil(graph.nodes[""])
    }

    func testNodeLookupIsCaseSensitive() {
        let graph = Self.branchingGraph()
        XCTAssertNotNil(graph.nodes["review"])
        XCTAssertNil(graph.nodes["Review"])
    }

    func testEntryAndTerminalNodesResolveToNodes() {
        let graph = Self.branchingGraph()
        XCTAssertNotNil(graph.nodes[graph.entryNode])
        for terminal in graph.terminalNodes {
            XCTAssertNotNil(graph.nodes[terminal], "terminal '\(terminal)' has no node")
        }
        XCTAssertTrue(graph.terminalNodes.contains("done"))
        XCTAssertFalse(graph.terminalNodes.contains("build"))
    }

    /// `nodes` is `var` — the loader patches nodes in place after validation.
    func testNodeLookupReflectsMutation() {
        var graph = Self.branchingGraph()
        graph.nodes["build"] = WorkflowNode(id: "build", agentID: "other", prompt: "Rebuild it")
        XCTAssertEqual(graph.nodes["build"]?.agentID, "other")

        graph.nodes["review"] = nil
        XCTAssertNil(graph.nodes["review"])
        XCTAssertEqual(graph.nodes.count, 3)
    }

    func testNodeLookupSurvivesRoundTrip() throws {
        let graph = Self.branchingGraph()
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(Set(decoded.nodes.keys), Set(graph.nodes.keys))
        for (id, node) in decoded.nodes {
            XCTAssertEqual(node.id, id, "node keyed under '\(id)' reports id '\(node.id)'")
        }
    }

    // MARK: - Edge lookup

    func testOutgoingEdgeLookupBySourceNode() {
        let graph = Self.branchingGraph()
        let outgoing = graph.edges.filter { $0.from == "review" }
        XCTAssertEqual(outgoing.count, 3)
        XCTAssertEqual(Set(outgoing.map(\.to)), ["done", "build", "blocked"])
        XCTAssertTrue(graph.edges.filter { $0.from == "done" }.isEmpty)
    }

    func testIncomingEdgeLookupByTargetNode() {
        let graph = Self.branchingGraph()
        XCTAssertEqual(graph.edges.filter { $0.to == "review" }.map(\.from), ["build"])
        // The entry node is re-entered by the retry edge, not only by starting the run.
        XCTAssertEqual(graph.edges.filter { $0.to == graph.entryNode }.map(\.from), ["review"])
        XCTAssertTrue(graph.edges.filter { $0.to == "nope" }.isEmpty)
    }

    /// Edge selection walks candidates in ascending priority, so the lowest
    /// number wins and the `.always` fallback must sort last.
    func testOutgoingEdgesSortByPriorityLowestFirst() {
        let graph = Self.branchingGraph()
        let ordered = graph.edges
            .filter { $0.from == "review" }
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(ordered.map(\.to), ["done", "build", "blocked"])
        XCTAssertEqual(ordered.map(\.priority), [0, 1, 10])
        XCTAssertEqual(ordered.last?.condition, .always)
    }

    func testEveryEdgeEndpointResolvesToANode() {
        let graph = Self.branchingGraph()
        for edge in graph.edges {
            XCTAssertNotNil(graph.nodes[edge.from], "edge source '\(edge.from)' missing")
            XCTAssertNotNil(graph.nodes[edge.to], "edge target '\(edge.to)' missing")
        }
    }

    func testEdgeLookupSurvivesRoundTrip() throws {
        let graph = Self.branchingGraph()
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: JSONEncoder().encode(graph))
        let outgoing = decoded.edges
            .filter { $0.from == "review" }
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(outgoing.map(\.to), ["done", "build", "blocked"])
        XCTAssertEqual(outgoing.first?.condition, .outputMatch(key: "passed", value: "true"))
    }

    // MARK: - Fixture

    /// build → review, with review branching three ways at distinct priorities.
    private static func branchingGraph() -> WorkflowGraph {
        WorkflowGraph(
            id: "branching",
            name: "Branching",
            version: 1,
            nodes: [
                "build": WorkflowNode(id: "build", agentID: "engineer", prompt: "Build it"),
                "review": WorkflowNode(id: "review", agentID: "reviewer", prompt: "Review it"),
                "done": WorkflowNode(id: "done", agentID: "engineer", prompt: ""),
                "blocked": WorkflowNode(id: "blocked", agentID: "engineer", prompt: "")
            ],
            edges: [
                WorkflowEdge(from: "build", to: "review", condition: .always),
                WorkflowEdge(from: "review", to: "blocked", condition: .always, priority: 10),
                WorkflowEdge(from: "review", to: "build",
                             condition: .outputMatch(key: "passed", value: "false"), priority: 1),
                WorkflowEdge(from: "review", to: "done",
                             condition: .outputMatch(key: "passed", value: "true"), priority: 0)
            ],
            entryNode: "build",
            terminalNodes: ["done", "blocked"],
            metadata: .empty
        )
    }

    // MARK: - WorkflowNode defaults

    /// Freeform output is something a graph opts a node into; a node built
    /// without saying so is not freeform.
    func testWorkflowNodeInitDefaultsToNotFreeform() {
        let node = WorkflowNode(id: "n", agentID: "a", prompt: "p")
        XCTAssertFalse(node.allowFreeform)
    }

    // MARK: - FileScope

    func testFrozenPathIsRefusedEvenWhenAnAllowedPatternCoversIt() {
        let scope = FileScope(allowedPaths: ["Sources/**"], frozenPaths: ["Sources/Locked/**"])
        XCTAssertTrue(scope.isPathAllowed("Sources/Open/A.swift"))
        XCTAssertFalse(scope.isPathAllowed("Sources/Locked/A.swift"),
                       "a frozen path wins over the allowed pattern that also covers it")
    }

    func testSwiftGlobRequiresBothThePrefixAndTheSwiftSuffix() {
        let scope = FileScope(allowedPaths: ["Sources/**/*.swift"])
        XCTAssertTrue(scope.isPathAllowed("Sources/Deep/A.swift"))
        XCTAssertFalse(scope.isPathAllowed("Sources/README.md"), "under the prefix but not a .swift file")
        XCTAssertFalse(scope.isPathAllowed("Tests/A.swift"), "a .swift file outside the prefix")
    }

    func testSingleLevelGlobMatchesDirectChildrenOnly() {
        let scope = FileScope(allowedPaths: ["docs/*"])
        XCTAssertTrue(scope.isPathAllowed("docs/a.md"))
        XCTAssertFalse(scope.isPathAllowed("docs/sub/a.md"), "one level deeper is not a direct child")
        XCTAssertFalse(scope.isPathAllowed("README.md"),
                       "a path outside the directory does not match just because it has no slash after the prefix length")
    }

    func testLiteralPatternMatchesExactPathOrBasename() {
        let scope = FileScope(allowedPaths: ["Package.swift"])
        XCTAssertTrue(scope.isPathAllowed("Package.swift"))
        XCTAssertTrue(scope.isPathAllowed("Kiteloop/Package.swift"),
                      "a literal pattern also matches as the last component of a longer path")
        XCTAssertFalse(scope.isPathAllowed("Packages.swift"))
    }
}
