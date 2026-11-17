import Foundation

/// Which of the control API's credentials a request came with, reduced to
/// what decides who is asking: a person, or something a person handed a
/// token to.
package enum ControlCredentialKind: Sendable, CaseIterable {
    /// The full control token — the person's own.
    case full
    /// A paired phone's token — the person's own, on their phone.
    case paired
    /// The operator token, handed to an agent with operator tools.
    case operatorToken
    /// A token minted over `/v1/tokens`, whatever its scope.
    case scoped
    /// No valid credential.
    case none

    /// Whether the credential is one a person holds themselves, rather than
    /// one given to an agent or a script.
    package var isAPersons: Bool {
        switch self {
        case .full, .paired: return true
        case .operatorToken, .scoped, .none: return false
        }
    }
}

/// Whether a call is a configuration change made by an agent — one that waits
/// on a person's approval before it applies (`HeldConfigChanges`).
///
/// The one place that is decided. It keys on the credential: the same route
/// called with the person's own token, or from a paired phone, is never held.
/// The routes are not a list kept here — they are the ones `ControlRoute.scope`
/// already says need `configure`, less the reads among them, so a route added
/// to that classification is held without anyone remembering to add it.
package enum ConfigChangeGate {

    /// Whether `route`, called with `method`, changes how a team, a project or
    /// the app is set up.
    package static func isConfigurationChange(route: ControlRoute, method: String) -> Bool {
        method.uppercased() != "GET" && route.scope == .configure
    }

    /// Whether this call waits on a person: a configuration change, made with
    /// the operator token or a scoped one.
    package static func waitsOnAPerson(route: ControlRoute, method: String,
                                       credential: ControlCredentialKind) -> Bool {
        switch credential {
        case .operatorToken, .scoped:
            return isConfigurationChange(route: route, method: method)
        case .full, .paired, .none:
            return false
        }
    }
}

/// What a held change asks for, written for the card and the log with the
/// secrets left out: the query and the JSON body, with every value that could
/// be a credential replaced by `redacted`.
///
/// What is left out: the value under any key named like a secret (`token`,
/// `secret`, `password`, `authorization`, `credential`, anything ending in
/// `key`), every value inside an `env` or `headers` object — an MCP server's
/// credentials live there — and the user, password and query of any URL.
/// Names stay, so the card still says *which* variable or header was set.
package enum ConfigChangeSummary {

    package static let redacted = "<redacted>"

    /// The summary of a request's query and body.
    package static func text(query: [String: String], body: Data) -> String {
        var parts = query.keys.sorted().map { key in
            "\(key)=\(isSecretName(key) ? redacted : cleaned(query[key] ?? ""))"
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
        if let text = value as? String { return cleaned(text) }
        return value
    }

    private static func scrubbed(_ value: Any, under key: String) -> Any {
        if isSecretName(key) { return redacted }
        if holdsSecrets(key), let object = value as? [String: Any] {
            return object.mapValues { _ in redacted as Any }
        }
        return scrubbed(value)
    }

    private static func isSecretName(_ key: String) -> Bool {
        let name = key.lowercased()
        return name.hasSuffix("key") || name.hasSuffix("token")
            || ["secret", "password", "authorization", "credential"].contains { name.contains($0) }
    }

    /// The objects whose values are credentials whatever their keys are called.
    private static func holdsSecrets(_ key: String) -> Bool {
        ["env", "headers"].contains(key.lowercased())
    }

    /// A URL without the parts that carry credentials; any other text as given.
    private static func cleaned(_ text: String) -> String {
        guard text.hasPrefix("http://") || text.hasPrefix("https://"),
              var components = URLComponents(string: text),
              components.user != nil || components.password != nil || components.query != nil else { return text }
        let hadQuery = components.query != nil
        components.user = nil
        components.password = nil
        components.query = nil
        return (components.string ?? redacted) + (hadQuery ? "?\(redacted)" : "")
    }
}
