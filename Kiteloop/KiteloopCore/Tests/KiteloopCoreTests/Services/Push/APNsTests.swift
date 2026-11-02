import CryptoKit
import XCTest
@testable import KiteloopCore

/// A push the way Apple's service takes one: a provider token that verifies
/// against the key it claims, a request addressed to the phone app, and the
/// replies that mean a device is gone for good. No network.
final class APNsTests: XCTestCase {

    private let key = P256.Signing.PrivateKey()

    func testTheProviderTokenVerifiesAgainstTheKeyAndNamesKeyAndTeam() throws {
        let token = try APNs.token(pem: key.pemRepresentation, keyID: "ABC123DEFG", teamID: "TEAM123456",
                                   issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let header = try XCTUnwrap(decode(parts[0]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABC123DEFG")
        let claims = try XCTUnwrap(decode(parts[1]))
        XCTAssertEqual(claims["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(data(parts[2])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testAFileThatIsNotAKeyIsRefused() {
        XCTAssertThrowsError(try APNs.token(pem: "not a key", keyID: "k", teamID: "t", issuedAt: .now)) { error in
            guard case APNs.KeyError.notAKey = error else { return XCTFail("\(error)") }
        }
    }

    func testTheRequestIsAddressedToThePhoneAppOnItsEnvironment() throws {
        let request = try XCTUnwrap(APNs.request(device: "abcd", environment: .sandbox, providerToken: "jwt",
                                                 payload: Data("{}".utf8)))

        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/abcd")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "bearer jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "ai.kasatkin.kiteloop.mobile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(APNs.request(device: "x", environment: .production, providerToken: "j", payload: Data())?.url?.host,
                       "api.push.apple.com")
    }

    func testThePayloadCarriesTheAlertAndWhereToOpen() throws {
        let payload = APNs.payload(title: "Builder is asking you", body: "Keep it?",
                                   info: ["kind": "question", "project": "alpha", "agent": "b1"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])

        let alert = (object["aps"] as? [String: Any])?["alert"] as? [String: Any]
        XCTAssertEqual(alert?["title"] as? String, "Builder is asking you")
        XCTAssertEqual(object["kind"] as? String, "question")
        XCTAssertEqual(object["agent"] as? String, "b1")
    }

    func testALiveActivityUpdateGoesToItsOwnTopicAndType() throws {
        let request = try XCTUnwrap(APNs.liveActivityRequest(token: "beef", environment: .production,
                                                             providerToken: "jwt", payload: Data()))

        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "ai.kasatkin.kiteloop.mobile.push-type.liveactivity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "liveactivity")
        XCTAssertEqual(request.url?.lastPathComponent, "beef")
    }

    func testALiveActivityPayloadCarriesTheStateAndEndsWithADismissal() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let update = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: APNs.liveActivityPayload(working: true, status: "Working", line: "Editing refund.ts", ends: false, at: at))
            as? [String: Any])["aps"] as? [String: Any]
        XCTAssertEqual(update?["event"] as? String, "update")
        XCTAssertEqual(update?["timestamp"] as? Int, 1_800_000_000)
        XCTAssertEqual((update?["content-state"] as? [String: Any])?["line"] as? String, "Editing refund.ts")
        XCTAssertNil(update?["dismissal-date"])

        let end = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: APNs.liveActivityPayload(working: false, status: "Done", line: "", ends: true, at: at))
            as? [String: Any])["aps"] as? [String: Any]
        XCTAssertEqual(end?["event"] as? String, "end")
        XCTAssertEqual(end?["dismissal-date"] as? Int, 1_800_000_000 + 15 * 60)
    }

    func testA410OrABadTokenMeansTheDeviceIsGone() {
        XCTAssertTrue(APNs.isDeadToken(status: 410, body: Data()))
        XCTAssertTrue(APNs.isDeadToken(status: 400, body: Data(#"{"reason":"BadDeviceToken"}"#.utf8)))
        XCTAssertFalse(APNs.isDeadToken(status: 400, body: Data(#"{"reason":"PayloadTooLarge"}"#.utf8)))
        XCTAssertFalse(APNs.isDeadToken(status: 429, body: Data()))
        XCTAssertFalse(APNs.isDeadToken(status: 200, body: Data()))
    }

    private func data(_ base64URL: String) -> Data? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    private func decode(_ part: String) -> [String: Any]? {
        data(part).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
