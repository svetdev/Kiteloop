import Foundation

/// Hides what looks like a credential in a command line or a URL before it is
/// shown — on a configuration-change card and its log, in a pack's inspection,
/// in the MCP server listing.
///
/// Best effort, and it does not claim more: it knows a secret by the name
/// beside it — `--token=…`, `--api-key …`, `API_KEY=…`, `?access_token=…` — or
/// by its place — after `Bearer`, before the `@` of a URL. A secret passed
/// bare, under a name that says nothing, or inside a path is shown as written.
/// A connector's secrets belong in its `env` or `headers`, whose values are
/// never shown at all and are kept in the keychain (`ConnectorSecrets`).
package enum SecretRedaction {

    /// What a hidden value is replaced with.
    package static let marker = "<redacted>"

    /// Whether a field, variable, flag or query key is named like a secret.
    /// The one rule for that: `ConfigChangeSummary` reads it for a JSON key,
    /// and everything below for a name in a command line or a URL.
    package static func isSecretName(_ key: String) -> Bool {
        let name = key.lowercased()
        return name.hasSuffix("key") || name.hasSuffix("token")
            || ["secret", "password", "authorization", "credential"].contains { name.contains($0) }
    }

    /// The arguments of a command line, one element each, secrets replaced.
    /// The argument after a secret-named flag is replaced whole.
    package static func commandLine(_ arguments: [String]) -> [String] {
        scan(arguments, each: text)
    }

    /// A command line, or part of one, written as a single string.
    package static func text(_ text: String) -> String {
        scan(text.components(separatedBy: " "), each: word).joined(separator: " ")
    }

    /// A string that is a URL, with the user and password before its `@` and
    /// the value of each secret-named query key replaced; any other string as
    /// given.
    package static func url(_ text: String) -> String {
        guard let scheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) else {
            return text
        }
        let rest = text[scheme.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        var authority = String(rest[..<authorityEnd])
        if let at = authority.lastIndex(of: "@") { authority = marker + authority[at...] }
        return text[scheme] + authority + queryRedacted(rest[authorityEnd...])
    }

    // MARK: - A command line

    /// Each token through `each`, except the one a secret-named flag or
    /// `Bearer` announces, which is replaced. A token starting with `-` is
    /// the next flag, not a value.
    private static func scan(_ tokens: [String], each: (String) -> String) -> [String] {
        var expectsSecret = false
        return tokens.map { token in
            guard !token.isEmpty else { return token }
            let isValue = expectsSecret && !token.hasPrefix("-")
            expectsSecret = announcesSecret(token)
            return isValue ? marker : each(token)
        }
    }

    /// Whether the token after this one is a secret: `--token`, `-api-key`,
    /// `Bearer`.
    private static func announcesSecret(_ token: String) -> Bool {
        if token.lowercased() == "bearer" { return true }
        guard token.hasPrefix("-"), let name = assignedName(token[...]) else { return false }
        return isSecretName(name)
    }

    /// One token with no space in it: `NAME=value` or `--name=value` loses
    /// its value when the name is a secret's; otherwise the value, or the
    /// whole token, is read as a URL.
    private static func word(_ token: String) -> String {
        guard let equals = token.firstIndex(of: "="), let name = assignedName(token[..<equals]) else {
            return url(token)
        }
        let value = String(token[token.index(after: equals)...])
        guard !value.isEmpty else { return token }
        return token[...equals] + (isSecretName(name) ? marker : url(value))
    }

    /// The name a flag or an assignment is made to — leading dashes dropped —
    /// or nil when what stands there is not a name (a URL, a path).
    private static func assignedName(_ prefix: Substring) -> String? {
        let name = prefix.drop { $0 == "-" }
        let isName = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
        return isName ? String(name) : nil
    }

    // MARK: - A URL

    /// The path, query and fragment of a URL with each secret-named query
    /// value replaced.
    private static func queryRedacted(_ tail: Substring) -> String {
        let fragmentStart = tail.firstIndex(of: "#") ?? tail.endIndex
        let beforeFragment = tail[..<fragmentStart]
        guard let mark = beforeFragment.firstIndex(of: "?") else { return String(tail) }
        let items = beforeFragment[beforeFragment.index(after: mark)...]
            .split(separator: "&", omittingEmptySubsequences: false)
            .map(queryItemRedacted)
        return tail[...mark] + items.joined(separator: "&") + tail[fragmentStart...]
    }

    private static func queryItemRedacted(_ item: Substring) -> String {
        guard let equals = item.firstIndex(of: "="), isSecretName(String(item[..<equals])),
              item.index(after: equals) != item.endIndex else { return String(item) }
        return item[...equals] + marker
    }
}

extension ClaudeMCPServerEntry {
    /// `displaySummary` for showing to someone who should not see the entry's
    /// credentials: the command line or endpoint through `SecretRedaction`.
    package var redactedSummary: String {
        guard let command else { return SecretRedaction.text(displaySummary) }
        return ([SecretRedaction.text(command)] + SecretRedaction.commandLine(args ?? [])).joined(separator: " ")
    }
}
