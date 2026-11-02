import Foundation

package struct OTLPConfig: Codable, Sendable {
    package var enabled: Bool
    package var endpoint: String
    package var headers: [String: String]
    package var batchSize: Int
    package var flushIntervalSeconds: Int

    package static let `default` = OTLPConfig(
        enabled: false,
        endpoint: "",
        headers: [:],
        batchSize: 10,
        flushIntervalSeconds: 30
    )

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(enabled: Bool, endpoint: String, headers: [String: String], batchSize: Int, flushIntervalSeconds: Int) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.headers = headers
        self.batchSize = batchSize
        self.flushIntervalSeconds = flushIntervalSeconds
    }
}
