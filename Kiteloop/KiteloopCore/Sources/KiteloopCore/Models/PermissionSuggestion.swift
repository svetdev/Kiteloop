import Foundation

/// One thing the CLI offers to remember with the answer to a permission
/// prompt: a rule, a directory, a mode. `json` is the offer as the CLI wrote
/// it, handed back untouched when it is taken; `label` says it to a person.
package struct PermissionSuggestion: Codable, Equatable, Sendable {
    package let label: String
    package let json: String

    package init(label: String, json: String) {
        self.label = label
        self.json = json
    }
}
