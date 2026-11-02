import XCTest
@testable import Kiteloop

/// `checkBedrock` and `checkGitHub` used to spawn their own `Process` by hand,
/// each with no deadline: a hung `aws sts get-caller-identity` or `gh auth
/// status` left every later check in `runChecks` on `.checking` forever. Both
/// now go through `runCredentialCheck`, the seam these tests drive directly —
/// `executable` lets a test stand in for `aws`/`gh` without touching either.
final class SetupWizardViewModelCredentialCheckTests: XCTestCase {

    func testASuccessfulCommandReadsAsSuccess() async {
        let success = await SetupWizardViewModel.runCredentialCheck(
            arguments: [],
            executable: "/usr/bin/true",
            timeout: 5
        )

        XCTAssertTrue(success)
    }

    func testAFailingCommandReadsAsFailure() async {
        let success = await SetupWizardViewModel.runCredentialCheck(
            arguments: [],
            executable: "/usr/bin/false",
            timeout: 5
        )

        XCTAssertFalse(success)
    }

    /// The defect this item exists to fix: a command that never exits must be
    /// abandoned at the deadline — reading as a failure — rather than leaving
    /// the check on `.checking` for ever.
    func testACommandThatOutlivesItsDeadlineReadsAsFailureRatherThanHanging() async {
        let started = Date()
        let success = await SetupWizardViewModel.runCredentialCheck(
            arguments: ["3600"],
            executable: "/bin/sleep",
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(success)
        // The child would have slept for an hour: returning near the deadline,
        // rather than after it, proves the wait was bounded.
        XCTAssertLessThan(elapsed, 15)
    }

    /// Both checks layer credential-specific state (`AWS_PROFILE`) onto the
    /// child's environment; the refactor must keep forwarding it.
    func testExtraEnvironmentReachesTheChild() async {
        let success = await SetupWizardViewModel.runCredentialCheck(
            arguments: ["-c", "test \"$KITELOOP_TEST_MARKER\" = expected"],
            extraEnv: ["KITELOOP_TEST_MARKER": "expected"],
            executable: "/bin/sh",
            timeout: 5
        )

        XCTAssertTrue(success)
    }

    /// Nothing here can answer a prompt: the child must read EOF on stdin
    /// rather than inheriting the test host's, or a command that stops to ask
    /// would hang until the deadline killed it instead of exiting at once.
    func testTheChildsStandardInputIsClosedRatherThanInherited() async {
        let started = Date()
        let success = await SetupWizardViewModel.runCredentialCheck(
            arguments: [],
            executable: "/bin/cat",
            timeout: 10
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(success)
        XCTAssertLessThan(elapsed, 5, "cat should see EOF immediately, not wait out the deadline")
    }
}
