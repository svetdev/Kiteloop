import Foundation

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
/// Used on the control server's actor: the check runs on every request, so it
/// reads memory and writes the file only when a token is minted or revoked.
package final class ControlScopedTokens {
    private let url: URL
    private(set) package var tokens: [ControlScopedToken]

    package init(url: URL) {
        self.url = url
        tokens = PrivateJSONFile.load([ControlScopedToken].self, from: url) ?? []
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/control-scoped-tokens.json")
    }

    /// A new token of `scope`: the plaintext, to hand back once, and its entry.
    package func mint(name: String, scope: ControlScope, at date: Date = .now) -> (token: String, entry: ControlScopedToken) {
        let token = ControlDeviceTokens.randomHex()
        let entry = ControlScopedToken(id: UUID(), name: name, scope: scope,
                                       tokenHash: ControlDeviceTokens.hash(token), createdAt: date)
        tokens.append(entry)
        save()
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
        guard tokens.contains(where: { $0.id == id }) else { return false }
        tokens.removeAll { $0.id == id }
        save()
        return true
    }

    private func save() {
        PrivateJSONFile.save(tokens, to: url)
    }
}
