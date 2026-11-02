import XCTest
@testable import Kiteloop

/// What the address bar — and `web_navigate` — makes of a typed address. A bare
/// loopback address gets http, because a local dev server almost never speaks
/// TLS; every other bare host still gets https.
@MainActor
final class WebPreviewNormalizeURLTests: XCTestCase {

    func testBareLocalhostWithPortLoadsOverHTTP() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("localhost:3000")?.absoluteString,
                       "http://localhost:3000")
    }

    func testLocalhostIsMatchedIgnoringCaseAndKeepsPortAndPath() {
        let url = WebPreviewViewModel.normalizeURL("LOCALHOST:3000/app")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.port, 3000)
        XCTAssertEqual(url?.path, "/app")
    }

    func testBareLocalhostWithPathAndNoPortLoadsOverHTTP() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("localhost/docs")?.absoluteString,
                       "http://localhost/docs")
    }

    func testIPv4LoopbackLoadsOverHTTP() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("127.0.0.1:8080")?.absoluteString,
                       "http://127.0.0.1:8080")
    }

    func testIPv6LoopbackLoadsOverHTTP() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("[::1]:5173")?.absoluteString,
                       "http://[::1]:5173")
    }

    func testOtherBareHostsStillLoadOverHTTPS() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("localhost.example.com")?.scheme, "https")
    }

    func testAnAddressWithASchemeIsPassedThroughUnchanged() {
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("https://localhost:3000/x")?.absoluteString,
                       "https://localhost:3000/x")
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("http://example.com")?.absoluteString,
                       "http://example.com")
    }

    func testATildePathOpensAsAFileUnderTheHomeFolder() {
        let url = WebPreviewViewModel.normalizeURL("~/site/index.html")
        XCTAssertEqual(url?.isFileURL, true)
        XCTAssertEqual(url?.path, NSHomeDirectory() + "/site/index.html")
    }

    func testEmptyAndAbsolutePathKeepTheirRules() {
        XCTAssertNil(WebPreviewViewModel.normalizeURL("   "))
        XCTAssertEqual(WebPreviewViewModel.normalizeURL("/tmp/a.html")?.isFileURL, true)
    }
}
