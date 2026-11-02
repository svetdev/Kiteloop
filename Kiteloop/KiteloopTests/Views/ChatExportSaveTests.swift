import XCTest
@testable import Kiteloop

/// Export Chat… writes the conversation's Markdown where the save panel
/// pointed; a write that fails comes back as the message the window shows.
@MainActor
final class ChatExportSaveTests: XCTestCase {

    func testTheChatIsWrittenToTheChosenFile() throws {
        let url = try makeTemporaryDirectory(prefix: "chat-export").appending(path: "Planning.md")
        let markdown = "# Planning\n\n**You:** ship it?\n"

        XCTAssertNil(MainWindow.saveChatExport(markdown, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), markdown)
    }

    /// Saving over an existing file replaces it, as the save panel's Replace
    /// promised.
    func testSavingOverAnExistingFileReplacesIt() throws {
        let url = try makeTemporaryDirectory(prefix: "chat-export").appending(path: "Planning.md")
        try "an older export".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(MainWindow.saveChatExport("# Planning\n", to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Planning\n")
    }

    /// A write that fails is shown, not swallowed: the message names the file.
    func testAFailedWriteNamesTheFileItCouldNotSave() throws {
        let url = try makeTemporaryDirectory(prefix: "chat-export")
            .appending(path: "gone/Planning.md")

        let message = try XCTUnwrap(MainWindow.saveChatExport("# Planning\n", to: url))

        XCTAssertTrue(message.hasPrefix("Planning.md could not be saved: "), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
