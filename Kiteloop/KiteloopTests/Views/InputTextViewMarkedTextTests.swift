import AppKit
import XCTest
@testable import Kiteloop

/// While an input method is composing — kana to kanji, Pinyin, Korean — Return
/// and the arrow keys belong to it, so nothing is sent and no history is
/// recalled until the candidate is committed.
@MainActor
final class InputTextViewMarkedTextTests: XCTestCase {

    private let returnKeyCode: UInt16 = 36
    private let upArrowKeyCode: UInt16 = 126
    private let downArrowKeyCode: UInt16 = 125
    private let upArrow = "\u{F700}"
    private let downArrow = "\u{F701}"

    private var submits = 0
    private var actions: [InputKeyAction] = []

    private func makeInput() -> InputTextView {
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.onSubmit = { [unowned self] in submits += 1 }
        view.onKeyAction = { [unowned self] action in
            actions.append(action)
            return true
        }
        return view
    }

    /// Puts a fresh view where an input method leaves it mid-conversion:
    /// uncommitted kana on screen, the composition still open.
    private func composingInput(file: StaticString = #filePath, line: UInt = #line) -> InputTextView {
        let input = makeInput()
        input.setMarkedText(
            "にほん",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(input.hasMarkedText(), "the view is not composing", file: file, line: line)
        return input
    }

    private func key(_ keyCode: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// One key sent to a view that is composing: the input method gets it, and
    /// neither the submit nor the key-action hook hears anything.
    private func assertComposingKeyIsIgnored(
        _ keyCode: UInt16, characters: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        submits = 0
        actions = []
        let input = composingInput(file: file, line: line)

        input.keyDown(with: try key(keyCode, characters: characters))

        XCTAssertEqual(submits, 0, "the half-typed message was sent", file: file, line: line)
        XCTAssertEqual(actions, [], "the key reached the input bar", file: file, line: line)
    }

    func testReturnWhileComposingDoesNotSubmit() throws {
        try assertComposingKeyIsIgnored(returnKeyCode, characters: "\r")
    }

    func testUpArrowWhileComposingDoesNotRecallHistory() throws {
        try assertComposingKeyIsIgnored(upArrowKeyCode, characters: upArrow)
    }

    func testDownArrowWhileComposingDoesNotRecallHistory() throws {
        try assertComposingKeyIsIgnored(downArrowKeyCode, characters: downArrow)
    }

    func testReturnOnceTheCompositionIsCommittedSubmits() throws {
        let input = composingInput()
        input.onKeyAction = nil
        input.insertText("日本", replacementRange: input.markedRange())
        XCTAssertFalse(input.hasMarkedText())

        input.keyDown(with: try key(returnKeyCode, characters: "\r"))

        XCTAssertEqual(submits, 1)
    }

    func testUpArrowWithNothingComposingStillRecallsHistory() throws {
        let input = makeInput()

        input.keyDown(with: try key(upArrowKeyCode, characters: upArrow))

        XCTAssertEqual(actions, [.historyUp])
    }
}
