import Foundation

package enum RoutingMode: Sendable {
    case freeform
    case graphControlled(executionID: String)
}
