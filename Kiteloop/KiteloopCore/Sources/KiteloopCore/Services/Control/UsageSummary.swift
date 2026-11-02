import Foundation

/// `GET /v1/usage`'s reading of the agents' rate limits: of every reading the
/// open agents' CLIs last reported, the one closest to its limit.
package enum UsageSummary {
    /// A refusal first, then any other warning, then the highest share used.
    package static func closest(_ readings: [AgentActivityEvent.RateLimitInfo]) -> AgentActivityEvent.RateLimitInfo? {
        readings.max { rank($0) < rank($1) }
    }

    private static func rank(_ reading: AgentActivityEvent.RateLimitInfo) -> (Int, Double) {
        let severity = switch reading.status {
        case "allowed": 0
        case "rejected": 2
        default: 1
        }
        return (severity, reading.utilization ?? 0)
    }
}
