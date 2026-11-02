import XCTest
import KiteloopCore
@testable import Kiteloop

final class ToolInterceptorScopeTests: XCTestCase {
    func testPermittedToolInEffectiveSet() {
        let scope = ResolvedToolScope(
            effective: ["Bash", "Edit"],
            base: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            contributions: []
        )
        let decision = ToolInterceptor.checkScope(tool: "Bash", scope: scope)
        XCTAssertEqual(decision, .permitted)
    }

    func testDeniedToolExplicitly() {
        let scope = ResolvedToolScope(
            effective: ["Bash", "Edit"],
            base: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            contributions: []
        )
        let decision = ToolInterceptor.checkScope(tool: "Write", scope: scope)
        if case .denied(let reason) = decision {
            XCTAssertEqual(reason, .explicitDeny)
        } else {
            XCTFail("Expected denied with explicitDeny")
        }
    }

    func testDeniedToolNotInEffective() {
        let scope = ResolvedToolScope(
            effective: ["Bash"],
            base: ["Bash", "Edit", "Write"],
            denied: [],
            contributions: []
        )
        let decision = ToolInterceptor.checkScope(tool: "Edit", scope: scope)
        if case .denied(let reason) = decision {
            XCTAssertEqual(reason, .notInAllowed)
        } else {
            XCTFail("Expected denied with notInAllowed")
        }
    }

    func testExplicitDenyTakesPrecedenceOverEffective() {
        let scope = ResolvedToolScope(
            effective: ["Bash", "Write"],
            base: ["Bash", "Write"],
            denied: ["Write"],
            contributions: []
        )
        let decision = ToolInterceptor.checkScope(tool: "Write", scope: scope)
        if case .denied(let reason) = decision {
            XCTAssertEqual(reason, .explicitDeny)
        } else {
            XCTFail("Expected denied — deny takes precedence")
        }
    }
}
