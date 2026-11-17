import Foundation

/// How full an agent's context window is: the tokens the last turn's `result`
/// put in the window, and the window's size. The chat header, `/context` and
/// `GET /v1/agents` all read this one value, so all three give the same number.
package struct ContextOccupancy: Equatable, Sendable {
    /// Tokens in the window — input, cache read and cache creation.
    package let tokens: Int
    /// The window's size, nil until the CLI has reported one.
    package let windowSize: Int?

    /// `input_tokens` is only the uncached delta; the prior conversation lives
    /// in cache read and cache creation. Output tokens are not context window
    /// occupancy, so none are taken.
    package init(inputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, windowSize: Int?) {
        self.tokens = inputTokens + cacheReadTokens + cacheCreationTokens
        self.windowSize = windowSize
    }

    /// The share of the window in use, 0–100 — nil when the size is unknown or 0.
    package var percent: Double? {
        guard let windowSize, windowSize > 0 else { return nil }
        return Double(tokens) / Double(windowSize) * 100
    }

    /// `42.1k / 200k` — or just the tokens while the size is unknown.
    package var headerText: String {
        guard let windowSize else { return Self.compact(tokens) }
        return "\(Self.compact(tokens)) / \(Self.compact(windowSize))"
    }

    /// `950` as it is, `42_120` as `42.1k`, `200_000` as `200k`, `1_000_000` as `1M`.
    package static func compact(_ count: Int) -> String {
        let thousands = (Double(count) / 100).rounded() / 10
        if count < 1_000 { return "\(count)" }
        if thousands < 1_000 { return trimmed(thousands) + "k" }
        return trimmed((Double(count) / 100_000).rounded() / 10) + "M"
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
