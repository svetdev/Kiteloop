import CryptoKit
import Foundation

/// An address Kiteloop posts its events to: every `AppEventFeed` event whose
/// kind is in `kinds` — all of them when `kinds` is empty — is POSTed to `url`,
/// signed with `secret`.
package struct OutboundWebhook: Codable, Equatable, Sendable {
    package let url: URL
    /// The signing key. Empty for an entry as the file keeps it once the key
    /// has moved to the secret store.
    package let secret: String
    /// `NotificationItem.NotificationType` raw values: approval, question,
    /// complete, error, event. Empty selects every kind.
    package let kinds: [String]

    package init(url: URL, secret: String, kinds: [String] = []) {
        self.url = url
        self.secret = secret
        self.kinds = kinds
    }

    private enum CodingKeys: String, CodingKey { case url, secret, kinds }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        secret = try container.decodeIfPresent(String.self, forKey: .secret) ?? ""
        kinds = try container.decode([String].self, forKey: .kinds)
    }

    /// An entry with no secret is written without the key.
    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        if !secret.isEmpty { try container.encode(secret, forKey: .secret) }
        try container.encode(kinds, forKey: .kinds)
    }

    package func selects(kind: String) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }

    /// Where this webhook's secret is kept: under its URL.
    package var secretKey: ConnectorSecretKey {
        ConnectorSecretKey(server: url.absoluteString, kind: .webhook, name: "secret")
    }

    fileprivate func with(secret: String) -> OutboundWebhook {
        OutboundWebhook(url: url, secret: secret, kinds: kinds)
    }
}

/// The outbound webhooks, in `~/.kiteloop/webhooks.json`, readable by this
/// user only and edited by hand; read once at launch. The file lists each
/// webhook's `url` and `kinds`; its secret is in the secret store.
package enum OutboundWebhooks {
    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/webhooks.json")
    }

    /// The webhooks to deliver to, each with its secret.
    ///
    /// A `secret` written in the file is how a person sets or replaces one: it
    /// moves to `secrets` and the file is written again without it — the way a
    /// connector's plain values are moved (`ConnectorSecrets`). It stays in
    /// the file only if the store did not take it. A webhook with no secret in
    /// either place is left out: nothing is posted unsigned.
    package static func load(from url: URL, secrets: ConnectorSecretStore) -> [OutboundWebhook] {
        let written = listed(in: url)
        let kept = written.map { moving($0, into: secrets) }
        if kept != written { save(kept, to: url) }
        return kept.compactMap { webhook in
            let secret = webhook.secret.isEmpty ? secrets.value(for: webhook.secretKey) ?? "" : webhook.secret
            return secret.isEmpty ? nil : webhook.with(secret: secret)
        }
    }

    /// The entries as the file has them; empty when it is missing or unreadable.
    package static func listed(in url: URL) -> [OutboundWebhook] {
        PrivateJSONFile.load([OutboundWebhook].self, from: url) ?? []
    }

    package static func save(_ webhooks: [OutboundWebhook], to url: URL) {
        PrivateJSONFile.save(webhooks, to: url)
    }

    /// The entry as the file should keep it: without its secret once the
    /// store holds it, unchanged when the store did not take it.
    private static func moving(_ webhook: OutboundWebhook, into secrets: ConnectorSecretStore) -> OutboundWebhook {
        guard !webhook.secret.isEmpty else { return webhook }
        secrets.set(webhook.secret, for: webhook.secretKey)
        guard secrets.value(for: webhook.secretKey) == webhook.secret else { return webhook }
        return webhook.with(secret: "")
    }

    /// `sha256=` and the hex HMAC-SHA256 of `body` keyed by `secret`.
    package static func signature(body: Data, secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
    }
}

/// Posts each event of an `AppEventFeed` to every webhook that selects its
/// kind, retrying a failed send with backoff and logging every attempt in
/// memory.
package actor OutboundWebhookDispatcher {
    package typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)
    package typealias Sleep = @Sendable (Duration) async -> Void

    /// One attempt to deliver one event to one webhook.
    package struct Attempt: Sendable, Equatable {
        package let host: String
        package let eventID: Int
        package let attempt: Int
        /// The HTTP status answered; nil when the send threw.
        package let status: Int?
        /// What the send threw; nil when it was answered.
        package let error: String?
        package let time: Date
    }

    private let webhooks: [OutboundWebhook]
    private let transport: Transport
    private let sleep: Sleep
    package let maxAttempts: Int
    package let logCapacity: Int
    private var log: [Attempt] = []

    package init(webhooks: [OutboundWebhook],
                 transport: @escaping Transport,
                 sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
                 maxAttempts: Int = 3,
                 logCapacity: Int = 500) {
        self.webhooks = webhooks
        self.transport = transport
        self.sleep = sleep
        self.maxAttempts = max(1, maxAttempts)
        self.logCapacity = max(1, logCapacity)
    }

    /// Every attempt still held, oldest first.
    package var deliveries: [Attempt] { log }

    /// Delivers each live event of `feed`, in order, until the task is cancelled.
    package func run(feed: AppEventFeed) async {
        let (_, live) = await feed.subscribe(after: nil)
        for await event in live {
            await deliver(event)
        }
    }

    /// Sends `event` to every webhook that selects its kind.
    package func deliver(_ event: AppEventFeed.Event) async {
        let body = Data(event.json.utf8)
        for webhook in webhooks where webhook.selects(kind: event.kind) {
            await send(body, of: event, to: webhook)
        }
    }

    private func send(_ body: Data, of event: AppEventFeed.Event, to webhook: OutboundWebhook) async {
        let request = Self.request(body: body, kind: event.kind, to: webhook)
        for attempt in 1...maxAttempts {
            let status = await attemptOnce(request, eventID: event.seq, attempt: attempt)
            guard Self.isRetryable(status), attempt < maxAttempts else { return }
            await sleep(.seconds(1 << (attempt - 1)))
        }
    }

    private func attemptOnce(_ request: URLRequest, eventID: Int, attempt: Int) async -> Int? {
        var status: Int?
        var failure: String?
        do {
            status = try await transport(request).status
        } catch {
            failure = String(describing: error)
        }
        record(Attempt(host: request.url?.host() ?? "", eventID: eventID, attempt: attempt,
                       status: status, error: failure, time: .now))
        return status
    }

    private func record(_ attempt: Attempt) {
        log.append(attempt)
        if log.count > logCapacity { log.removeFirst(log.count - logCapacity) }
    }

    /// A thrown send (nil), a 5xx or a 429 is worth another try; a 2xx is
    /// delivered and any other answer will not change on a retry.
    package static func isRetryable(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status == 429 || (500...599).contains(status)
    }

    package static func request(body: Data, kind: String, to webhook: OutboundWebhook) -> URLRequest {
        var request = URLRequest(url: webhook.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(kind, forHTTPHeaderField: "X-Kiteloop-Event")
        request.setValue(OutboundWebhooks.signature(body: body, secret: webhook.secret),
                         forHTTPHeaderField: "X-Kiteloop-Signature")
        return request
    }
}
