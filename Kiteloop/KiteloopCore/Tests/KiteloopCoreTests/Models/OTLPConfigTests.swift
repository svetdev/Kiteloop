import XCTest
@testable import KiteloopCore

final class OTLPConfigTests: XCTestCase {
    /// Telemetry export is off until someone turns it on. The default carries
    /// no endpoint, so an enabled default would be an exporter pointed at
    /// nowhere — and, once an endpoint is set, a config nobody opted into.
    func testTheDefaultConfigIsDisabled() {
        XCTAssertFalse(OTLPConfig.default.enabled)
        XCTAssertEqual(OTLPConfig.default.endpoint, "")
    }
}
