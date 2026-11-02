import Foundation

package struct CostEntry: Codable, Sendable {
    package let agentID: String
    package let date: String
    package let costUSD: Double
    package let inputTokens: Int
    package let outputTokens: Int
    package let durationMs: Int
    package let timestamp: Date

    package init(agentID: String, costUSD: Double, inputTokens: Int, outputTokens: Int, durationMs: Int) {
        self.agentID = agentID
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.timestamp = Date()
        self.date = DayKey.string(for: timestamp)
    }
}
