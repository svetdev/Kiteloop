import CryptoKit
import XCTest
@testable import KiteloopCore

/// Outbound webhooks: an event goes to the webhooks that select its kind,
/// signed with each one's secret; a failed send is retried only when a retry
/// can help; every attempt is logged; the list survives its file.
final class OutboundWebhooksTests: XCTestCase {

    /// A transport that answers from a script and remembers every request.
    private final class ScriptedTransport: @unchecked Sendable {
        enum Answer { case status(Int), failure }
        struct Refused: Error {}

        private let lock = NSLock()
        private var answers: [Answer]
        private var sent: [URLRequest] = []

        init(_ answers: [Answer] = []) { self.answers = answers }

        var requests: [URLRequest] { lock.withLock { sent } }

        func send(_ request: URLRequest) throws -> (status: Int, body: Data) {
            let answer: Answer = lock.withLock {
                sent.append(request)
                return answers.isEmpty ? .status(200) : answers.removeFirst()
            }
            switch answer {
            case .status(let code): return (code, Data())
            case .failure: throw Refused()
            }
        }
    }

    private let hookURL = URL(string: "https://hooks.example.com/kiteloop")!

    private func event(_ seq: Int = 7, kind: String = "approval") -> AppEventFeed.Event {
        AppEventFeed.Event(seq: seq, project: "/tmp/p", kind: kind, subject: "item",
                           title: "item is waiting", time: Date(timeIntervalSince1970: 0))
    }

    private func dispatcher(_ webhooks: [OutboundWebhook], _ transport: ScriptedTransport,
                            maxAttempts: Int = 3, logCapacity: Int = 500) -> OutboundWebhookDispatcher {
        OutboundWebhookDispatcher(webhooks: webhooks,
                                  transport: { try transport.send($0) },
                                  sleep: { _ in },
                                  maxAttempts: maxAttempts,
                                  logCapacity: logCapacity)
    }

    // MARK: Selection and request shape

