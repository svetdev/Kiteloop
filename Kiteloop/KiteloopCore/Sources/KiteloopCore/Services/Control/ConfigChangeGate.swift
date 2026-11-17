import Foundation

/// Whether a call is a configuration change made by an agent — one that waits
/// on a person's approval before it applies (`HeldConfigChanges`).
///
/// The one place that is decided. It keys on the credential: the same route
/// called with the person's own token, or from a paired phone, is never held.
/// Which routes is not a list kept here: `ControlRoute.changesConfiguration`
/// classifies every route — the ones that change what agents are allowed to
/// do or what Kiteloop does unattended — in a switch with no `default:`, so a
/// route added later is held or not by a line someone had to write. Everyday
/// work that needs the `configure` scope (a backlog item, memory, knowledge)
/// is checked against the token's scope and not held.
package enum ConfigChangeGate {

    /// Whether `route`, called with `method`, changes what agents are allowed
    /// to do or what Kiteloop does unattended.
    package static func isConfigurationChange(route: ControlRoute, method: String) -> Bool {
        method.uppercased() != "GET" && route.changesConfiguration
    }

    /// Whether this call waits on a person: a configuration change, made with
    /// a credential that is not the person's own (`ControlCredential`) — the
    /// operator token or a scoped one. Nil is a request with no credential.
    package static func waitsOnAPerson(route: ControlRoute, method: String,
                                       credential: ControlCredential?) -> Bool {
        guard let credential, !credential.isThePersons else { return false }
        return isConfigurationChange(route: route, method: method)
    }
}

/// What a held change asks for, written for the card and the log with the
/// secrets left out: the query and the JSON body, with every value that could
/// be a credential replaced by `redacted`.
///
/// What is left out: the value under any key named like a secret
/// (`SecretRedaction.isSecretName`), every value inside an `env` or `headers`
/// object — an MCP server's credentials live there — and, best effort, what
/// `SecretRedaction` finds in a `command`, in `args` and in any URL.
/// Names stay, so the card still says *which* variable or header was set.
package enum ConfigChangeSummary {

    package static let redacted = SecretRedaction.marker

    /// The summary of a request's query and body.
    package static func text(query: [String: String], body: Data) -> String {
        var parts = query.keys.sorted().map { key in
            "\(key)=\(SecretRedaction.isSecretName(key) ? redacted : SecretRedaction.url(query[key] ?? ""))"
        }
        if let body = bodyText(body) { parts.append(body) }
        return parts.joined(separator: " ")
    }

    private static func bodyText(_ body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: scrubbed(json),
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "a body of \(body.count) bytes that is not JSON"
        }
        return text
    }

    /// `value` with every secret in it replaced.
    private static func scrubbed(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: object.map { ($0.key, scrubbed($0.value, under: $0.key)) })
        }
        if let list = value as? [Any] { return list.map(scrubbed) }
        if let text = value as? String { return SecretRedaction.url(text) }
        return value
    }

    private static func scrubbed(_ value: Any, under key: String) -> Any {
        if SecretRedaction.isSecretName(key) { return redacted }
        if holdsSecrets(key), let object = value as? [String: Any] {
            return object.mapValues { _ in redacted as Any }
        }
        return commandLine(value, under: key) ?? scrubbed(value)
    }

    /// An MCP server's `command` or `args` with the secrets written into it
    /// replaced; nil for any other field.
    private static func commandLine(_ value: Any, under key: String) -> Any? {
        switch (key, value) {
        case ("command", let command as String): return SecretRedaction.text(command)
        case ("args", let arguments as [String]): return SecretRedaction.commandLine(arguments)
        default: return nil
        }
    }

    /// The objects whose values are credentials whatever their keys are called.
    private static func holdsSecrets(_ key: String) -> Bool {
        ["env", "headers"].contains(key.lowercased())
    }
}
