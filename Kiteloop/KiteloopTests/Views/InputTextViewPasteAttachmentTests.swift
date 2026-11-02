import AppKit
import KiteloopCore
import XCTest
@testable import Kiteloop

/// A screenshot or a file pasted into the chat input, or dropped onto it, is
/// attached; plain text is still pasted as text.
@MainActor
final class InputTextViewPasteAttachmentTests: XCTestCase {

    /// A pasteboard of this test's own — never the general one, which belongs to
    /// whoever is using the machine while the suite runs.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kiteloop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func makeImageData(png: Bool) throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        guard png else { return tiff }
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    private func assertIsPNG(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not PNG data", file: file, line: line)
    }

    /// A file of `size` bytes that costs no disk — only its recorded size matters.
    private func writeSparseFile(at url: URL, ofSize size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    func testAFileURLIsHandedOutAsItsURLNotReadHere() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let file = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])

        XCTAssertEqual(InputTextView.fileURLs(from: pasteboard).map(\.lastPathComponent), ["note.txt"])
        XCTAssertNil(InputTextView.attachments(from: pasteboard), "a file came back as pasted image data")
    }

    func testADirectoryOnThePasteboardIsSkipped() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let folder = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.md")
        try Data("# hi".utf8).write(to: file)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([folder as NSURL, file as NSURL])

        XCTAssertEqual(InputTextView.fileURLs(from: pasteboard).map(\.lastPathComponent), ["note.md"])
    }

    /// A file too large to attach is still taken — handed to the bar, which says
    /// why it cannot attach it — never left for the text view to type its path.
    func testAFileOverTheAttachmentCeilingIsTakenAndHandedToTheBar() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let huge = dir.appendingPathComponent("huge.bin")
        try writeSparseFile(at: huge, ofSize: ChatAttachment.maxBytes + 1)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([huge as NSURL])

        let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var files: [String] = []
        var attached: [ChatAttachment] = []
        input.onFileURLs = { files.append(contentsOf: $0.map(\.lastPathComponent)) }
        input.onAttachments = { attached.append(contentsOf: $0) }

        XCTAssertTrue(input.takeAttachments(from: pasteboard), "the path would be typed into the message")
        XCTAssertEqual(files, ["huge.bin"])
        XCTAssertTrue(attached.isEmpty)
        XCTAssertEqual(input.string, "")
    }

    func testAReadableFileAndAnOverCeilingFileAreBothHandedToTheBar() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let note = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let huge = dir.appendingPathComponent("huge.bin")
        try writeSparseFile(at: huge, ofSize: ChatAttachment.maxBytes + 1)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([note as NSURL, huge as NSURL])

        let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var files: [String] = []
        input.onFileURLs = { files.append(contentsOf: $0.map(\.lastPathComponent)) }

        XCTAssertTrue(input.takeAttachments(from: pasteboard))
        XCTAssertEqual(files, ["note.txt", "huge.bin"])
    }

    func testAPasteboardOfOnlyDirectoriesHoldsNothingToAttach() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let folder = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([folder as NSURL])

        let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var files: [URL] = []
        input.onFileURLs = { files.append(contentsOf: $0) }

        XCTAssertTrue(InputTextView.fileURLs(from: pasteboard).isEmpty)
        XCTAssertNil(InputTextView.attachments(from: pasteboard))
        XCTAssertFalse(input.takeAttachments(from: pasteboard), "a directory-only drop still types its path")
        XCTAssertTrue(files.isEmpty)
    }

    func testCopiedScreenshotBecomesOnePastedImage() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(try makeImageData(png: true), forType: .png)

        let attachments = try XCTUnwrap(InputTextView.attachments(from: pasteboard))

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.filename, "Pasted image.png")
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
        XCTAssertTrue(attachments.first?.isImage == true)
        assertIsPNG(try XCTUnwrap(attachments.first?.data))
    }

    func testTiffImageDataIsAttachedAsPNG() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(try makeImageData(png: false), forType: .tiff)

        let attachments = try XCTUnwrap(InputTextView.attachments(from: pasteboard))

        XCTAssertEqual(attachments.map(\.filename), ["Pasted image.png"])
        assertIsPNG(try XCTUnwrap(attachments.first?.data))
    }

    /// A full-screen Retina capture is larger than a model looks at: it is
    /// downscaled before it is staged, not sent at a size the model refuses.
    func testALargePastedTiffIsDownscaledToTheLongestEdgeAModelLooksAt() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3024, pixelsHigh: 1964, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pasteboard = makePasteboard()
        pasteboard.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)

        let attachments = try XCTUnwrap(InputTextView.attachments(from: pasteboard))

        XCTAssertEqual(attachments.count, 1)
        let pasted = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(attachments.first?.data)))
        XCTAssertLessThanOrEqual(max(pasted.pixelsWide, pasted.pixelsHigh), ChatAttachment.maxImageEdge)
    }

    func testImageDataAlongsideTextHoldsNothingToAttach() throws {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(try makeImageData(png: true), forType: .png)
        item.setString("a diagram", forType: .string)
        pasteboard.writeObjects([item])

        XCTAssertNil(InputTextView.attachments(from: pasteboard))
    }

    func testPlainTextHoldsNothingToAttachSoPasteInsertsIt() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("/etc/hosts", forType: .string)

        XCTAssertTrue(InputTextView.fileURLs(from: pasteboard).isEmpty)
        XCTAssertNil(InputTextView.attachments(from: pasteboard))
    }

    /// What `paste(_:)` and `performDragOperation(_:)` both call: it hands the
    /// files out and says it handled the pasteboard, or leaves it to the text
    /// view.
    func testTakingAttachmentsHandsFilesOutAndLeavesTextAlone() throws {
        let dir = try makeTemporaryDirectory(prefix: "paste-attachment")
        let file = dir.appendingPathComponent("note.txt")
        try Data("dropped".utf8).write(to: file)
        let files = makePasteboard()
        files.writeObjects([file as NSURL])
        let text = makePasteboard()
        text.setString("just text", forType: .string)

        let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var received: [String] = []
        input.onFileURLs = { received.append(contentsOf: $0.map(\.lastPathComponent)) }
        input.onAttachments = { received.append(contentsOf: $0.map(\.filename)) }

        XCTAssertTrue(input.takeAttachments(from: files))
        XCTAssertEqual(received, ["note.txt"])

        XCTAssertFalse(input.takeAttachments(from: text))
        XCTAssertNil(InputTextView.attachments(from: text))
        XCTAssertEqual(received, ["note.txt"], "plain text was taken as an attachment")
    }
}
