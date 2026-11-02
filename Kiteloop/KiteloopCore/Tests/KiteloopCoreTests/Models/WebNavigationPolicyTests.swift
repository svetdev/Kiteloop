import XCTest
@testable import KiteloopCore

final class WebNavigationPolicyTests: XCTestCase {
    private func decide(
        _ mode: WebPreviewMode,
        _ urlString: String,
        _ source: WebNavigationSource,
        allowlist: Set<String> = []
    ) -> WebNavigationDecision {
        WebNavigationPolicy.decide(
            mode: mode,
            url: URL(string: urlString)!,
            source: source,
            allowlist: allowlist
        )
    }

    func testTrustedAllowsLocalAndFile() {
        XCTAssertEqual(decide(.trusted, "file:///tmp/index.html", .user), .allow)
        XCTAssertEqual(decide(.trusted, "http://localhost:3000/app", .user), .allow)
        XCTAssertEqual(decide(.trusted, "http://127.0.0.1:8080", .programmatic), .allow)
        XCTAssertEqual(decide(.trusted, "about:blank", .user), .allow)
    }

    func testTrustedDeniesExternal() {
        XCTAssertEqual(decide(.trusted, "https://example.com", .user), .deny)
        XCTAssertEqual(decide(.trusted, "https://example.com", .programmatic), .deny)
    }

    func testExternalUserBrowsingIsAllowed() {
        XCTAssertEqual(decide(.external, "https://example.com", .user), .allow)
        XCTAssertEqual(decide(.external, "http://localhost:3000", .user), .allow)
    }

    func testExternalAgentLoadIsGated() {
        // Not allowlisted → confirm; allowlisted → allow; local → allow.
        XCTAssertEqual(decide(.external, "https://evil.test/x", .programmatic), .confirm)
        XCTAssertEqual(decide(.external, "https://api.example.com", .programmatic, allowlist: ["api.example.com"]), .allow)
        XCTAssertEqual(decide(.external, "http://localhost:5173", .programmatic), .allow)
    }

    func testNonWebSchemesDenied() {
        XCTAssertEqual(decide(.external, "javascript:alert(1)", .user), .deny)
        XCTAssertEqual(decide(.trusted, "ftp://host/file", .user), .deny)
    }

    // MARK: - External allowlist matching

    func testAllowlistMatchIsCaseInsensitiveOnTheURLHost() {
        // The policy lowercases the host before matching, so a shouted URL still
        // hits a lowercase allowlist entry.
        XCTAssertEqual(
            decide(.external, "HTTPS://API.EXAMPLE.COM/v1", .programmatic, allowlist: ["api.example.com"]),
            .allow
        )
        XCTAssertEqual(
            decide(.external, "https://API.Example.COM/v1", .programmatic, allowlist: ["api.example.com"]),
            .allow
        )
    }

    func testAllowlistEntriesMustBeStoredLowercase() {
        // Only the URL side is normalized — an uppercase entry never matches.
        XCTAssertEqual(
            decide(.external, "https://api.example.com", .programmatic, allowlist: ["API.EXAMPLE.COM"]),
            .confirm
        )
    }

    func testAllowlistIgnoresPortAndUserInfo() {
        XCTAssertEqual(
            decide(.external, "https://api.example.com:8443/v1", .programmatic, allowlist: ["api.example.com"]),
            .allow
        )
        XCTAssertEqual(
            decide(.external, "https://user:pw@api.example.com/v1", .programmatic, allowlist: ["api.example.com"]),
            .allow
        )
        // ...and an entry that bakes in the port matches nothing.
        XCTAssertEqual(
            decide(.external, "https://api.example.com:8443/v1", .programmatic, allowlist: ["api.example.com:8443"]),
            .confirm
        )
    }

