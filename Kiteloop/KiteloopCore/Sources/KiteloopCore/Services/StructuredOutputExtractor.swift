import Foundation

/// Pulls structured fields out of an agent's free-text reply. Deliberately
/// lenient: a reviewer that answers "passed: true" — with or without fences,
/// with trailing prose, missing a sibling field, or phrasing the boolean as
/// "yes"/"pass" — should still route correctly instead of dead-ending.
package enum StructuredOutputExtractor {

    package static func extract(from text: String, schema: OutputSchema) -> [String: AnyCodable]? {
        // Try every JSON object we can find (fenced, trailing, or embedded),
        // then fall back to loose key/value patterns.
        for json in candidateJSONObjects(from: text) {
            if let result = matchAgainstSchema(json: json, schema: schema) {
                return result
            }
        }
        return extractKeyValuePatterns(from: text, schema: schema)
    }

    // MARK: - JSON candidates

    private static func candidateJSONObjects(from text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []

        // Fenced code blocks — newlines around the content are optional, so
        // ```json {"passed": true}``` on one line still matches.
        let fence = #"```(?:json)?\s*([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fence) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text),
                   let obj = parseJSON(String(text[range])) {
                    objects.append(obj)
                }
            }
        }

        // Every balanced {...} object anywhere in the text — covers a trailing
        // JSON object, JSON followed by prose, or several objects.
        objects.append(contentsOf: balancedObjects(in: text))
        return objects
    }

    /// Finds each top-level `{...}` object, respecting quoted strings/escapes so
    /// braces inside string values don't throw off the depth count.
    private static func balancedObjects(in text: String) -> [[String: Any]] {
        balancedSlices(in: text, open: "{", close: "}").compactMap(parseJSON)
    }

    /// Each balanced top-level `open`…`close` slice, in the order it appears,
    /// respecting quoted strings and escapes so a delimiter inside a string
    /// value doesn't throw off the depth count. An unclosed delimiter yields
    /// nothing and the scan resumes after it.
    ///
    /// Generalised over the pair so `BacklogAIEditor` can find the `[…]` array
    /// of edit operations the same way rather than by first-`[`-to-last-`]`,
    /// which any bracket in the surrounding prose widened into the slice.
    package static func balancedSlices(in text: String, open: Character, close: Character) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == open else { i += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var j = i
            var closed = false
            while j < chars.count {
                let c = chars[j]
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString.toggle()
                } else if !inString {
                    if c == open { depth += 1 }
                    else if c == close {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                    }
                }
                j += 1
            }
            if closed {
                results.append(String(chars[i...j]))
                i = j + 1
            } else {
                i += 1
            }
        }
        return results
    }

    // MARK: - Schema matching

    private static func matchAgainstSchema(json: [String: Any], schema: OutputSchema) -> [String: AnyCodable]? {
        var result: [String: AnyCodable] = [:]
        for (key, field) in schema.fields {
            guard let value = json[key], let string = stringify(value) else { continue }
            result[key] = .string(canonicalize(string, fieldType: field.type))
        }
        // Lenient: return whatever matched. A present `passed` should route even
        // if a sibling "required" field (e.g. reason) is absent — a missing
        // field is far better than dead-ending the whole workflow.
        return result.isEmpty ? nil : result
    }

    /// Distinguishes JSON booleans from numbers (both bridge to `NSNumber`, and
    /// `1 as? Bool` is `true`), so a numeric score isn't misread as a boolean.
    private static func stringify(_ value: Any) -> String? {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return (value as? Bool) == true ? "true" : "false"
        }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let str = value as? String { return str }
        // A JSON `null` carries no value — treat it as absent rather than
        // stringifying it. `isValidJSONObject` guards the re-encode below:
        // it raises an ObjC exception on non-container values, which `try?`
        // cannot catch, so an unguarded call would crash the process.
        if value is NSNull { return nil }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }

    private static func canonicalize(_ value: String, fieldType: String) -> String {
        guard fieldType == "boolean" else { return value }
        return normalizeBoolean(value) ?? value
    }

    /// Maps loose truthiness to the canonical `"true"`/`"false"` the edges match.
    private static func normalizeBoolean(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y", "pass", "passed", "approve", "approved", "ok", "success", "1":
            return "true"
        case "false", "no", "n", "fail", "failed", "reject", "rejected", "0":
            return "false"
        default:
            return nil
        }
    }

    // MARK: - Key/value fallback

    private static func extractKeyValuePatterns(from text: String, schema: OutputSchema) -> [String: AnyCodable]? {
        var result: [String: AnyCodable] = [:]
        for (key, field) in schema.fields {
            if let value = extractValueForKey(key, from: text) {
                result[key] = .string(canonicalize(value, fieldType: field.type))
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func extractValueForKey(_ key: String, from text: String) -> String? {
        // Match patterns like: key: "value" or key: value or - key: value
        let patterns = [
            #"(?:^|\n)\s*[-•]?\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*:\s*"([^"]+)""#,
            #"(?:^|\n)\s*[-•]?\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*:\s*(.+?)(?:\n|$)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[valueRange]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseJSON(_ str: String) -> [String: Any]? {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
