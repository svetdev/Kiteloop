import CryptoKit
import Foundation

/// The APNs key the Mac signs pushes with: the `.p8` file, its
/// key id, and the team it belongs to. Set once in Settings → Control API;
/// with none, nothing is pushed.
package struct PushKeyConfig: Codable, Sendable, Equatable {
    package var keyPath: String
    package var keyID: String
    package var teamID: String

    package init(keyPath: String, keyID: String, teamID: String) {
        self.keyPath = keyPath
        self.keyID = keyID
        self.teamID = teamID
    }

    package var isComplete: Bool {
        ![keyPath, keyID, teamID].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Apple's push service, spoken directly from the Mac: no server of ours in
/// between. A request is a JWT signed with the team's key (ES256) and a JSON
/// payload, POSTed over HTTP/2 to the device's token.
package enum APNs {

    /// The phone app's bundle id: what every push is addressed to.
    package static let topic = "ai.kasatkin.kiteloop.mobile"

    /// Which push service a device's token belongs to: a build run from Xcode
    /// talks to the sandbox, a TestFlight or App Store build to production.
    package enum Environment: String, Codable, Sendable {
        case sandbox, production

        package var host: String {
            switch self {
            case .sandbox: "api.sandbox.push.apple.com"
            case .production: "api.push.apple.com"
            }
        }
    }

    package enum KeyError: Error, Equatable {
        case unreadable(String)
        case notAKey(String)
    }

    /// The provider token: `header.claims.signature`, base64url, signed ES256
    /// with the `.p8` key. Apple accepts one for an hour and asks it be
    /// refreshed no more than every twenty minutes, so callers keep one.
    package static func token(pem: String, keyID: String, teamID: String, issuedAt: Date) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw KeyError.notAKey("the key file is not an ES256 private key (.p8)")
        }
        let header = base64URL(json(["alg": "ES256", "kid": keyID]))
        let claims = base64URL(json(["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)]))
        let signingInput = "\(header).\(claims)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    /// The `.p8` file's text, or why it cannot be read.
    package static func readKey(at path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw KeyError.unreadable("no readable key file at \(path)")
        }
        return pem
    }

    /// The POST for one device; nil for a token no URL can carry.
    package static func request(device: String, environment: Environment, providerToken: String,
                                payload: Data) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = environment.host
        components.path = "/3/device/\(device)"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(providerToken)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        return request
    }

    /// The POST that moves a Live Activity on, addressed to the activity's own
    /// push token: a different push type, and a topic of its own.
    package static func liveActivityRequest(token: String, environment: Environment, providerToken: String,
                                            payload: Data) -> URLRequest? {
        guard var request = request(device: token, environment: environment, providerToken: providerToken,
                                    payload: payload) else { return nil }
        request.setValue("\(topic).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        return request
    }

    /// A Live Activity's new state — `AgentActivityAttributes.ContentState` on
    /// the phone: `working`, the one-line `status`, the agent's `line` — or
    /// its end, which the lock screen keeps for a while before dismissing.
    package static func liveActivityPayload(working: Bool, status: String, line: String, ends: Bool,
                                            at date: Date) -> Data {
        var aps: [String: Any] = [
            "timestamp": Int(date.timeIntervalSince1970),
            "event": ends ? "end" : "update",
            "content-state": ["working": working, "status": status, "line": line],
        ]
        if ends { aps["dismissal-date"] = Int(date.addingTimeInterval(15 * 60).timeIntervalSince1970) }
        return json(["aps": aps])
    }

    /// An alert with what the phone needs to open the right screen beside it:
    /// `kind` (`question`, `approval`, `finished`), `project`, `agent`, `item`.
    package static func payload(title: String, body: String, info: [String: String]) -> Data {
        var object: [String: Any] = ["aps": ["alert": ["title": title, "body": body], "sound": "default"]]
        for (key, value) in info { object[key] = value }
        return json(object)
    }

    /// Whether the push service said this token will never work again — the
    /// app was deleted, or the token belongs to the other environment — so the
    /// device should be forgotten rather than tried on every notice.
    package static func isDeadToken(status: Int, body: Data) -> Bool {
        if status == 410 { return true }
        guard status == 400,
              let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String else {
            return false
        }
        return reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic"
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    package static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
