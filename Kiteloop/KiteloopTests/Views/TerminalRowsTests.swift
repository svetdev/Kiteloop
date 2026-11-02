import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Claude Code terminal look: which chats get it, and what its rows print.
final class TerminalRowsTests: XCTestCase {

    private func message(_ sender: Message.Sender, _ text: String = "hi") -> Message {
        Message(id: UUID(), timestamp: Date(), sender: sender, content: .text(text))
    }

    // MARK: - Which chats are drawn terminal-style

    func testAChatWithOneAgentIsDrawnLikeTheTerminal() {
        let messages = [message(.human), message(.agent("coder")), message(.system), message(.agent("coder"))]
        XCTAssertTrue(ChatView.usesTerminalLook(for: messages))
    }

    func testAChatNobodyHasAnsweredYetIsDrawnLikeTheTerminal() {
        XCTAssertTrue(ChatView.usesTerminalLook(for: []))
        XCTAssertTrue(ChatView.usesTerminalLook(for: [message(.human)]))
    }

    func testAChatHoldingASecondAgentsReplyKeepsTheBubbles() {
        let messages = [message(.human), message(.agent("coder")), message(.agent("qa"))]
        XCTAssertFalse(ChatView.usesTerminalLook(for: messages),
                       "bubbles name who said what; the terminal look names nobody")
    }

    // MARK: - The call line

    func testACallReadsAsToolAndTarget() {
        XCTAssertEqual(TerminalText.callLine(tool: "Bash", target: "swift test"), "Bash(swift test)")
        XCTAssertEqual(TerminalText.callLine(tool: "Read", target: "Tests/LoginTests.swift"), "Read(Tests/LoginTests.swift)")
    }

    func testACallWithNothingToPointAtIsItsNameAlone() {
        XCTAssertEqual(TerminalText.callLine(tool: "TodoWrite", target: ""), "TodoWrite")
    }

    // MARK: - What prints under ⎿

    func testAReadPrintsHowManyLinesItRead() {
        XCTAssertEqual(TerminalText.resultLines(tool: "Read", output: "one\ntwo\nthree"), ["Read 3 lines"])
    }

    func testASearchPrintsHowManyMatchesItFound() {
        XCTAssertEqual(TerminalText.resultLines(tool: "Grep", output: "a.swift:1:x\nb.swift:2:y"), ["Found 2 matches"])
    }

    func testAFailurePrintsItsErrorNotItsOutput() {
        let lines = TerminalText.resultLines(tool: "Bash", output: "Error: ENOENT: no such file or directory\nat line 2")
        XCTAssertEqual(lines, ["Error: ENOENT: no such file or directory"])
    }

    func testLongOutputShowsItsFirstLinesAndHowManyMoreThereWere() {
        let output = (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(TerminalText.resultLines(tool: "Bash", output: output),
                       ["line 1", "line 2", "line 3", "… +7 lines (click to expand)"])
    }

    func testOneLineOverTheCutIsNamedInTheSingular() {
        XCTAssertEqual(TerminalText.preview(of: "a\nb\nc\nd", limit: 3), ["a", "b", "c", "… +1 line (click to expand)"])
    }

    func testShortOutputIsShownWholeWithoutItsTrailingBlankLines() {
        XCTAssertEqual(TerminalText.resultLines(tool: "Bash", output: "ok\n\n  \n"), ["ok"])
    }

    func testACommandThatPrintedNothingSaysSo() {
        XCTAssertEqual(TerminalText.resultLines(tool: "Bash", output: "\n"), ["(No output)"])
    }

    // MARK: - A file change under ⎿

    private let edited = "The file /repo/notes.txt has been updated successfully."

    func testAnEditReplacingOneLineWithTwoReadsAsItsAdditionsAndRemovals() {
        let input: [String: Any] = ["file_path": "/repo/notes.txt", "old_string": "a", "new_string": "b\nc"]
        XCTAssertEqual(TerminalText.resultLines(tool: "Edit", output: edited, input: input),
                       ["Updated notes.txt with 2 additions and 1 removal"])
    }

    func testAOneLineAddIsNamedInTheSingular() {
        let input: [String: Any] = ["file_path": "/repo/notes.txt", "old_string": "", "new_string": "b"]
        XCTAssertEqual(TerminalText.resultLines(tool: "Edit", output: edited, input: input),
                       ["Updated notes.txt with 1 addition and 0 removals"])
    }

    func testAWriteReadsAsHowManyLinesItWrote() {
        let content = (1...14).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let input: [String: Any] = ["file_path": "/repo/notes.txt", "content": content]
        XCTAssertEqual(TerminalText.resultLines(tool: "Write", output: "File created successfully", input: input),
                       ["Wrote 14 lines to notes.txt"])
    }

    func testAFailedEditStillReadsItsError() {
        let input: [String: Any] = ["file_path": "/repo/notes.txt", "old_string": "a", "new_string": "b"]
        let lines = TerminalText.resultLines(tool: "Edit", output: "Error: String to replace not found in file.", input: input)
        XCTAssertEqual(lines, ["Error: String to replace not found in file."])
    }

    func testAnEditWithUnreadableInputFallsBackToItsOutput() {
        let input: [String: Any] = ["file_path": "/repo/notes.txt"]
        XCTAssertEqual(TerminalText.resultLines(tool: "Edit", output: edited, input: input), [edited])
    }

    func testTheDiffPreviewMarksRemovedAndAddedLinesAndFoldsTheRest() {
        let diff = EditDiff(tool: "Edit", input: ["old_string": "a\nb", "new_string": "c\nd"])!
        XCTAssertEqual(TerminalText.diffPreview(diff), ["- a", "- b", "+ c", "… +1 line (click to expand)"])
    }

    // MARK: - One typeface

    @MainActor
    func testARenderedReplyIsSetEntirelyInAMonospacedFontWithItsBoldKept() {
        let rendered = MarkdownRenderer.render("Plain and **bold** and `code`", isDark: false)
        let mono = TerminalStyle.monospaced(rendered)
        var fonts: [(String, NSFont)] = []
        mono.enumerateAttribute(.font, in: NSRange(location: 0, length: mono.length)) { value, range, _ in
            if let font = value as? NSFont { fonts.append(((mono.string as NSString).substring(with: range), font)) }
        }
        XCTAssertTrue(fonts.allSatisfy { $0.1.isFixedPitch }, "every run is monospaced")
        let bold = fonts.first { $0.0.contains("bold") }?.1
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true, "bold stays bold")
        let plain = fonts.first { $0.0.contains("Plain") }?.1
        XCTAssertFalse(plain?.fontDescriptor.symbolicTraits.contains(.bold) == true, "plain stays plain")
        XCTAssertEqual(mono.string, rendered.string, "only the fonts change, never the text")
    }
}
