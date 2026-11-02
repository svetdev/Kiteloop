import Foundation

package struct MentionParseResult: Equatable {
    package let mentions: [String]
    package let isInlineMode: Bool
    package let cleanText: String

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(mentions: [String], isInlineMode: Bool, cleanText: String) {
        self.mentions = mentions
        self.isInlineMode = isInlineMode
        self.cleanText = cleanText
    }
}

package enum MentionParser {
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9])@([a-zA-Z][a-zA-Z0-9\-]*)"#,
        options: []
    )

    package static func parse(_ text: String) -> MentionParseResult {
        let range = NSRange(text.startIndex..., in: text)
        let matches = mentionPattern.matches(in: text, options: [], range: range)

        // Naming a handle more than once summons the specialist once: the routing
        // loop acts on every entry, so a repeat would spawn a second agent or run a
        // second consult. Both resolvers match case-insensitively, so `@Bot` and
        // `@bot` are the same specialist — collapse on the lowercased handle, keeping
        // the order and the spelling of the first occurrence.
        var mentions: [String] = []
        var seen: Set<String> = []
        for match in matches {
            if let captureRange = Range(match.range(at: 1), in: text) {
                let handle = String(text[captureRange])
                if seen.insert(handle.lowercased()).inserted {
                    mentions.append(handle)
                }
            }
        }

        let isInline = text.contains("--here")

        var clean = text
        for match in matches.reversed() {
            if let fullRange = Range(match.range, in: clean) {
                clean.removeSubrange(fullRange)
            }
        }
        clean = clean.replacingOccurrences(of: "--here", with: "")
        clean = clean.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return MentionParseResult(
            mentions: mentions,
            isInlineMode: isInline,
            cleanText: clean
        )
    }
}
