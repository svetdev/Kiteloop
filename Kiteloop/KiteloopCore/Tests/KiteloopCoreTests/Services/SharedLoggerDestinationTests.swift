import XCTest
@testable import KiteloopCore

/// The redirect that keeps this whole test process out of the human's Kiteloop
/// home.
///
/// `KiteloopFileLogger.shared` is the singleton every service logs through, and
/// with no project open it writes under `~/.kiteloop` — which is where a test
/// process used to put every line a fixture provoked, over a hundred thousand a
/// day. `KiteloopTestLogRedirect` sets `KITELOOP_LOG_BASE_DIRECTORY` from a
/// load-time constructor, so the destination is already somewhere else before
/// the first test runs; `KiteloopTestSupport` depends on that target, so linking
/// the shared test helpers is what installs it.
///
/// These cases are the guard on that arrangement. They fail if the constructor
/// stops running — if the C target is dropped from the manifest, or a linker
/// leaves its object out — which is a failure that is otherwise invisible until
/// somebody notices their log filling up again.
final class SharedLoggerDestinationTests: XCTestCase {

    private var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    }

    /// The constructor ran: this process defaults its logs somewhere that is not
    /// under the home directory, without any test having asked for it.
    func testThisProcessDefaultsItsLogsOutsideTheHomeDirectory() {
        let base = KiteloopFileLogger.defaultBaseURL().path(percentEncoded: false)

        XCTAssertFalse(
            base.hasPrefix(home),
            "KiteloopTestLogRedirect should have pointed this process at a temporary directory, not \(base)"
        )
    }

    /// And a logger built the way `shared` is — no `baseURL`, the process's real
    /// environment — writes there, rather than into the day's real log.
    @MainActor
    func testALoggerBuiltLikeTheSharedOneWritesOutsideTheHomeDirectory() async throws {
        let message = "default-destination probe \(UUID().uuidString)"
        let logger = KiteloopFileLogger()

        logger.log(message, category: "logger-test")

        // `configure` settles on the logger's own queue, so the file it will
        // write to is named a moment after the init returns, not by it.
        let fileURL = try await eventuallyValue("the logger to name a file") {
            logger.currentLogFileURL()
        }
        XCTAssertFalse(
            fileURL.path(percentEncoded: false).hasPrefix(home),
            "a logger nothing configured must name no file under the human's home"
        )
        try await eventually("the line to reach \(fileURL.path(percentEncoded: false))") {
            (try? String(contentsOf: fileURL, encoding: .utf8))?.contains(message) == true
        }
    }
}
