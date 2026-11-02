import Foundation

/// The phone's one-tap replies, kept on the Mac so every paired phone offers
/// the same ones (`GET /v1/quick-replies`, edited in Settings → Control API).
package enum QuickReplies {
    /// What a list never set reads as: the replies a phone sends most.
    package static let starters = ["Continue", "Yes, go ahead", "Run the tests"]

    /// The list in effect: the saved one, else the starters.
    package static func effective(_ config: GlobalConfig) -> [String] {
        config.quickReplies ?? starters
    }

    /// Settings' text, one reply per line, as the list it saves: each line
    /// trimmed, blank lines dropped.
    package static func list(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
