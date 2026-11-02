import Foundation

/// A groomed detail file's prose — What, How, Validation, Notes and the rest —
/// as the item pages draw it. `Text(String)` prints a field verbatim, so every
/// backticked path in a How read as literal backticks; this renders the inline
/// markdown instead and keeps the field's newlines. Block-level syntax is not
/// interpreted: a groomed field is inline text.
enum GroomedText {

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
