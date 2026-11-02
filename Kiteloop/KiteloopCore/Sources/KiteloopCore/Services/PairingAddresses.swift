import Foundation

/// Which of a Mac's IPv4 addresses a phone can actually pair over, and what
/// to call each one in the picker. Classifies by octet rather than by text
/// prefix so a 172.16–172.31 lease (ordinary on guest and corporate Wi-Fi)
/// isn't dropped, and so a public 100.200.x.x address isn't mistaken for
/// Tailscale's CGNAT range — 100.64.0.0/10, not everything starting `100.`.
package enum PairingAddresses {

    /// `raw` filtered to the ranges a phone can reach the Mac on — tailnet
    /// (100.64.0.0/10), then LAN (10/8, 172.16/12, 192.168/16) — tailnet
    /// first, input order preserved otherwise, duplicates collapsed.
    package static func reachable(from raw: [String]) -> [String] {
        var seen = Set<String>()
        var tailnet: [String] = []
        var lan: [String] = []
        for address in raw {
            guard let octets = octets(of: address), seen.insert(address).inserted else { continue }
            if isTailnet(octets) {
                tailnet.append(address)
            } else if isLAN(octets) {
                lan.append(address)
            }
        }
        return tailnet + lan
    }

    /// What the picker calls `address`: "Tailnet" inside the CGNAT range,
    /// else "Wi-Fi".
    package static func label(for address: String) -> String {
        guard let octets = octets(of: address), isTailnet(octets) else { return "Wi-Fi" }
        return "Tailnet"
    }

    private static func octets(of address: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { UInt8($0) }
        guard values.count == 4 else { return nil }
        return (values[0], values[1], values[2], values[3])
    }

    private static func isTailnet(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        octets.0 == 100 && (64...127).contains(octets.1)
    }

    private static func isLAN(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        if octets.0 == 10 { return true }
        if octets.0 == 172 { return (16...31).contains(octets.1) }
        if octets.0 == 192 { return octets.1 == 168 }
        return false
    }
}
