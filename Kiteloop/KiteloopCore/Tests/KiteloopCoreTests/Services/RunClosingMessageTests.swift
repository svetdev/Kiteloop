import XCTest
@testable import KiteloopCore

/// Covers what a run that produced nothing says about *why*. The rules are pure
/// — a step list is a value — so the whole thing is exercised without a workflow
/// engine, an agent or a repo.
final class RunClosingMessageTests: XCTestCase {

    // MARK: - Condensing

    func testCondensedKeepsTheWordsOnOneLine() {
        let text = "This is the commit that actually implements the item\n— already merged."
        XCTAssertEqual(RunClosingMessage.condensed(text),
                       "This is the commit that actually implements the item — already merged.")
    }

    func testCondensedIsNilWhenThereIsNothingToRecord() {
        XCTAssertNil(RunClosingMessage.condensed(nil))
        XCTAssertNil(RunClosingMessage.condensed(""))
        XCTAssertNil(RunClosingMessage.condensed("   \n\t  "))
    }

    /// A signpost, not a transcript — a worker that ends with a wall of text
    /// must not put a wall of text in the item's Notes.
    func testCondensedIsBounded() {
        let long = String(repeating: "a", count: RunClosingMessage.characterLimit * 3)
        let condensed = RunClosingMessage.condensed(long)
        XCTAssertEqual(condensed?.count, RunClosingMessage.characterLimit + 1) // + the ellipsis
        XCTAssertTrue(condensed?.hasSuffix("…") == true, condensed ?? "nil")
    }

    func testCondensedLeavesAMessageAtTheLimitAlone() {
        let exact = String(repeating: "b", count: RunClosingMessage.characterLimit)
        XCTAssertEqual(RunClosingMessage.condensed(exact), exact)
    }

    // MARK: - Capturing

    /// What is kept and what is shown are two different bounds. Capture used to
    /// apply the display one, which threw the rest of the message away before
    /// anything could read it — a structured claim over 300 characters arrived
    /// as JSON with no closing brace.
    func testCapturedKeepsMoreThanIsEverShown() {
        let long = String(repeating: "a", count: RunClosingMessage.characterLimit * 3)
        XCTAssertEqual(RunClosingMessage.captured(long)?.count, long.count)
        XCTAssertGreaterThan(RunClosingMessage.captureLimit, RunClosingMessage.characterLimit)
    }

    /// Line breaks survive capture, because what reads this rather than shows it
    /// is a parser. `condensed` is still where they are collapsed.
    func testCapturedKeepsTheShapeTheAgentWrote() {
        let text = "I believe this is already done.\n\n{\"outcome\": \"already-implemented\"}"
        XCTAssertEqual(RunClosingMessage.captured(text), text)
        XCTAssertFalse(RunClosingMessage.condensed(text)?.contains("\n") ?? true)
    }

    /// Bounded all the same: this rides in workflow state and is checkpointed
    /// with it, so a worker ending with a wall of text cannot put the wall there.
    func testCapturedIsStillBounded() {
        let huge = String(repeating: "c", count: RunClosingMessage.captureLimit * 2)
        XCTAssertEqual(RunClosingMessage.captured(huge)?.count, RunClosingMessage.captureLimit)
    }

    /// The dead-session case reads the same through capture as through
    /// condensing: nothing said is nil, not an empty string.
    func testCapturedIsNilWhenThereIsNothingToRecord() {
        XCTAssertNil(RunClosingMessage.captured(nil))
        XCTAssertNil(RunClosingMessage.captured(""))
        XCTAssertNil(RunClosingMessage.captured("   \n\t  "))
    }

    // MARK: - The recorded phrase

    func testPhraseQuotesTheWorkersOwnWords() {
        XCTAssertEqual(RunClosingMessage.phrase("Already implemented on main."),
                       "worker's closing message: \"Already implemented on main.\"")
    }

    /// The dead-session case. "Nothing was said" is the most diagnostic answer
    /// available and has to be said out loud, not left as a blank.
    func testPhraseSaysSoWhenThereWasNoOutputAtAll() {
        XCTAssertEqual(RunClosingMessage.phrase(nil), RunClosingMessage.noOutput)
        XCTAssertEqual(RunClosingMessage.phrase("  "), RunClosingMessage.noOutput)
    }

    /// The words are recorded, never read. A message that sounds like a category
    /// gets the same treatment as one that doesn't.
    func testPhraseNeverClassifies() {
        for message in ["Already implemented — nothing to do.",
                        "I gave up.",
                        "Session error."] {
            XCTAssertEqual(RunClosingMessage.phrase(message),
                           "worker's closing message: \"\(message)\"")
        }
    }

    // MARK: - Reading it off an execution

    private func step(_ node: String, _ message: String?) -> ExecutionStep {
        var output: [String: AnyCodable] = ["passed": .string("false")]
        if let message { output[RunClosingMessage.outputKey] = .string(message) }
        return ExecutionStep(nodeID: node, agentID: "a", spanID: nil,
                             startedAt: Date(), completedAt: Date(), output: output)
    }

    func testLastMessageReadsTheNamedNode() {
        let steps = [step("worker", "built it"), step("reviewer", "looks fine")]
        XCTAssertEqual(RunClosingMessage.lastMessage(in: steps, node: "worker"), "built it")
        XCTAssertEqual(RunClosingMessage.lastMessage(in: steps, node: "reviewer"), "looks fine")
    }

    /// A rejected item runs the worker again; the run ended on the last attempt,
    /// so that is the attempt whose words explain the ending.
    func testLastMessageTakesTheFinalAttempt() {
        let steps = [step("worker", "first try"),
                     step("reviewer", "no"),
                     step("worker", "already implemented")]
        XCTAssertEqual(RunClosingMessage.lastMessage(in: steps, node: "worker"),
                       "already implemented")
    }

    /// A session that dies never completes its node, so there is no step to
    /// read — which reports as no output rather than as a gap in the record.
    func testLastMessageIsNilWhenTheNodeNeverCompleted() {
        XCTAssertNil(RunClosingMessage.lastMessage(in: [], node: "worker"))
        XCTAssertNil(RunClosingMessage.lastMessage(in: [step("reviewer", "hi")], node: "worker"))
        XCTAssertEqual(RunClosingMessage.phrase(RunClosingMessage.lastMessage(in: [], node: "worker")),
                       RunClosingMessage.noOutput)
    }

    func testLastMessageIsNilWhenTheStepCarriedNoText() {
        XCTAssertNil(RunClosingMessage.lastMessage(in: [step("worker", nil)], node: "worker"))
    }
}
