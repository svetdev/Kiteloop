import XCTest
@testable import KiteloopCore

/// The collapsed summary on a tool-call row read a failed output as a failure
/// while the standalone result row hard-coded a green tick, so a transcript of
/// failed Bash, Read and Grep calls looked like a run that went fine. Both
/// surfaces ask these rules now, and they are asserted here with no view.
final class ToolResultOutcomeTests: XCTestCase {

    func testOutputOpeningWithErrorIsAFailure() {
        XCTAssertEqual(ToolResultOutcome.of(output: "Error: ENOENT: no such file or directory"), .failure)
    }

    func testTheErrorPrefixIsReadWithoutRegardToCase() {
        XCTAssertEqual(ToolResultOutcome.of(output: "ERROR reading the file"), .failure)
    }

    /// The wrapper Claude Code returns for a refused or failed tool call. The
    /// Autopilot console already turned such a row red while the chat drew it
    /// with a green tick.
    func testAToolUseErrorWrapperIsAFailure() {
        XCTAssertEqual(ToolResultOutcome.of(output: "<tool_use_error>File has not been read yet"), .failure)
    }

    func testCommandFailedAnywhereNearTheTopIsAFailure() {
        let output = """
        $ swift build
        The command failed with exit code 1
        """

        XCTAssertEqual(ToolResultOutcome.of(output: output), .failure)
    }

    /// A build log that mentions an error hundreds of characters in is not the
    /// call itself failing — only the top of the output is read.
    func testAFailureNotedBeyondTheInspectedPrefixIsNotAFailure() {
        let output = String(repeating: "ok\n", count: 200) + "command failed"

        XCTAssertEqual(ToolResultOutcome.of(output: output), .success)
    }

    func testAnEmptyOutputIsNotAFailure() {
        XCTAssertEqual(ToolResultOutcome.of(output: ""), .success)
        XCTAssertFalse(ToolResultOutcome.of(output: "").isError)
    }

    func testAnOrdinaryOutputIsASuccess() {
        XCTAssertEqual(ToolResultOutcome.of(output: "12 files changed, 40 insertions(+)"), .success)
        XCTAssertFalse(ToolResultOutcome.of(output: "12 files changed, 40 insertions(+)").isError)
    }

    func testIsErrorAgreesWithTheCase() {
        XCTAssertTrue(ToolResultOutcome.failure.isError)
        XCTAssertFalse(ToolResultOutcome.success.isError)
    }
}
