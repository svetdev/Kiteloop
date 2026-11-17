import Foundation

/// The one read-scoped control token the app keeps for agents whose
/// `controlAccess` is `read` (`AgentControlAccess.readOnly`), so such an agent
/// is spawned holding a token that can only read instead of the operator token.
///
/// Its lifecycle:
/// - **Minted in process, on the first spawn that needs it** — an entry named
///   `AgentReadToken.name`, scope `read`, in the same `ControlScopedTokens`
///   the server answers `/v1/tokens` from, so it is listed and revoked there
///   like any other. An install with no read-only agent never has one.
/// - **Reused**: the token is kept beside the operator token, in
///   `~/.kiteloop/agent-read-token` (`0600`), because the store holds only its
///   hash. Every later spawn, of every read-only agent, reads it from there.
/// - **Revocable**: `DELETE /v1/tokens/{id}` stops it at once for every session
///   holding it. The next read-only spawn finds the kept token no longer in
///   the store and mints a fresh one — a revoke is a rotation; taking the
///   access away is turning the agent's Operator tools off.
/// - **Never in a project folder**: it lives under `~/.kiteloop` and reaches an
///   agent only through its environment.
package struct AgentReadToken: Sendable {
    /// The name the token carries in `GET /v1/tokens`.
    package static let name = "Kiteloop read-only agents"

    private static let lock = NSLock()

    private let store: ControlScopedTokens
    private let fileURL: URL

    package init(store: ControlScopedTokens, fileURL: URL = AgentReadToken.defaultURL) {
        self.store = store
        self.fileURL = fileURL
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/agent-read-token")
    }

    /// The token to spawn a read-only agent with: the kept one while the store
    /// still holds it as a `read` token, else a new one. Nil when a new token
    /// could not be kept — it is revoked again rather than handed out, since a
    /// token that cannot be reused would be minted anew at every spawn.
    package func current() -> String? {
        Self.lock.withLock {
            if let kept = kept, store.token(for: kept)?.scope == .read { return kept }
            let (token, entry) = store.mint(name: Self.name, scope: .read)
            do {
                try AtomicFileWriter.write(Data(token.utf8), to: fileURL, mode: 0o600)
            } catch {
                store.revoke(entry.id)
                return nil
            }
            return token
        }
    }

    /// The token in the file, read strictly: bytes that are not UTF-8 are no token.
    private var kept: String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
