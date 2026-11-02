import CryptoKit
import Foundation

/// A phone paired with this Mac, with a token of its own, so losing one phone
/// means revoking that phone — not regenerating the token every other client
/// holds. Only the token's SHA-256 is kept; the token itself goes into the
/// pairing code once and lives on the phone.
package struct ControlDevice: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package var name: String
    package let tokenHash: String
    package let pairedAt: Date
    /// When the phone last made a request, since the app started; not saved.
    package var lastUsedAt: Date?

    private enum CodingKeys: String, CodingKey { case id, name, tokenHash, pairedAt }
}

/// The paired phones, in `~/.kiteloop/control-devices.json`, readable by this
/// user only. Used on the control server's actor: the check runs on every
/// request, so it reads memory and writes the file only when a phone is
/// paired, renamed or revoked.
package final class ControlDeviceTokens {
    private let url: URL
    private(set) package var devices: [ControlDevice]
    /// The hashes of the pairing codes on offer. Memory only: a code lives as
    /// long as the sheet showing it, so a relaunch forgets every one.
    private var offers: Set<String> = []

    package init(url: URL) {
        self.url = url
        devices = PrivateJSONFile.load([ControlDevice].self, from: url) ?? []
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/control-devices.json")
    }

    /// A new phone: its token, to put in the pairing code, and its entry.
    package func pair(name: String, at date: Date = .now) -> (token: String, device: ControlDevice) {
        let token = Self.randomHex()
        let device = ControlDevice(id: UUID(), name: name, tokenHash: Self.hash(token), pairedAt: date)
        devices.append(device)
        save()
        return (token, device)
    }

    /// A pairing code to show in the QR: it pairs one phone, once, until it
    /// is claimed or withdrawn. Nothing is paired until a phone claims it.
    package func offer() -> String {
        let code = Self.randomHex()
        offers.insert(Self.hash(code))
        return code
    }

    /// Trades a code on offer for a newly paired phone and its token, using
    /// the code up; nil for a code that is not on offer — never offered,
    /// claimed already or withdrawn.
    package func claim(code: String, name: String, at date: Date = .now) -> (token: String, device: ControlDevice)? {
        guard offers.remove(Self.hash(code)) != nil else { return nil }
        return pair(name: name, at: date)
    }

    /// Takes a code off offer, as closing the sheet that shows it does.
    package func withdraw(code: String) {
        offers.remove(Self.hash(code))
    }

    /// The phone `token` belongs to, marked as just used; nil for a token no
    /// paired phone holds, a revoked one included.
    package func device(for token: String, at date: Date = .now) -> ControlDevice? {
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return nil }
        devices[index].lastUsedAt = date
        return devices[index]
    }

    package func rename(_ id: UUID, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].name != name, !name.isEmpty else { return }
        devices[index].name = name
        save()
    }

    package func revoke(_ id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    private static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    package static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        PrivateJSONFile.save(devices, to: url)
    }
}
