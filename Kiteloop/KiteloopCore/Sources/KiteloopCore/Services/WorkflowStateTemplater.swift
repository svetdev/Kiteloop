import Foundation

package struct TemplateResult: Sendable {
    package let rendered: String
    package let referencedKeys: Set<String>

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(rendered: String, referencedKeys: Set<String>) {
        self.rendered = rendered
        self.referencedKeys = referencedKeys
    }
}

package enum WorkflowStateTemplater {
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{\{state\.([a-zA-Z0-9_]+|\*)\}\}"#,
        options: []
    )

    private static let conditionalRegex = try! NSRegularExpression(
        pattern: #"\{\{#if (?:state\.)?([a-zA-Z0-9_]+)\}\}(.*?)\{\{/if\}\}"#,
        options: [.dotMatchesLineSeparators]
    )

    package static func render(template: String, state: [String: AnyCodable]) -> TemplateResult {
        let processed = processConditionals(template: template, state: state)

        var referencedKeys = Set<String>()
        let nsTemplate = processed as NSString
        let matches = placeholderRegex.matches(in: processed, range: NSRange(location: 0, length: nsTemplate.length))

        // First pass: collect all referenced keys (non-star)
        for match in matches {
            let keyRange = match.range(at: 1)
            let key = nsTemplate.substring(with: keyRange)
            if key == "*" { continue }
            // Track key as referenced BEFORE checking if value exists/is stringifiable
            // This ensures null/complex values are excluded from {{state.*}} output
            if state[key] != nil {
                referencedKeys.insert(key)
            }
        }

        // Second pass: perform replacements
        var result = processed
        // Process in reverse order to preserve ranges
        for match in matches.reversed() {
            let fullRange = Range(match.range, in: result)!
            let keyRange = match.range(at: 1)
            let key = (processed as NSString).substring(with: keyRange)

            if key == "*" {
                let remainder = state.filter { !referencedKeys.contains($0.key) }
                if remainder.isEmpty {
                    result.replaceSubrange(fullRange, with: "{}")
                } else {
                    let encoded = try? JSONEncoder().encode(remainder)
                    let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    result.replaceSubrange(fullRange, with: json)
                }
            } else if let value = state[key], let stringVal = value.stringValue {
                result.replaceSubrange(fullRange, with: stringVal)
            }
            // If key is in state but not stringifiable: leave placeholder, key already tracked
            // If key is not in state: leave placeholder, key not tracked
        }

        return TemplateResult(rendered: result, referencedKeys: referencedKeys)
    }

    private static func processConditionals(template: String, state: [String: AnyCodable]) -> String {
        let nsTemplate = template as NSString
        let matches = conditionalRegex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))
        guard !matches.isEmpty else { return template }

        var result = template
        for match in matches.reversed() {
            let fullRange = Range(match.range, in: result)!
            let key = (template as NSString).substring(with: match.range(at: 1))
            let content = (template as NSString).substring(with: match.range(at: 2))

            if let value = state[key], let str = value.stringValue, !str.isEmpty {
                result.replaceSubrange(fullRange, with: content)
            } else {
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
    }
}
