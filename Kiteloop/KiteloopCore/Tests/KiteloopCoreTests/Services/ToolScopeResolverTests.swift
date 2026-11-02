import XCTest
@testable import KiteloopCore

final class ToolScopeResolverTests: XCTestCase {
    func testProfileOnlyResolvesToProfileAllowed() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write", "Read"],
            denied: [],
            policyVersion: "v1"
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit", "Write", "Read"])
        XCTAssertEqual(resolved.base, ["Bash", "Edit", "Write", "Read"])
        XCTAssertTrue(resolved.denied.isEmpty)
        XCTAssertEqual(resolved.contributions.count, 1)
    }

    func testProfileDeniedSubtractsFromEffective() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            policyVersion: "v1"
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit"])
        XCTAssertEqual(resolved.denied, ["Write"])
    }

    func testTaskLayerIntersectsWithProfile() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write", "Read"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: ["Bash", "Edit"],
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "t1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit"])
    }

    func testNilAllowedIsIdentity() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: nil,
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "t1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit", "Write"])
    }

    func testEmptyAllowedBlocksAll() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: [],
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "t1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task])
        XCTAssertTrue(resolved.effective.isEmpty)
    }

    func testDenyPrecedenceAcrossLayers() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: nil,
            denied: ["Bash"],
            policyVersion: "v1",
            source: .taskHint(taskID: "t1")
        )
        let workflow = LayerToolScope(
            allowed: nil,
            denied: ["Edit"],
            policyVersion: "v1",
            source: .workflowNode(graphID: "g1", nodeID: "n1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task, workflow])
        XCTAssertEqual(resolved.effective, ["Write"])
        XCTAssertEqual(resolved.denied, ["Bash", "Edit"])
    }

    func testMultipleLayersIntersect() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit", "Write", "Read"],
            denied: [],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: ["Bash", "Edit", "Write"],
            denied: [],
            policyVersion: "v1",
            source: .taskHint(taskID: "t1")
        )
        let workflow = LayerToolScope(
            allowed: ["Bash", "Edit"],
            denied: [],
            policyVersion: "v1",
            source: .workflowNode(graphID: "g1", nodeID: "n1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task, workflow])
        XCTAssertEqual(resolved.effective, ["Bash", "Edit"])
    }

    func testContributionsRecordAllLayers() {
        let profile = ProfileToolScope(
            allowed: ["Bash", "Edit"],
            denied: ["Write"],
            policyVersion: "v1"
        )
        let task = LayerToolScope(
            allowed: ["Bash"],
            denied: [],
            policyVersion: "v2",
            source: .taskHint(taskID: "t1")
        )
        let resolved = ToolScopeResolver.resolve(profile: profile, layers: [task])
        XCTAssertEqual(resolved.contributions.count, 2)
        XCTAssertEqual(resolved.contributions[0].source, .profile)
        XCTAssertEqual(resolved.contributions[0].allowed, ["Bash", "Edit"])
        XCTAssertEqual(resolved.contributions[0].denied, ["Write"])
        XCTAssertEqual(resolved.contributions[1].source, .taskHint(taskID: "t1"))
        XCTAssertEqual(resolved.contributions[1].allowed, ["Bash"])
    }
}
