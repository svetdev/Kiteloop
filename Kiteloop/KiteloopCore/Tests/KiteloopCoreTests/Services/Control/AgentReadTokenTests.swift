import XCTest
import os
@testable import KiteloopCore

/// The read token the app keeps for read-only agents: minted once into the
/// scoped-token store under a name a person recognises, reused from its own
/// private file, replaced after a revoke — and refused, by the same rule every
/// scoped token is judged by, on every route that is not a read.
final class AgentReadTokenTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL { directory.appending(path: "control-scoped-tokens.json") }
    private var fileURL: URL { directory.appending(path: "agent-read-token") }

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory(prefix: "agent-read-token")
    }

    func testTheFirstSpawnMintsOneNamedReadTokenInThePersonsTokenList() throws {
        let store = ControlScopedTokens(url: storeURL)

        let token = try XCTUnwrap(AgentReadToken(store: store, fileURL: fileURL).current())

        XCTAssertEqual(store.tokens.map(\.name), [AgentReadToken.name])
        XCTAssertEqual(store.token(for: token)?.scope, .read)
    }

    func testLaterSpawnsReuseItAcrossInstancesAndRelaunches() throws {
        let store = ControlScopedTokens(url: storeURL)
        let first = try XCTUnwrap(AgentReadToken(store: store, fileURL: fileURL).current())

        XCTAssertEqual(AgentReadToken(store: store, fileURL: fileURL).current(), first)
        let relaunched = ControlScopedTokens(url: storeURL)
        XCTAssertEqual(AgentReadToken(store: relaunched, fileURL: fileURL).current(), first)
        XCTAssertEqual(relaunched.tokens.count, 1, "nothing was minted for the later spawns")
    }

    func testTheTokenIsKeptInAFileOnlyThisUserCanRead() throws {
        let token = try XCTUnwrap(AgentReadToken(store: ControlScopedTokens(url: storeURL), fileURL: fileURL).current())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), token)
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertFalse(try String(contentsOf: storeURL, encoding: .utf8).contains(token), "the store keeps the hash")
    }

    func testARevokedTokenStopsResolvingAndTheNextSpawnGetsANewOne() throws {
        let store = ControlScopedTokens(url: storeURL)
        let keeper = AgentReadToken(store: store, fileURL: fileURL)
        let revoked = try XCTUnwrap(keeper.current())
        XCTAssertTrue(store.revoke(try XCTUnwrap(store.token(for: revoked)).id))
        XCTAssertNil(store.token(for: revoked))

        let replacement = try XCTUnwrap(keeper.current())

        XCTAssertNotEqual(replacement, revoked)
        XCTAssertNil(store.token(for: revoked), "the revoked token stays revoked")
        XCTAssertEqual(store.token(for: replacement)?.scope, .read)
        XCTAssertEqual(store.tokens.count, 1)
    }

    /// A file that names a token of a wider scope — put there by hand — is not
    /// what a read-only agent is given.
    func testAKeptTokenThatIsNotAReadTokenIsNotHandedOut() throws {
        let store = ControlScopedTokens(url: storeURL)
        let (wider, _) = store.mint(name: "ci", scope: .configure)
        try Data(wider.utf8).write(to: fileURL)

        let token = try XCTUnwrap(AgentReadToken(store: store, fileURL: fileURL).current())

        XCTAssertNotEqual(token, wider)
        XCTAssertEqual(store.token(for: token)?.scope, .read)
    }

    func testATokenThatCannotBeKeptIsRevokedRatherThanHandedOut() throws {
        let store = ControlScopedTokens(url: storeURL)
        // A file where the token's directory should be: the write cannot land.
        let blocker = directory.appending(path: "blocker")
        try Data().write(to: blocker)

        XCTAssertNil(AgentReadToken(store: store, fileURL: blocker.appending(path: "agent-read-token")).current())
        XCTAssertEqual(store.tokens, [], "a token minted at every spawn would pile up in the list")
    }

    func testConcurrentSpawnsShareOneToken() throws {
        let store = ControlScopedTokens(url: storeURL)
        let keeper = AgentReadToken(store: store, fileURL: fileURL)
        let handed = OSAllocatedUnfairLock(initialState: Set<String?>())

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let token = keeper.current()
            handed.withLock { _ = $0.insert(token) }
        }

        XCTAssertEqual(handed.withLock { $0 }.count, 1)
        XCTAssertEqual(store.tokens.count, 1)
    }

    // MARK: - What the token may call

    /// The credential the server sees for the token `AgentReadToken` hands out.
    private func credential() throws -> ControlCredential {
        let store = ControlScopedTokens(url: storeURL)
        let token = try XCTUnwrap(AgentReadToken(store: store, fileURL: fileURL).current())
        return .scoped(try XCTUnwrap(store.token(for: token)).scope)
    }

    /// Over the whole routing table, so a route added later is covered: the
    /// scope check that judges every scoped token refuses this one on every
    /// endpoint that is not a `GET`.
    func testTheReadTokenIsRefusedOnEveryRouteThatIsNotAGET() throws {
        let held = try credential()
        let writes = ControlRouter.endpoints.filter { $0.method != "GET" }

        XCTAssertFalse(writes.isEmpty)
        for endpoint in writes {
            let request = "\(endpoint.method) \(endpoint.path)"
            XCTAssertNotNil(ControlAccess.refusal(of: held, calling: endpoint.route, as: request),
                            "\(request) is open to the read token")
        }
    }

    func testTheReadTokenReadsButNeverTheTokenList() throws {
        let held = try credential()
        for (method, path) in [("GET", "/v1/projects"), ("GET", "/v1/attention"), ("GET", "/v1/spend"),
                               ("GET", "/v1/events"), ("GET", "/v1/backlog")] {
            let route = try XCTUnwrap(ControlRouter.match(method: method, path: path), path)
            XCTAssertNil(ControlAccess.refusal(of: held, calling: route, as: "\(method) \(path)"), path)
        }
        let tokens = try XCTUnwrap(ControlRouter.match(method: "GET", path: "/v1/tokens"))
        XCTAssertNotNil(ControlAccess.refusal(of: held, calling: tokens, as: "GET /v1/tokens"))
    }
}
