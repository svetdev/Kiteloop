import Foundation
import Observation
import Security

/// One Mac the phone has paired with: what to call it, where it is, and which
/// keychain entry holds its token. The token itself never sits in defaults.
struct SavedMac: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    /// The keychain account holding this Mac's token. The Mac paired before
    /// the phone knew more than one keeps the original "controlToken".
    var tokenAccount: String
}

/// Where each Mac is and how to be believed: the saved Macs (defaults — an
/// address is not a secret), each one's bearer token (keychain), and which is
/// current. `baseURL` and `token` are the current Mac's, so every screen reads
/// one connection; `configured` gates the whole UI: no connection, no tabs.
@Observable
final class ConnectionStore {
    /// Injectable so a test can drive a refusal without touching the device
    /// keychain; defaults to the real write.
    var tokenWriter: (String, String) -> OSStatus = Keychain.write
    var tokenReader: (String) -> String?
    var tokenDeleter: (String) -> Void = Keychain.delete
    /// Set when `tokenWriter` refuses the write, so the screen that just set
    /// the token can say so instead of looking paired until the next launch.
    var tokenStoreProblem: String?

    private(set) var macs: [SavedMac] = []
    private(set) var currentID: String?
    /// True while `baseURL`/`token` are being loaded from a saved Mac, so
    /// their observers do not write back what was just read.
    private var loading = false
    private let defaults: UserDefaults

    static let macsKey = "savedMacs"
    static let currentKey = "currentMac"
    static let legacyURLKey = "controlBaseURL"
    static let legacyTokenAccount = "controlToken"

    var baseURL: String {
        didSet {
            guard !loading else { return }
            updateCurrent { $0.baseURL = baseURL }
        }
    }
    var token: String {
        didSet {
            guard !loading else { return }
            let status = tokenWriter(ensureCurrent().tokenAccount, token)
            tokenStoreProblem = status == errSecSuccess
                ? nil
                : "Could not save the token to the keychain (status \(status))."
        }
    }

    init(defaults: UserDefaults = .standard, tokenReader: @escaping (String) -> String? = Keychain.read) {
        self.defaults = defaults
        self.tokenReader = tokenReader
        baseURL = ""
        token = ""
        loading = true
        defer { loading = false }
        macs = Self.loadMacs(from: defaults)
        currentID = defaults.string(forKey: Self.currentKey) ?? macs.first?.id
        if let current {
            baseURL = current.baseURL
            token = tokenReader(current.tokenAccount) ?? ""
        }
        // A launch-environment connection is for development drives
        // (simulator, UI tests) — it is never saved.
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["KITELOOP_BASE_URL"] { baseURL = url }
        if let envToken = environment["KITELOOP_TOKEN"] { token = envToken }
    }

    var configured: Bool { !baseURL.isEmpty && !token.isEmpty }
    var current: SavedMac? { macs.first { $0.id == currentID } }

    /// Saves a Mac from a pairing code or typed by hand, and makes it current.
    /// The same address again updates that Mac's token rather than adding a
    /// second entry for it.
    func pair(baseURL url: String, token newToken: String, name: String? = nil) {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        if let existing = macs.first(where: { Self.normalize($0.baseURL) == Self.normalize(url) }) {
            select(existing.id)
            if let name { updateCurrent { $0.name = name } }
        } else {
            let id = UUID().uuidString
            macs.append(SavedMac(id: id, name: name ?? Self.defaultName(for: url), baseURL: url,
                                 tokenAccount: "\(Self.legacyTokenAccount).\(id)"))
            currentID = id
            save()
            loading = true
            baseURL = url
            loading = false
        }
        token = newToken
    }

    /// Makes a saved Mac current: its address and token become the connection.
    func select(_ id: String) {
        guard let mac = macs.first(where: { $0.id == id }) else { return }
        currentID = id
        save()
        loading = true
        defer { loading = false }
        baseURL = mac.baseURL
        token = tokenReader(mac.tokenAccount) ?? ""
    }

    /// Forgets a Mac and its token. Removing the current one moves to the
    /// next saved Mac, or leaves the phone unpaired.
    func remove(_ id: String) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        let removed = macs.remove(at: index)
        tokenDeleter(removed.tokenAccount)
        guard currentID == id else { return save() }
        currentID = nil
        if let next = macs.first { return select(next.id) }
        save()
        loading = true
        baseURL = ""
        token = ""
        loading = false
    }

    /// The name a Mac gets when its pairing code carries none: its host.
    static func defaultName(for url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }

    static func normalize(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// The saved Macs, or — on a phone paired before there could be more than
    /// one — the single address it kept, as the first entry.
    private static func loadMacs(from defaults: UserDefaults) -> [SavedMac] {
        if let data = defaults.data(forKey: macsKey),
           let saved = try? JSONDecoder().decode([SavedMac].self, from: data) {
            return saved
        }
        guard let legacy = defaults.string(forKey: legacyURLKey), !legacy.isEmpty else { return [] }
        return [SavedMac(id: "legacy", name: defaultName(for: legacy), baseURL: legacy,
                         tokenAccount: legacyTokenAccount)]
    }

    /// The current Mac, creating one for a connection typed before any was
    /// saved — the first `baseURL`/`token` assignment on a fresh phone.
    @discardableResult
    private func ensureCurrent() -> SavedMac {
        if let current { return current }
        let id = UUID().uuidString
        let mac = SavedMac(id: id, name: Self.defaultName(for: baseURL), baseURL: baseURL,
                           tokenAccount: "\(Self.legacyTokenAccount).\(id)")
        macs.append(mac)
        currentID = id
        save()
        return mac
    }

    private func updateCurrent(_ change: (inout SavedMac) -> Void) {
        ensureCurrent()
        guard let index = macs.firstIndex(where: { $0.id == currentID }) else { return }
        change(&macs[index])
        if macs[index].name.isEmpty { macs[index].name = Self.defaultName(for: macs[index].baseURL) }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(macs), forKey: Self.macsKey)
        defaults.set(currentID, forKey: Self.currentKey)
    }
}
