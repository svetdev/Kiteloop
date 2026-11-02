import AppKit
import XCTest
@testable import Kiteloop

/// Ctrl+K, Ctrl+U and Ctrl+W in the chat input delete the way any Mac text
/// field does, and never touch the system clipboard.
@MainActor
final class InputTextViewKillKeyTests: XCTestCase {

    private func makeInput(text: String, cursor: Int) -> InputTextView {
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.string = text
        view.setSelectedRange(NSRange(location: cursor, length: 0))
        return view
    }

    private func ctrlKey(_ character: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func assertKey(
        _ character: String, keyCode: UInt16, text: String, cursor: Int, leaves expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let input = makeInput(text: text, cursor: cursor)
        let changeCount = NSPasteboard.general.changeCount

        input.keyDown(with: try ctrlKey(character, keyCode: keyCode))

        XCTAssertEqual(input.string, expected, file: file, line: line)
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount, "the clipboard was written", file: file, line: line)
    }

    func testCtrlKDeletesToEndOfLineAndKeepsTheLineBreak() throws {
        try assertKey("k", keyCode: 40, text: "abc\ndef", cursor: 2, leaves: "ab\ndef")
    }

    func testCtrlUDeletesFromStartOfLineToCursor() throws {
        try assertKey("u", keyCode: 32, text: "abc\ndef", cursor: 6, leaves: "abc\nf")
    }

    func testCtrlWDeletesTheWordBeforeTheCursor() throws {
        try assertKey("w", keyCode: 13, text: "one two", cursor: 7, leaves: "one ")
    }
}
