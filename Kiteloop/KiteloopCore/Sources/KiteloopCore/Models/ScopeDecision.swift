import Foundation

package enum ScopeDecision: Sendable, Equatable {
    case permitted
    case denied(reason: DenyReason)

    package enum DenyReason: String, Codable, Sendable {
        case explicitDeny
        case notInAllowed
    }
}
