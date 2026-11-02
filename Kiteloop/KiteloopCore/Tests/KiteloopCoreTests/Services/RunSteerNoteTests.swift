import XCTest
@testable import KiteloopCore

/// `RunSteerNote` is the one thing an operator can hand a live worker without
/// cancelling the run, so what it does with the text matters twice: once for
/// what reaches the worker, once for the record that says what was sent.
final class RunSteerNoteTests: XCTestCase {

    // MARK: - sanitize

    /// Nothing to send is nil, not an empty note: the UI's send control and the
    /// orchestrator's queue both key off "is there a note", and an empty string
    /// would reach the worker as a turn saying nothing.
    func testSanitizeReturnsNilForABlankNote() {
        XCTAssertNil(RunSteerNote.sanitize(""))
        XCTAssertNil(RunSteerNote.sanitize("   \n\t  "))
    }

    func testSanitizeKeepsATypedNoteMinusItsSurroundingWhitespace() {
        XCTAssertEqual(
            RunSteerNote.sanitize("  the fix belongs in the parser, not the view\n"),
            "the fix belongs in the parser, not the view"
        )
        XCTAssertEqual(
            RunSteerNote.sanitize("look at\n  Services/Foo.swift"),
            "look at\n  Services/Foo.swift",
            "inner newlines and indentation are the operator's and stay"
        )
    }

    func testSanitizeCapsANoteLongerThanMaxLength() throws {
        let note = String(repeating: "x", count: RunSteerNote.maxLength + 1)
        let sent = try XCTUnwrap(RunSteerNote.sanitize(note))
        XCTAssertEqual(sent.count, RunSteerNote.maxLength)
    }

    // MARK: - prompt

    /// One note reads as one note: "a note", then the note. Nothing counts it.
    ///
    /// The framing is the whole difference between advice and re-scoping. A
    /// worker handed a bare operator sentence mid-run treats it as the new
    /// specification, so the prompt has to say what the note cannot do.
    func testPromptForASingleNoteSaysANoteAndQuotesIt() {
        let prompt = RunSteerNote.prompt(["check the parser first"])
        XCTAssertTrue(prompt.contains("has sent you a note:"), prompt)
        XCTAssertFalse(prompt.contains("1 notes"), "a lone note is not a batch of one")
        XCTAssertTrue(prompt.contains("  > check the parser first"), prompt)
        XCTAssertTrue(prompt.contains("not a change to the item"),
                      "the note must not read as a new specification")
        XCTAssertTrue(prompt.contains("What / How / Validation"),
                      "the item's criteria still define done")
        XCTAssertTrue(prompt.contains("cannot approve"))
        XCTAssertTrue(prompt.contains("raise any spending cap"))
        XCTAssertTrue(prompt.contains("speak for the reviewer"))
        XCTAssertTrue(prompt.contains("the item wins"),
                      "a note that contradicts the item must lose to it")
    }

    /// A batch says how many, and every note in it reaches the worker — a turn
    /// that ends with three notes waiting must not deliver only the first, and
    /// a correction that supersedes an earlier one must be read after it.
    func testPromptForSeveralNotesCountsThemAndQuotesEachOne() {
        let prompt = RunSteerNote.prompt(["first", "second", "third"])
        XCTAssertTrue(prompt.contains("has sent you 3 notes:"), prompt)
        XCTAssertFalse(prompt.contains("sent you a note:"), prompt)
        for note in ["first", "second", "third"] {
            XCTAssertTrue(prompt.contains("  > \(note)"), "note \(note) did not reach the prompt")
        }
        guard let first = prompt.range(of: "first"),
              let second = prompt.range(of: "second"),
              let third = prompt.range(of: "third") else {
            return XCTFail("every note must survive into the prompt")
        }
        XCTAssertTrue(first.lowerBound < second.lowerBound)
        XCTAssertTrue(second.lowerBound < third.lowerBound)
    }
}
