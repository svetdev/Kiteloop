import Foundation
import os

/// A control token narrowed to one `ControlScope`, minted over the API for a
/// script or a tool that should not hold the whole control token. Only the
/// token's SHA-256 is kept; the token itself is in the mint's answer once.
package struct ControlScopedToken: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let name: String
    package let scope: ControlScope
    package let tokenHash: String
    package let createdAt: Date
}

/// The scoped tokens, in `~/.kiteloop/control-scoped-tokens.json`, readable by
/// this user only — kept the way `ControlDeviceTokens` keeps paired phones.
/// The check runs on every request, so it reads memory and writes the file
/// only when a token is minted or revoked. Guarded by a lock: the control
/// server uses it on its own actor, and `AgentReadToken` mints through the
/// same instance from wherever a session is being spawned.
package final class ControlScopedTokens: Sendable {
    private let url: URL
    private let stored: OSAllocatedUnfairLock<[ControlScopedToken]>

    package init(url: URL) {
        self.url = url
        stored = OSAllocatedUnfairLock(initialState: PrivateJSONFile.load([ControlScopedToken].self, from: url) ?? [])
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/control-scoped-tokens.json")
    }

    /// Every token there is, in the order they were minted.
    package var tokens: [ControlScopedToken] {
        stored.withLock { $0 }
    }

    /// A new token of `scope`: the plaintext, to hand back once, and its entry.
    package func mint(name: String, scope: ControlScope, at date: Date = .now) -> (token: String, entry: ControlScopedToken) {
        let token = ControlDeviceTokens.randomHex()
        let entry = ControlScopedToken(id: UUID(), name: name, scope: scope,
                                       tokenHash: ControlDeviceTokens.hash(token), createdAt: date)
        stored.withLock { tokens in
            tokens.append(entry)
            PrivateJSONFile.save(tokens, to: url)
        }
        return (token, entry)
    }

    /// The entry `token` belongs to; nil for a token never minted or revoked.
    package func token(for token: String) -> ControlScopedToken? {
        let hash = ControlDeviceTokens.hash(token)
        return tokens.first { $0.tokenHash == hash }
    }

    /// Revokes the token with `id`; false when there is none.
    @discardableResult
    package func revoke(_ id: UUID) -> Bool {
        stored.withLock { tokens in
            guard tokens.contains(where: { $0.id == id }) else { return false }
            tokens.removeAll { $0.id == id }
            PrivateJSONFile.save(tokens, to: url)
            return true
        }
    }
}
