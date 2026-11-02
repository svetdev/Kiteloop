import XCTest
@testable import KiteloopCore

final class ToolScopeTests: XCTestCase {
    func testProfileToolScopeCodableRoundTrip() throws {
        let scope = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: ["Read"],
            policyVersion: "v1"
        )
        let data = try JSONEncoder().encode(scope)
        let decoded = try JSONDecoder().decode(ProfileToolScope.self, from: data)
        XCTAssertEqual(decoded, scope)
    }

    func testLayerToolScopeNilAllowedIsIdentity() throws {
        let layer = LayerToolScope(
            allowed: nil,
            denied: ["Bash"],
            policyVersion: "v1",
            source: .profile
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(LayerToolScope.self, from: data)
        XCTAssertEqual(decoded, layer)
    }

    func testLayerToolScopeEmptyAllowedBlocksAll() throws {
        let layer = LayerToolScope(
            allowed: [],
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "abc")
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(LayerToolScope.self, from: data)
        XCTAssertEqual(decoded.allowed, [])
        XCTAssertEqual(decoded, layer)
    }

    func testResolvedToolScopeCodableRoundTrip() throws {
        let resolved = ResolvedToolScope(
            effective: ["Bash", "Edit"],
            base: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            contributions: [
                ScopeContribution(
                    source: .profile,
                    allowed: ["Bash", "Edit", "Write"],
                    denied: [],
                    policyVersion: "v1"
                ),
                ScopeContribution(
                    source: .workflowNode(graphID: "g1", nodeID: "n1"),
                    allowed: ["Bash", "Edit"],
                    denied: ["Write"],
                    policyVersion: "v1"
                )
            ]
        )
        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(ResolvedToolScope.self, from: data)
        XCTAssertEqual(decoded.effective, ["Bash", "Edit"])
        XCTAssertEqual(decoded.base, ["Bash", "Edit", "Write"])
        XCTAssertEqual(decoded.denied, ["Write"])
        XCTAssertEqual(decoded.contributions.count, 2)
        XCTAssertEqual(decoded, resolved)
    }

    func testToolScopeSourceCodableAssociatedValues() throws {
        let sources: [ToolScopeSource] = [
            .profile,
            .taskHint(taskID: "task-123"),
            .workflowNode(graphID: "graph-1", nodeID: "node-A")
        ]
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(ToolScopeSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }

    func testScopeDecisionPermitted() {
        let decision = ScopeDecision.permitted
        if case .permitted = decision {
            // pass
        } else {
            XCTFail("Expected permitted")
        }
    }

    func testScopeDecisionDeniedExplicit() {
        let decision = ScopeDecision.denied(reason: .explicitDeny)
        if case .denied(let reason) = decision {
            XCTAssertEqual(reason, .explicitDeny)
        } else {
            XCTFail("Expected denied")
        }
    }

    func testScopeDecisionDeniedNotInAllowed() {
        let decision = ScopeDecision.denied(reason: .notInAllowed)
        if case .denied(let reason) = decision {
            XCTAssertEqual(reason, .notInAllowed)
        } else {
            XCTFail("Expected denied")
        }
    }


}
