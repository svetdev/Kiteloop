import Foundation

/// Whether the address+port the pairing sheet is about to hand a phone
/// actually answers something — `.checking` until the probe settles,
/// `.unreachable` on a failure or a timeout, never left hanging.
package enum PairingReachability: Equatable {
    case checking
    case reachable
    case unreachable
}

/// Probes `/health` — the one unauthenticated route `KiteloopControlServer`
/// serves — at a chosen address and port, so the pairing sheet can say
/// before the scan whether anything is listening there. The check itself is
/// injectable, the same seam `SubprocessOutput` uses for the subprocess
/// side, so tests drive reachable/unreachable/timeout without opening a
/// socket.
package struct PairingReachabilityProbe {
    package typealias Check = @Sendable (URL) async throws -> Bool

    private let timeout: TimeInterval
    private let check: Check

    package init(timeout: TimeInterval = 2, check: @escaping Check = PairingReachabilityProbe.urlSessionCheck) {
        self.timeout = timeout
        self.check = check
    }

    /// Races `check` against `timeout`; whichever settles first decides, so a
    /// check slower than the deadline reads as unreachable rather than
    /// hanging the view.
    package func probe(address: String, port: UInt16) async -> PairingReachability {
        guard let url = URL(string: "http://\(address):\(port)/health") else { return .unreachable }
        let check = self.check
        let deadline = timeout
        let reachable = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await check(url)) ?? false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return reachable ? .reachable : .unreachable
    }

    private static let urlSessionCheck: Check = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
