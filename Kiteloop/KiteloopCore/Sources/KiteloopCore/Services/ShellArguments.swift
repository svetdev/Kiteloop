import Foundation

/// One line of arguments, the way a shell reads it, and the way back.
///
/// A settings panel that holds an argument list as a single text field has to
/// turn the line into an array and the array back into a line. Splitting on
/// every space tears `--root /Users/me/My Project` into two arguments and grows
/// the array on every save; this honours quotes and a backslash-escaped space,
/// so the round trip is a fixed point.
package enum ShellArguments {

    /// The arguments in `line`, splitting on unquoted whitespace. Single quotes,
    /// double quotes and a backslash escape group; an unterminated quote yields
    /// the rest of the line as one argument rather than dropping it.
    package static func tokenize(_ line: String) -> [String] {
        var scan = Scan()
        for character in line {
            scan.take(character)
        }
        return scan.finished()
    }

    /// One line holding `arguments`, quoting only the elements that need it, so
    /// that `tokenize` reads back exactly the array given here.
    package static func line(from arguments: [String]) -> String {
        arguments.map(quoted(_:)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        guard needsQuoting(argument) else { return argument }
        let escaped = argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func needsQuoting(_ argument: String) -> Bool {
        argument.isEmpty || argument.contains { character in
            character.isWhitespace || character == "\"" || character == "'" || character == "\\"
        }
    }

    /// The tokenizer's state: the argument being built, whether one has begun
    /// (so `""` survives as an empty argument), the quote we are inside, and
    /// whether the previous character was a backslash.
    private struct Scan {
        private var tokens: [String] = []
        private var current = ""
        private var begun = false
        private var quote: Character?
        private var escaped = false

        mutating func take(_ character: Character) {
            if escaped {
                append(character)
                escaped = false
            } else if let quote {
                takeQuoted(character, within: quote)
            } else {
                takeBare(character)
            }
        }

        mutating func finished() -> [String] {
            close()
            return tokens
        }

        private mutating func takeQuoted(_ character: Character, within quote: Character) {
            if character == quote {
                self.quote = nil
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else {
                append(character)
            }
        }

        private mutating func takeBare(_ character: Character) {
            if character == "\"" || character == "'" {
                quote = character
                begun = true
            } else if character == "\\" {
                escaped = true
                begun = true
            } else if character.isWhitespace {
                close()
            } else {
                append(character)
            }
        }

        private mutating func append(_ character: Character) {
            current.append(character)
            begun = true
        }

        private mutating func close() {
            guard begun else { return }
            tokens.append(current)
            current = ""
            begun = false
        }
    }
}