    func testASelectedKindIsPostedOnceWithTheFeedLineAndItsKind() async {
        let transport = ScriptedTransport()
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s", kinds: ["approval"])], transport)
        let event = event()

        await sut.deliver(event)

        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url, hookURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data(event.json.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiteloop-Event"), "approval")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testAnUnselectedKindIsNotSent() async {
        let transport = ScriptedTransport()
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s", kinds: ["error"])], transport)

        await sut.deliver(event(kind: "question"))

        XCTAssertTrue(transport.requests.isEmpty)
        let log = await sut.deliveries
        XCTAssertTrue(log.isEmpty)
    }

    func testAnEmptyKindsListSendsEveryKind() async {
        let transport = ScriptedTransport()
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s", kinds: [])], transport)
        let kinds = ["approval", "question", "complete", "error", "event"]

        for (n, kind) in kinds.enumerated() { await sut.deliver(event(n + 1, kind: kind)) }

        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "X-Kiteloop-Event") }, kinds)
    }

    func testTheSignatureIsTheHMACOfTheExactBodyKeyedByTheSecret() async throws {
        let transport = ScriptedTransport()
        let secret = "correct horse battery staple"
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: secret)], transport)

        await sut.deliver(event())

        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        let expected = "sha256=" + Data(mac).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiteloop-Signature"), expected)
        XCTAssertEqual(expected.count, "sha256=".count + 64)
    }

    // MARK: Retries

    func testAThrowingTransportIsTriedMaxAttemptsTimesThenStops() async {
        let transport = ScriptedTransport([.failure, .failure, .failure, .failure])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event())

        XCTAssertEqual(transport.requests.count, 3)
    }

    func testA500IsRetriedUpToMaxAttempts() async {
        let transport = ScriptedTransport([.status(500), .status(500), .status(500), .status(500)])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event())

        XCTAssertEqual(transport.requests.count, 3)
    }

    func testA500ThenA200StopsAfterThe200() async {
        let transport = ScriptedTransport([.status(500), .status(200), .status(500)])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event())

        XCTAssertEqual(transport.requests.count, 2)
    }

    func testA400IsAttemptedExactlyOnce() async {
        let transport = ScriptedTransport([.status(400), .status(200)])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event())

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testA429IsRetried() async {
        let transport = ScriptedTransport([.status(429), .status(204)])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event())

        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: Delivery log

    func testTheLogHoldsOneRecordPerAttempt() async {
        let transport = ScriptedTransport([.failure, .status(503), .status(200)])
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, maxAttempts: 3)

        await sut.deliver(event(42))

        let log = await sut.deliveries
        XCTAssertEqual(log.map(\.eventID), [42, 42, 42])
        XCTAssertEqual(log.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(log.map(\.status), [nil, 503, 200])
        XCTAssertNotNil(log[0].error)
        XCTAssertNil(log[1].error)
        XCTAssertEqual(log.map(\.host), Array(repeating: "hooks.example.com", count: 3))
    }

    func testTheLogStaysWithinItsBound() async {
        let transport = ScriptedTransport()
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport, logCapacity: 3)

        for seq in 1...5 { await sut.deliver(event(seq)) }

        let log = await sut.deliveries
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log.map(\.eventID), [3, 4, 5], "the oldest records drop first")
    }

    // MARK: Following the feed

    @MainActor
    func testRunDeliversLiveFeedEventsInOrder() async throws {
        let feed = AppEventFeed()
        let transport = ScriptedTransport()
        let sut = dispatcher([OutboundWebhook(url: hookURL, secret: "s")], transport)
        let task = Task { await sut.run(feed: feed) }
        defer { task.cancel() }
        try await eventually("the dispatcher subscribed") { await feed.subscriberCount == 1 }

        for title in ["one", "two"] {
            await feed.publish(NotificationItem(agentID: "a", type: .question, title: title, body: "b"))
        }

        try await eventually("both events delivered") { transport.requests.count == 2 }
        let ids = await sut.deliveries.map(\.eventID)
        XCTAssertEqual(ids, [1, 2])
    }

    // MARK: The file

    private let otherURL = URL(string: "https://other.example.net/x")!

    private func webhooksFile(_ json: String) throws -> URL {
        let url = try makeTemporaryDirectory(prefix: "webhooks").appending(path: "webhooks.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testAPlainSecretMovesToTheStoreAndTheFileIsRewrittenWithoutIt() throws {
        let url = try webhooksFile("""
            [{"url": "https://hooks.example.com/kiteloop", "secret": "s3cr3t-one", "kinds": ["approval", "error"]},
             {"url": "https://other.example.net/x", "secret": "s3cr3t-two", "kinds": []}]
            """)
        let store = InMemoryConnectorSecretStore()

        let loaded = OutboundWebhooks.load(from: url, secrets: store)

        XCTAssertEqual(loaded, [OutboundWebhook(url: hookURL, secret: "s3cr3t-one", kinds: ["approval", "error"]),
                                OutboundWebhook(url: otherURL, secret: "s3cr3t-two")])
        XCTAssertEqual(store.all, [OutboundWebhook(url: hookURL, secret: "").secretKey: "s3cr3t-one",
                                   OutboundWebhook(url: otherURL, secret: "").secretKey: "s3cr3t-two"])
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains("s3cr3t"), file)
        XCTAssertFalse(file.contains("\"secret\""), file)
        XCTAssertEqual(OutboundWebhooks.listed(in: url),
                       [OutboundWebhook(url: hookURL, secret: "", kinds: ["approval", "error"]),
                        OutboundWebhook(url: otherURL, secret: "")])
    }

    func testAMovedSecretIsReadBackFromTheStoreOnTheNextLoad() throws {
        let url = try webhooksFile(#"[{"url": "https://hooks.example.com/kiteloop", "secret": "s3cr3t", "kinds": []}]"#)
        let store = InMemoryConnectorSecretStore()
        _ = OutboundWebhooks.load(from: url, secrets: store)
        let rewritten = try Data(contentsOf: url)

        let loaded = OutboundWebhooks.load(from: url, secrets: store)

        XCTAssertEqual(loaded, [OutboundWebhook(url: hookURL, secret: "s3cr3t")])
        XCTAssertEqual(try Data(contentsOf: url), rewritten, "a file with nothing to move is not written again")
    }

    func testAPlainSecretWrittenLaterReplacesTheStoredOne() throws {
        let url = try webhooksFile(#"[{"url": "https://hooks.example.com/kiteloop", "secret": "new", "kinds": []}]"#)
        let store = InMemoryConnectorSecretStore([OutboundWebhook(url: hookURL, secret: "").secretKey: "old"])

        XCTAssertEqual(OutboundWebhooks.load(from: url, secrets: store), [OutboundWebhook(url: hookURL, secret: "new")])
        XCTAssertEqual(store.all.values.sorted(), ["new"])
    }

    func testAWebhookWithNoSecretAnywhereIsLeftOut() throws {
        let url = try webhooksFile("""
            [{"url": "https://hooks.example.com/kiteloop", "kinds": []},
             {"url": "https://other.example.net/x", "secret": "t", "kinds": []}]
            """)

        let loaded = OutboundWebhooks.load(from: url, secrets: InMemoryConnectorSecretStore())

        XCTAssertEqual(loaded, [OutboundWebhook(url: otherURL, secret: "t")])
        XCTAssertEqual(OutboundWebhooks.listed(in: url).map(\.url), [hookURL, otherURL], "the entry stays in the file")
    }

    /// A store that takes nothing — a keychain that refused the write.
    private final class RefusingSecretStore: ConnectorSecretStore {
        func value(for key: ConnectorSecretKey) -> String? { nil }
        func set(_ value: String, for key: ConnectorSecretKey) {}
        func delete(_ key: ConnectorSecretKey) {}
    }

    func testASecretTheStoreDidNotTakeStaysInTheFileAndStillSigns() throws {
        let url = try webhooksFile(#"[{"url": "https://hooks.example.com/kiteloop", "secret": "s3cr3t", "kinds": []}]"#)
        let before = try Data(contentsOf: url)

        let loaded = OutboundWebhooks.load(from: url, secrets: RefusingSecretStore())

        XCTAssertEqual(loaded, [OutboundWebhook(url: hookURL, secret: "s3cr3t")])
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAnEventSentAfterTheMoveIsSignedWithTheMovedSecret() async throws {
        let url = try webhooksFile(#"[{"url": "https://hooks.example.com/kiteloop", "secret": "s3cr3t", "kinds": []}]"#)
        let store = InMemoryConnectorSecretStore()
        _ = OutboundWebhooks.load(from: url, secrets: store)
        let transport = ScriptedTransport()
        let sut = dispatcher(OutboundWebhooks.load(from: url, secrets: store), transport)

        await sut.deliver(event())

        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let code = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data("s3cr3t".utf8)))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiteloop-Signature"),
                       "sha256=" + code.map { String(format: "%02x", $0) }.joined())
    }

    func testAMissingOrUnreadableFileLoadsAsEmpty() throws {
        let dir = try makeTemporaryDirectory(prefix: "webhooks")
        let store = InMemoryConnectorSecretStore()
        XCTAssertEqual(OutboundWebhooks.load(from: dir.appending(path: "absent.json"), secrets: store), [])

        let garbled = dir.appending(path: "webhooks.json")
        try Data("{not json".utf8).write(to: garbled)
        XCTAssertEqual(OutboundWebhooks.load(from: garbled, secrets: store), [])
        XCTAssertEqual(try String(contentsOf: garbled, encoding: .utf8), "{not json", "an unreadable file is left alone")
    }

    func testTheDefaultFileIsUnderKiteloopHome() {
        XCTAssertEqual(OutboundWebhooks.defaultURL,
                       KiteloopHome.url.appending(path: ".kiteloop/webhooks.json"))
    }
}
