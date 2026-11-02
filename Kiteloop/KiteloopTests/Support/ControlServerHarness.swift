import Foundation
import XCTest
@testable import Kiteloop

/// A `KiteloopControlServer` listening on a free loopback port, and the client
/// that talks to it.
///
/// Every control-server test used to carry its own copy of this: the random
/// port probe (31 copies, each with the same `XCTSkip` string), `isListening`
/// (30), the proxy-free `URLSession` (31) and the `get`/`post` helpers (22 and
/// 17). They were identical in intent and drifted in detail. This is the one
/// copy; a test constructs the server it wants through `make` — the
/// `runRecords:`, `queueRefill:` and `metricStore:` variants all go through the
/// same closure — and gets back the port it actually bound.
@MainActor
final class ControlServerHarness {
    let server: KiteloopControlServer
    let port: UInt16
    let token: String
    let session: URLSession

    private init(server: KiteloopControlServer, port: UInt16, token: String, session: URLSession) {
        self.server = server
        self.port = port
        self.token = token
        self.session = session
    }

    /// Ports a harness in this process is still listening on. `start` never
    /// draws one of these: a test that holds two servers at once — the
    /// "restart" tests over `RunRecordStore` do, by design, since a second
    /// server over the same file is what a restart actually is — could
    /// otherwise draw the same random port for its second harness while the
    /// first is still live. `HTTPServer` sets `allowLocalEndpointReuse` (so the
    /// app's own control server can rebind instantly from a Settings toggle),
    /// so that bind does not fail — it succeeds, and the two servers end up
    /// sharing one port with no way for a caller to say which one answers a
    /// given request. `server.isRunning`, checked below, only rules out a
    /// *foreign* process's server answering before ours is ready; it says
    /// nothing once both listeners are genuinely ready on the same port.
    private static var claimedPorts: Set<UInt16> = []

    /// Starts a server on a free loopback port. `NWListener` reports a bind
    /// conflict asynchronously rather than throwing from `start()`, so the port
    /// is picked at random in the dynamic range, started, and probed; a port
    /// that never answers is stopped and the next candidate tried. Ten misses
    /// throws `XCTSkip` — the skip string is the one the suite record has always
    /// carried for this, so `docs/suite-status.md` keeps reading the same.
    static func start(
        token: String = "control-token-" + UUID().uuidString,
        make: (_ token: String) -> KiteloopControlServer
    ) async throws -> ControlServerHarness {
        let session = Self.loopbackSession()
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49_152...65_000)
            guard !claimedPorts.contains(candidate) else { continue }
            let server = make(token)
            server.start(port: candidate)
            if await Self.isListening(server: server, port: candidate, session: session) {
                claimedPorts.insert(candidate)
                return ControlServerHarness(server: server, port: candidate, token: token, session: session)
            }
            server.stop()
        }
        throw XCTSkip("No free loopback port for the control server")
    }

    /// The common case: a server over a fresh registry with nothing attached.
    static func start(
        registry: ControlSessionRegistry = ControlSessionRegistry(),
        token: String = "control-token-" + UUID().uuidString
    ) async throws -> ControlServerHarness {
        try await start(token: token) { KiteloopControlServer(registry: registry, token: $0) }
    }

    func stop() {
        server.stop()
        Self.claimedPorts.remove(port)
    }

    // MARK: Client

    /// An ephemeral session that never routes loopback through a proxy and
    /// never answers from a cache — both have produced a wrong status before.
    static func loopbackSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }

    /// Whether `server`'s own listener is bound on `port` and answering
    /// `/health`, polling for up to ~2 s.
    ///
    /// `allowLocalEndpointReuse` (set for every `HTTPServer`, so the app's own
    /// control server can rebind its port instantly from a Settings toggle)
    /// means the random candidate here can occasionally already belong to some
    /// other still-live control server — another test's harness, in a parallel
    /// suite run sharing this machine's loopback port space. A plain `/health`
    /// probe cannot tell those two apart: an unauthenticated 200 from the
    /// *other* server reads exactly like one from ours, and a test built on
    /// that false positive goes on to address every later request at a
    /// stranger's registry — a run id both happen to use (`run-1` is the
    /// suite's common placeholder) then answers from whichever process actually
    /// holds the port. `server.isRunning` is this instance's own listener state
    /// — true only once *its* bind reached `.ready` — so checking it first
    /// rules out that confusion before the network round trip ever runs.
    static func isListening(server: KiteloopControlServer, port: UInt16, session: URLSession) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<20 {
            if server.isRunning {
                var probe = URLRequest(url: url)
                probe.timeoutInterval = 2
                if let (_, response) = try? await session.data(for: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// How long a request may take before the client gives up. Ten seconds
    /// covers every endpoint that answers at once; an endpoint that blocks on
    /// purpose — `POST /v1/fleet/quiesce` with `waitSeconds` — says so with
    /// `timeout:` at the call.
    static let defaultTimeout: TimeInterval = 10

    /// `GET path`, returning the status and the JSON object the body parsed to
    /// (empty when it was not an object). `bearer: nil` sends no Authorization
    /// header — which is how a test asks what an unauthenticated caller gets.
    func get(_ path: String, bearer: String?, timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url(path))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    /// `GET path` with this harness's own token.
    func get(_ path: String, timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        try await get(path, bearer: token, timeout: timeout)
    }

    /// `POST path` with a JSON body — `{}` when none is given, which every
    /// endpoint that takes no body ignores.
    func post(_ path: String, _ body: [String: Any] = [:], bearer: String?, timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        try await send(path, method: "POST", body: body, bearer: bearer, timeout: timeout)
    }

    func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        try await post(path, body, bearer: token, timeout: timeout)
    }

    /// `PUT path` with a JSON body.
    func put(_ path: String, _ body: [String: Any] = [:], bearer: String?, timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        try await send(path, method: "PUT", body: body, bearer: bearer, timeout: timeout)
    }

    func put(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        try await put(path, body, bearer: token, timeout: timeout)
    }

    /// Any method with a JSON body; the status and parsed object come back, and
    /// `raw` carries the bytes for a test that wants to read something else.
    func send(_ path: String, method: String, body: [String: Any], bearer: String?, timeout: TimeInterval = defaultTimeout) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (Int, [String: Any]) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// The raw response, for a body that is not a JSON object — an SSE stream's
    /// first bytes, a plain-text error, a 204 with nothing.
    func raw(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}
