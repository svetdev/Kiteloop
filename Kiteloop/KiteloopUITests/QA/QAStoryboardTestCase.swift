import XCTest

/// The base of a QA flow — the UI test a `flow:qa` item's worker writes and its
/// QA agent runs (docs/qa-flow.md).
///
/// It launches the QA copy of Kiteloop in UI-testing mode against a throwaway
/// home, so the app never reads or writes the user's real `~/.kiteloop`, and
/// photographs the front window after every `step`, attaching the shot to the
/// run. `scripts/qa/run-ui-flow.sh` turns those attachments into the storyboard
/// the QA agent judges, one picture per step in the order they were taken.
@MainActor
class QAStoryboardTestCase: KiteloopUITestCase {
    private var stepNumber = 0
    private var currentCaption: String?

    override func setUp() async throws {
        try await super.setUp()
        app.launchEnvironment["KITELOOP_HOME"] = try Self.isolatedHome()
    }

    /// The home `run-ui-flow.sh` made for this run, or — run from Xcode, with
    /// nothing passed in — a fresh temporary one. Never the user's.
    private static func isolatedHome() throws -> String {
        if let home = ProcessInfo.processInfo.environment["KITELOOP_HOME"], home.hasPrefix("/") { return home }
        let home = FileManager.default.temporaryDirectory.appending(path: "kiteloop-qa-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path(percentEncoded: false)
    }

    /// Runs `body` as one step of the QA procedure, then photographs the app's
    /// front window as what the person sees once the step is done.
    func step(_ caption: String, _ body: () throws -> Void) rethrows {
        currentCaption = caption
        try XCTContext.runActivity(named: caption) { _ in try body() }
        currentCaption = nil
        stepNumber += 1
        photograph(named: String(format: "%02d %@", stepNumber, caption))
    }

    /// Fails if the start screen lists a recent project. The isolated home has
    /// never opened one, so a row there means the QA copy is reading the
    /// user's own `~/.kiteloop` — and a flow would judge their real projects.
    func assertNoRecentProjects(file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(identifier: "start-recent-project").firstMatch
        XCTAssertFalse(row.waitForExistence(timeout: 2),
                       "The start screen lists a recent project, so the QA copy is reading the user's own state, "
                       + "not its throwaway home: check KITELOOP_HOME reaches the app (scripts/qa/run-ui-flow.sh)",
                       file: file, line: line)
    }

    /// Fails if a macOS privacy (TCC) dialog is on screen. It is modal and waits
    /// for a human, so it sits over the window and every later step and picture
    /// is of the dialog, not of Kiteloop.
    func assertNoPrivacyDialog(file: StaticString = #filePath, line: UInt = #line) {
        // TCC prompts are drawn by this system agent, not by the app that asked.
        let prompter = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        let showing = prompter.state != .notRunning
            && (prompter.dialogs.firstMatch.waitForExistence(timeout: 2) || prompter.windows.firstMatch.exists)
        XCTAssertFalse(showing,
                       "A macOS privacy dialog is over the window: the QA copy has no grant of its own. Add it to "
                       + "Full Disk Access as docs/unattended-permissions.md §A step 5 says, then run the flow again",
                       file: file, line: line)
    }

    /// A failing step stops the flow (`continueAfterFailure` is off) before
    /// `step` can photograph it, so the failure takes the picture: the step's
    /// number, FAILED, and why. Without it the storyboard ended on the last
    /// step that passed and read as a clean run.
    nonisolated override func record(_ issue: XCTIssue) {
        // Only what fails the test: XCTest also records warnings here (an API
        // called on the main thread), and those do not stop a step.
        let fails: Set<XCTIssue.IssueType> = [.assertionFailure, .thrownError, .uncaughtException]
        guard fails.contains(issue.type) else { return super.record(issue) }
        let why = String(issue.compactDescription.replacingOccurrences(of: "\n", with: " ").prefix(160))
        // XCTest records an assertion on the thread that made it — the main
        // thread, for a flow's steps — and this hop never leaves it.
        if Thread.isMainThread {
            nonisolated(unsafe) let test = self
            MainActor.assumeIsolated { test.photographFailure(why: why) }
        }
        super.record(issue)
    }

    private func photographFailure(why: String) {
        guard let caption = currentCaption else { return }
        currentCaption = nil
        photograph(named: String(format: "%02d FAILED: %@ — %@", stepNumber + 1, caption, why))
    }

    private func photograph(named name: String) {
        let window = app.windows.firstMatch
        let shot = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
