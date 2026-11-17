import Foundation
import os
import Security

/// Which part of a connector a secret belongs to: a value in its `env`, or a
/// value in the `headers` a remote server keeps in `extras`.
package enum ConnectorSecretKind: String, Sendable {
    case env
    case header
}

/// Where one secret of one connector lives: the server, the part, the name.
package struct ConnectorSecretKey: Hashable, Sendable {
    package let server: String
    package let kind: ConnectorSecretKind
    package let name: String

    package init(server: String, kind: ConnectorSecretKind, name: String) {
        self.server = server
        self.kind = kind
        self.name = name
    }

    /// The keychain account the value is stored under.
    package var account: String { "\(server)/\(kind.rawValue)/\(name)" }
}

/// Holds the values the settings file no longer does.
package protocol ConnectorSecretStore: AnyObject, Sendable {
    func value(for key: ConnectorSecretKey) -> String?
    func set(_ value: String, for key: ConnectorSecretKey)
    func delete(_ key: ConnectorSecretKey)
}

/// The login keychain, one generic password per secret.
package final class KeychainConnectorSecretStore: ConnectorSecretStore {
    package static let service = "ai.kiteloop.connector"

    package init() {}

    private func query(_ key: ConnectorSecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: key.account]
    }

    package func value(for key: ConnectorSecretKey) -> String? {
        var lookup = query(key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package func set(_ value: String, for key: ConnectorSecretKey) {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query(key) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return }
        var item = query(key)
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    package func delete(_ key: ConnectorSecretKey) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// A store that forgets on exit — what a test hands the code under test.
package final class InMemoryConnectorSecretStore: ConnectorSecretStore {
    private let values: OSAllocatedUnfairLock<[ConnectorSecretKey: String]>

    package init(_ values: [ConnectorSecretKey: String] = [:]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    package var all: [ConnectorSecretKey: String] { values.withLock { $0 } }

    package func value(for key: ConnectorSecretKey) -> String? { values.withLock { $0[key] } }
    package func set(_ value: String, for key: ConnectorSecretKey) { values.withLock { $0[key] = value } }
    package func delete(_ key: ConnectorSecretKey) { _ = values.withLock { $0.removeValue(forKey: key) } }
}

/// Moves connector secrets between the servers as written to the settings
/// file — every name kept, every value "" — and the store holding the values.
/// `command`, `args` and every other `extras` key pass through untouched.
package enum ConnectorSecrets {
    /// The servers with every env value and every string header value set to
    /// "", and the non-empty values taken out.
    package static func separatingSecrets(
        _ servers: [String: ClaudeMCPServerEntry]
    ) -> (servers: [String: ClaudeMCPServerEntry], secrets: [ConnectorSecretKey: String]) {
        var secrets: [ConnectorSecretKey: String] = [:]
        let stripped = servers.reduce(into: [String: ClaudeMCPServerEntry]()) { result, pair in
            result[pair.key] = rewriting(pair.value, server: pair.key) { key, value in
                if !value.isEmpty { secrets[key] = value }
                return ""
            }
        }
        return (stripped, secrets)
    }

    /// The servers with each value filled in from the store; a name the store
    /// holds nothing for stays "".
    package static func resolvingSecrets(
        _ servers: [String: ClaudeMCPServerEntry],
        from store: ConnectorSecretStore
    ) -> [String: ClaudeMCPServerEntry] {
        servers.reduce(into: [String: ClaudeMCPServerEntry]()) { result, pair in
            result[pair.key] = rewriting(pair.value, server: pair.key) { key, _ in
                store.value(for: key) ?? ""
            }
        }
    }

    /// Every secret name the servers carry, whatever its value.
    package static func secretKeys(in servers: [String: ClaudeMCPServerEntry]) -> Set<ConnectorSecretKey> {
        var keys: Set<ConnectorSecretKey> = []
        for (name, entry) in servers {
            _ = rewriting(entry, server: name) { key, value in
                keys.insert(key)
                return value
            }
        }
        return keys
    }

    /// Writes the incoming servers' secrets to the store and returns the
    /// servers to save. A non-empty value replaces the stored one; a blank one
    /// keeps it; a server or name that `previous` had and `incoming` lacks has
    /// its secret deleted.
    package static func storing(
        _ incoming: [String: ClaudeMCPServerEntry],
        replacing previous: [String: ClaudeMCPServerEntry],
        in store: ConnectorSecretStore
    ) -> [String: ClaudeMCPServerEntry] {
        let separated = separatingSecrets(incoming)
        for key in secretKeys(in: previous).subtracting(secretKeys(in: incoming)) {
            store.delete(key)
        }
        for (key, value) in separated.secrets {
            store.set(value, for: key)
        }
        return separated.servers
    }

    /// Whether any server still holds a value in plain text.
    package static func holdsSecrets(_ servers: [String: ClaudeMCPServerEntry]) -> Bool {
        !separatingSecrets(servers).secrets.isEmpty
    }

    private static func rewriting(
        _ entry: ClaudeMCPServerEntry,
        server: String,
        _ transform: (ConnectorSecretKey, String) -> String
    ) -> ClaudeMCPServerEntry {
        var entry = entry
        if let env = entry.env {
            entry.env = Dictionary(uniqueKeysWithValues: env.map { name, value in
                (name, transform(ConnectorSecretKey(server: server, kind: .env, name: name), value))
            })
        }
        if case .dictionary(let headers)? = entry.extras["headers"] {
            entry.extras["headers"] = .dictionary(Dictionary(uniqueKeysWithValues: headers.map { name, value in
                guard case .string(let text) = value else { return (name, value) }
                let key = ConnectorSecretKey(server: server, kind: .header, name: name)
                return (name, AnyCodable.string(transform(key, text)))
            }))
        }
        return entry
    }
}
