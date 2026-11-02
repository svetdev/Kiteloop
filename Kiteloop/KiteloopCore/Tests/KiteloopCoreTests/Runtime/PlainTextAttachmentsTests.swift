import XCTest
@testable import KiteloopCore

/// The folding the Ollama and Copilot runtimes share: an attachment either
/// reaches the model as text under its filename, or is named in the turn as
/// something that could not be sent. What it must never do is disappear.
final class PlainTextAttachmentsTests: XCTestCase {
    func testNoAttachmentsLeavesTheTurnExactlyAsItWas() {
        XCTAssertEqual(
            PlainTextAttachments.fold(text: "hello", attachments: []),
            "hello",
            "a send with nothing attached must produce the message byte for byte"
        )
        XCTAssertEqual(PlainTextAttachments.fold(text: "", attachments: []), "")
    }

    func testTextAttachmentIsFoldedInUnderItsFilename() {
        let attachment = ChatAttachment(
            filename: "main.swift",
            data: Data("func main() {}".utf8),
            mimeType: "text/x-swift"
        )

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "review this", attachments: [attachment]),
            """
            review this

            --- main.swift ---
            func main() {}
            """
        )
    }

    func testSeveralAttachmentsEachGetTheirOwnHeadedSection() {
        let first = ChatAttachment(filename: "a.txt", data: Data("A".utf8), mimeType: "text/plain")
        let second = ChatAttachment(filename: "b.txt", data: Data("B".utf8), mimeType: "text/plain")

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "both", attachments: [first, second]),
            """
            both

            --- a.txt ---
            A

            --- b.txt ---
            B
            """
        )
    }

    func testAttachmentWithNoMessageTextStandsAlone() {
        let attachment = ChatAttachment(filename: "notes.md", data: Data("# Notes".utf8), mimeType: "text/markdown")

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "", attachments: [attachment]),
            """
            --- notes.md ---
            # Notes
            """,
            "an empty message must not leave a blank section ahead of the file"
        )
    }

    func testEmptyFileIsStillNamedInTheTurn() {
        let attachment = ChatAttachment(filename: "empty.txt", data: Data(), mimeType: "text/plain")

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "look", attachments: [attachment]),
            """
            look

            --- empty.txt ---

            """,
            "a zero-byte file is empty, not unreadable — it is named with nothing under it"
        )
    }

    func testImageIsNamedAsSomethingTheModelCannotSee() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let attachment = ChatAttachment(filename: "screenshot.png", data: png, mimeType: "image/png")

        let folded = PlainTextAttachments.fold(text: "describe", attachments: [attachment])

        XCTAssertEqual(
            folded,
            """
            describe

            --- screenshot.png ---
            [not sent: this model cannot see images]
            """
        )
        XCTAssertFalse(
            folded.contains(png.base64EncodedString()),
            "an image must be reported as missing, not smuggled into the prompt as base64"
        )
    }

    func testSVGIsFoldedInAsItsMarkupRatherThanNamedAsAnImage() {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"1\"/></svg>"
        let attachment = ChatAttachment(
            filename: "logo.svg",
            data: Data(markup.utf8),
            mimeType: "image/svg+xml"
        )

        let folded = PlainTextAttachments.fold(text: "what shape", attachments: [attachment])

        XCTAssertEqual(
            folded,
            """
            what shape

            --- logo.svg ---
            \(markup)
            """
        )
        XCTAssertFalse(
            folded.contains("cannot see images"),
            "markup the model can read must not be withheld as if it were a picture"
        )
    }

    /// A `.svg` name over bytes that are not text is still binary: the extension
    /// does not license sending mojibake as markup.
    func testSVGWhoseBytesAreNotTextKeepsTheBinaryWording() {
        let attachment = ChatAttachment(
            filename: "broken.svg",
            data: Data(repeating: 0xFF, count: 64),
            mimeType: "image/svg+xml"
        )

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "", attachments: [attachment]),
            """
            --- broken.svg ---
            [not sent: this file is not text this model can read]
            """
        )
    }

    func testBytesThatAreNotUTF8AreNamedRatherThanTurnedIntoMojibake() {
        // Lone continuation bytes: valid nowhere in UTF-8.
        let attachment = ChatAttachment(
            filename: "payload.bin",
            data: Data([0xFF, 0xFE, 0x80, 0x00]),
            mimeType: "application/octet-stream"
        )

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "what is this", attachments: [attachment]),
            """
            what is this

            --- payload.bin ---
            [not sent: this file is not text this model can read]
            """
        )
    }

    func testTextWithOneBadByteIsSentWithAReplacementCharacterInItsPlace() {
        let attachment = ChatAttachment(
            filename: "server.log",
            data: Data("before ".utf8) + Data([0xFF]) + Data(" after".utf8),
            mimeType: "text/plain"
        )

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "why", attachments: [attachment]),
            """
            why

            --- server.log ---
            before \u{FFFD} after
            """,
            "one byte that is not UTF-8 must not withhold the text around it"
        )
    }

    func testTextHoldingANulByteIsStillWithheld() {
        let attachment = ChatAttachment(
            filename: "dump.txt",
            data: Data("plain text".utf8) + Data([0x00]) + Data("more text".utf8),
            mimeType: "text/plain"
        )

        XCTAssertEqual(
            PlainTextAttachments.fold(text: "", attachments: [attachment]),
            """
            --- dump.txt ---
            [not sent: this file is not text this model can read]
            """
        )
    }

    func testMostlyInvalidBytesAreStillWithheld() {
        let data = Data("header ".utf8) + Data(repeating: 0xFF, count: 64)
        let attachment = ChatAttachment(filename: "blob.dat", data: data, mimeType: "application/octet-stream")

        XCTAssertNil(attachment.textContent)
    }
}
