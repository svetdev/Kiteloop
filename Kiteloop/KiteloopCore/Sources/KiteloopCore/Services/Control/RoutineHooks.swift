import Foundation

/// A routine's webhook: a name an outside service calls at
/// `POST /v1/hooks/{name}` and a secret that opens that one route for that one
/// routine. Only the secret's SHA-256 is kept; the secret itself is in the
/// mint's answer once.
package struct RoutineHook: Codable, Equatable, Sendable {
    package let name: String
    /// The id of the routine whose prompt the hook sends.
    package let routine: String
    package let secretHash: String
    package let createdAt: Date
}

/// The routines' webhooks, in `~/.kiteloop/routine-hooks.json`, readable by
/// this user only — kept the way `ControlScopedTokens` keeps scoped tokens.
/// Used on the control server's actor: it reads memory on every call and
/// writes the file only when a hook is minted or revoked.
package final class RoutineHooks {
    private let url: URL
    private(set) package var hooks: [RoutineHook]

    package init(url: URL) {
        self.url = url
        hooks = PrivateJSONFile.load([RoutineHook].self, from: url) ?? []
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/routine-hooks.json")
    }

    /// Why a hook could not be minted.
    package enum MintRefusal: Error, Equatable {
        /// The name is not lowercase letters, digits and hyphens.
        case invalidName
        /// A hook already has this name.
        case nameTaken
    }

    /// A new hook named `name` for `routine`: the secret, to hand back once,
    /// and its entry.
    package func mint(name: String, routine: String,
                      at date: Date = .now) -> Result<(secret: String, hook: RoutineHook), MintRefusal> {
        guard Routine.isValidID(name) else { return .failure(.invalidName) }
        guard !hooks.contains(where: { $0.name == name }) else { return .failure(.nameTaken) }
        let secret = ControlDeviceTokens.randomHex()
        let hook = RoutineHook(name: name, routine: routine,
                               secretHash: ControlDeviceTokens.hash(secret), createdAt: date)
        hooks.append(hook)
        save()
        return .success((secret, hook))
    }

    /// The hook named `name` when `secret` is its secret; nil for a name
    /// nobody minted, a revoked hook or any other secret.
    package func hook(named name: String, secret: String) -> RoutineHook? {
        let hash = ControlDeviceTokens.hash(secret)
        return hooks.first { $0.name == name && $0.secretHash == hash }
    }

    /// Revokes the hook named `name`; false when there is none.
    @discardableResult
    package func revoke(name: String) -> Bool {
        guard hooks.contains(where: { $0.name == name }) else { return false }
        hooks.removeAll { $0.name == name }
        save()
        return true
    }

    private func save() {
        PrivateJSONFile.save(hooks, to: url)
    }

    /// The names of the webhooks on file at `url` that fire `routine` — what
    /// the Routines page shows of them. A name is not a secret, and the file
    /// holds no secret to show.
    package static func names(firing routine: String, at url: URL = RoutineHooks.defaultURL) -> [String] {
        RoutineHooks(url: url).hooks.filter { $0.routine == routine }.map(\.name)
    }
}
