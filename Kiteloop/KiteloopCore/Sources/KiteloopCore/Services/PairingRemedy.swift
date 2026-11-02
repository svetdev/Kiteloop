import Foundation

/// What the pairing sheet's reachability banner says, and — for
/// `.unreachable` — what fixes it. `.unreachable` has two distinct causes
/// that look identical to the probe: the control server toggle is off, or
/// it's on and nothing answers at the offered address. Only the caller
/// knows which, so it passes `serverRunning` in.
package struct PairingRemedy: Equatable {
    package let headline: String
    package let remedy: String?

    package init(headline: String, remedy: String? = nil) {
        self.headline = headline
        self.remedy = remedy
    }

    package static func banner(
        for reachability: PairingReachability,
        address: String,
        port: UInt16,
        serverRunning: Bool
    ) -> PairingRemedy {
        switch reachability {
        case .checking:
            return PairingRemedy(headline: "Checking \(address):\(String(port))…")
        case .reachable:
            return PairingRemedy(headline: "\(address):\(String(port)) is reachable.")
        case .unreachable where !serverRunning:
            return PairingRemedy(
                headline: "The control server isn't running — the phone would hang.",
                remedy: "Turn on the control server above, then pair again.")
        case .unreachable:
            return PairingRemedy(
                headline: "Nothing answers at \(address):\(String(port)) — the phone would hang.",
                remedy: "Run ./scripts/install-control-forwarder.sh on this Mac so the phone can reach it.")
        }
    }
}