    func testAllowlistIsExactHostNotSuffixMatch() {
        let allowlist: Set<String> = ["example.com"]
        // Subdomains are not covered by the parent entry.
        XCTAssertEqual(decide(.external, "https://docs.example.com", .programmatic, allowlist: allowlist), .confirm)
        // Nor is a lookalike that merely ends with the entry.
        XCTAssertEqual(decide(.external, "https://notexample.com", .programmatic, allowlist: allowlist), .confirm)
        XCTAssertEqual(decide(.external, "https://example.com.evil.test", .programmatic, allowlist: allowlist), .confirm)
        // A fully-qualified trailing-dot host is a different string, so it too is gated.
        XCTAssertEqual(decide(.external, "https://example.com.", .programmatic, allowlist: allowlist), .confirm)
        // And a subdomain entry does not unlock its parent.
        XCTAssertEqual(decide(.external, "https://example.com", .programmatic, allowlist: ["docs.example.com"]), .confirm)
    }

    func testExternalAgentLoadWithoutMatchingEntryConfirms() {
        XCTAssertEqual(decide(.external, "https://evil.test", .programmatic, allowlist: []), .confirm)
        XCTAssertEqual(
            decide(.external, "https://evil.test", .programmatic, allowlist: ["api.example.com", "docs.example.com"]),
            .confirm
        )
    }

    func testHostlessHTTPURLIsGatedForAgentLoads() {
        // No host at all → nothing to match against, so the human decides.
        XCTAssertEqual(decide(.external, "https:///path", .programmatic), .confirm)
        XCTAssertEqual(decide(.external, "https:///path", .user), .allow)
    }

    // MARK: - Scope of the allowlist

    func testAllowlistIsIrrelevantWhenTheUserDrivesNavigation() {
        XCTAssertEqual(decide(.external, "https://evil.test", .user, allowlist: []), .allow)
        XCTAssertEqual(decide(.external, "https://evil.test", .user, allowlist: ["api.example.com"]), .allow)
    }

    func testAllowlistDoesNotUnlockTrustedMode() {
        XCTAssertEqual(decide(.trusted, "https://api.example.com", .programmatic, allowlist: ["api.example.com"]), .deny)
        XCTAssertEqual(decide(.trusted, "https://api.example.com", .user, allowlist: ["api.example.com"]), .deny)
    }

    func testAllowlistCannotWidenNonWebSchemes() {
        XCTAssertEqual(decide(.external, "ftp://api.example.com/f", .programmatic, allowlist: ["api.example.com"]), .deny)
        XCTAssertEqual(decide(.external, "javascript:alert(1)", .programmatic, allowlist: ["api.example.com"]), .deny)
    }

    func testLocalHostsBypassTheAllowlist() {
        XCTAssertEqual(decide(.external, "http://LocalHost:3000/app", .programmatic), .allow)
        XCTAssertEqual(decide(.external, "http://127.0.0.1:8080", .programmatic), .allow)
        XCTAssertEqual(decide(.external, "http://[::1]:8080/app", .programmatic), .allow)
        XCTAssertEqual(decide(.trusted, "http://[::1]:8080/app", .programmatic), .allow)
        // Names that merely contain a loopback token are ordinary external hosts.
        XCTAssertEqual(decide(.external, "https://localhost.evil.test", .programmatic), .confirm)
        XCTAssertEqual(decide(.trusted, "https://notlocalhost.com", .user), .deny)
    }

    func testLocalRenderingSchemesBypassGatingInBothModes() {
        XCTAssertEqual(decide(.external, "file:///tmp/report.html", .programmatic), .allow)
        XCTAssertEqual(decide(.external, "about:blank", .programmatic), .allow)
        XCTAssertEqual(decide(.external, "FILE:///tmp/report.html", .programmatic), .allow)
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertEqual(decide(.external, "HTTPS://example.com", .user), .allow)
        XCTAssertEqual(decide(.trusted, "HTTP://localhost:3000", .user), .allow)
        XCTAssertEqual(decide(.trusted, "HTTPS://example.com", .user), .deny)
    }
}
