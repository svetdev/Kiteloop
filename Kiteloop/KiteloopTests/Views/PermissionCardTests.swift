import XCTest
import SwiftUI
import KiteloopCore
@testable import Kiteloop

/// What the permission and choices cards say and send, apart from drawing.
final class PermissionCardTests: XCTestCase {

    func testTheTitleNamesWhoAsksAndForWhichTool() {
        let own = Message.PermissionRequest(id: "r", toolName: "Bash", input: "{}", summary: "make")
        XCTAssertEqual(PermissionCard.title(for: own), "Asks to use Bash")
        let child = Message.PermissionRequest(id: "r", toolName: "Write", input: "{}", summary: "a.txt", subagent: "Draft the notes")
        XCTAssertEqual(PermissionCard.title(for: child), "Subagent “Draft the notes” asks to use Write")
    }

    func testEachAnswerReadsAsWhatWasChosen() {
        XCTAssertEqual(PermissionCard.answeredLabel(.allowed), "Allowed once")
        XCTAssertEqual(PermissionCard.answeredLabel(.allowedAlways), "Allowed, and remembered")
        XCTAssertEqual(PermissionCard.answeredLabel(.denied), "Denied")
        XCTAssertEqual(PermissionCard.answeredLabel(.lapsed), "No longer waiting on an answer")
        XCTAssertEqual(PermissionCard.answeredSymbol(.denied), "xmark.circle.fill")
        XCTAssertEqual(PermissionCard.answeredSymbol(.lapsed), "clock.badge.xmark")
        XCTAssertEqual(PermissionCard.answeredSymbol(.allowedAlways), PermissionCard.answeredSymbol(.allowed))
    }

    // MARK: - Drawn

    /// Lays `view` out in a window and answers the height it needs.
    @MainActor
    private func drawnHeight(of view: some View) async throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 420))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await eventually("the view is laid out") { host.fittingSize.height > 0 }
        return host.fittingSize.height
    }

    /// An open card carries its buttons and its offers; answered, it is the
    /// shorter for having one line in their place.
    @MainActor
    func testAnOpenPermissionCardIsTallerThanAnAnsweredOneByItsButtonsAndOffers() async throws {
        let offers = [PermissionSuggestion(label: "Always allow Bash(make) in this project", json: "{}"),
                      PermissionSuggestion(label: "Switch to Accept Edits for this session", json: "{}")]
        var request = Message.PermissionRequest(id: "r", toolName: "Bash", input: "{}", summary: "make test",
                                                subagent: "Run the tests", suggestions: offers)
        let open = try await drawnHeight(of: PermissionCard(request: request) { _, _ in })
        request.answer = .allowed
        let answered = try await drawnHeight(of: PermissionCard(request: request) { _, _ in })

        XCTAssertGreaterThan(open, answered)
    }

    @MainActor
    func testAChoicesCardDrawsOpenAnsweredAndLapsed() async throws {
        var asked = Message.ChoiceQuestion(id: "q", input: "{}", questions: [one, several])
        let open = try await drawnHeight(of: ChoicesCard(asked: asked) { _ in })
        asked.answers = ["Tea", "S, L"]
        let answered = try await drawnHeight(of: ChoicesCard(asked: asked) { _ in })
        asked.answers = nil
        asked.lapsed = true
        let lapsed = try await drawnHeight(of: ChoicesCard(asked: asked) { _ in })

        XCTAssertGreaterThan(open, answered, "the options and answer fields go once it is answered")
        XCTAssertGreaterThan(open, lapsed)
        XCTAssertGreaterThan(answered, lapsed, "an answered card still shows each answer")
    }

    /// The strip draws for a subagent the turn is waiting on, which the
    /// background list does not hold, and not at all when nothing runs.
    @MainActor
    func testTheTasksStripDrawsForARunningTaskAndNotForNone() async throws {
        let running = [AgentActivity.TaskState(taskID: "t", kind: .subagent, description: "Run the tests")]
        let height = try await drawnHeight(of: BackgroundTasksStrip(tasks: [], running: running))
        XCTAssertGreaterThan(height, 0)
        XCTAssertNil(AgentActivityDisplay.runningSummary(background: [], running: []))
    }

    @MainActor
    func testRememberedRulesAreListedAndAnEmptyProjectSaysHowOneGetsThere() async throws {
        let root = try makeTemporaryDirectory(prefix: "remembered-list")
        let empty = try await drawnHeight(of: Form { RememberedPermissionsList(projectRoot: root) })
        let url = RememberedPermissions.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"permissions":{"allow":["Bash(a)","Bash(b)","Bash(c)","Bash(d)"]}}"#.utf8).write(to: url)
        let listed = try await drawnHeight(of: Form { RememberedPermissionsList(projectRoot: root) })

        XCTAssertGreaterThan(listed, empty, "four rules take more room than the one line that says there are none")
    }

    private let one = Message.ChoiceQuestion.Question(
        question: "Tea or coffee?", options: [.init(label: "Tea"), .init(label: "Coffee")])
    private let several = Message.ChoiceQuestion.Question(
        question: "Which sizes?", options: [.init(label: "S"), .init(label: "M"), .init(label: "L")], multiSelect: true)

    func testAQuestionThatTakesOneAnswerHoldsOnlyTheNewestPick() {
        XCTAssertEqual(ChoicesCard.toggling("Coffee", in: ["Tea"], of: one), ["Coffee"])
        XCTAssertEqual(ChoicesCard.toggling("Tea", in: ["Tea"], of: one), ["Tea"])
    }

    func testAQuestionThatTakesSeveralAddsAndRemovesInTheOrderListed() {
        XCTAssertEqual(ChoicesCard.toggling("L", in: [], of: several), ["L"])
        XCTAssertEqual(ChoicesCard.toggling("S", in: ["L"], of: several), ["S", "L"])
        XCTAssertEqual(ChoicesCard.toggling("L", in: ["S", "L"], of: several), ["S"])
    }

    func testAnswersAreWhatWasTypedElseThePicksAndNothingUntilEveryQuestionHasOne() {
        XCTAssertNil(ChoicesCard.answers(to: [one, several], picked: [0: ["Tea"]], typed: [:]))
        XCTAssertEqual(ChoicesCard.answers(to: [one, several], picked: [0: ["Tea"], 1: ["S", "L"]], typed: [:]), ["Tea", "S, L"])
        XCTAssertEqual(ChoicesCard.answers(to: [one, several], picked: [0: ["Tea"]], typed: [0: " Water ", 1: "None"]),
                       ["Water", "None"], "an answer of your own stands in for a pick")
        XCTAssertNil(ChoicesCard.answers(to: [one], picked: [:], typed: [0: "   "]))
        XCTAssertEqual(ChoicesCard.answers(to: [], picked: [:], typed: [:]), [])
    }
}
