import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Kiteloop

/// Coverage for the type an image in the chat is copied and saved under. The media
/// type the stream reported is gone by the time `ImageContentView` sees the bytes,
/// so both the pasteboard type and the offered filename are read off the bytes —
/// `imageType(for:)` and `saveFilename(for:)`, which the Copy Image button and
/// `saveImage` are the only callers of.
final class ImageContentViewTypeTests: XCTestCase {

    // MARK: - Sniffing the bytes

    func testPNGBytesSniffAsPNG() throws {
        XCTAssertEqual(ImageContentView.imageType(for: try bytes(.png)), .png)
    }

    func testJPEGBytesSniffAsJPEG() throws {
        XCTAssertEqual(ImageContentView.imageType(for: try bytes(.jpeg)), .jpeg)
    }

    func testGIFBytesSniffAsGIF() throws {
        XCTAssertEqual(ImageContentView.imageType(for: try bytes(.gif)), .gif)
    }

    // MARK: - Nothing recognisable

    /// Bytes that are not an image, and no bytes at all, fall back to PNG rather than
    /// trapping — the view renders "Failed to decode image" for these, but the statics
    /// still have to answer.
    func testUnrecognisedAndEmptyBytesFallBackToPNG() {
        let notAnImage = Data("this is not an image, it is a sentence".utf8)

        XCTAssertEqual(ImageContentView.imageType(for: notAnImage), .png)
        XCTAssertEqual(ImageContentView.imageType(for: Data()), .png)
        XCTAssertEqual(ImageContentView.saveFilename(for: notAnImage), "image.png")
        XCTAssertEqual(ImageContentView.saveFilename(for: Data()), "image.png")
    }

    // MARK: - The name the save panel offers

    func testSaveFilenameCarriesTheRealExtension() throws {
        XCTAssertEqual(ImageContentView.saveFilename(for: try bytes(.png)), "image.png")
        XCTAssertEqual(ImageContentView.saveFilename(for: try bytes(.jpeg)), "image.jpeg")
        XCTAssertEqual(ImageContentView.saveFilename(for: try bytes(.gif)), "image.gif")
    }

    // MARK: - What reaches the pasteboard

    /// The Copy Image button declares the sniffed type, so JPEG bytes go out as
    /// `public.jpeg` and are read back by a reader asking for that type — not as
    /// `.png`, which is what every image used to be declared as.
    func testPasteboardTypeIsTheSniffedOne() throws {
        let jpeg = try bytes(.jpeg)
        let pasteboard = NSPasteboard(name: .init("kiteloop.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let type = NSPasteboard.PasteboardType(ImageContentView.imageType(for: jpeg).identifier)
        pasteboard.setData(jpeg, forType: type)

        XCTAssertEqual(type.rawValue, UTType.jpeg.identifier)
        XCTAssertNotEqual(type, .png)
        XCTAssertEqual(pasteboard.data(forType: type), jpeg)
    }

    // MARK: - Writing the file

    /// A folder that refuses the write yields a message naming the file, so Save As…
    /// can say so instead of closing as if the image were saved.
    func testWriteIntoAnUnwritableFolderNamesTheFile() throws {
        let folder = try makeTemporaryDirectory(prefix: "image-save-refused")
        let path = folder.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let url = folder.appending(path: "refused.png")

        let message = ImageContentView.writeImage(try bytes(.png), to: url)

        XCTAssertTrue(try XCTUnwrap(message).contains("refused.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    func testWriteIntoAWritableFolderSucceedsAndLeavesTheBytes() throws {
        let folder = try makeTemporaryDirectory(prefix: "image-save")
        let url = folder.appending(path: "saved.png")
        let png = try bytes(.png)

        XCTAssertNil(ImageContentView.writeImage(png, to: url))
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    // MARK: - Writing the file Open in Preview opens

    func testImageToOpenKeepsItsFormatTheFolderAndTheBytes() throws {
        let folder = try makeTemporaryDirectory(prefix: "image-open")
        let jpeg = try bytes(.jpeg)
        let png = try bytes(.png)

        let jpegURL = try ImageContentView.writeImageToOpen(jpeg, in: folder).get()
        let pngURL = try ImageContentView.writeImageToOpen(png, in: folder).get()

        XCTAssertTrue(["jpg", "jpeg"].contains(jpegURL.pathExtension))
        XCTAssertEqual(pngURL.pathExtension, "png")
        XCTAssertEqual(jpegURL.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(pngURL.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: jpegURL), jpeg)
        XCTAssertEqual(try Data(contentsOf: pngURL), png)
    }

    /// Opening the same image twice writes two files, so the second never replaces the
    /// first while the viewer still has it open.
    func testImageToOpenTwiceWritesTwoFiles() throws {
        let folder = try makeTemporaryDirectory(prefix: "image-open-twice")
        let png = try bytes(.png)

        let first = try ImageContentView.writeImageToOpen(png, in: folder).get()
        let second = try ImageContentView.writeImageToOpen(png, in: folder).get()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), png)
        XCTAssertEqual(try Data(contentsOf: second), png)
    }

    func testImageToOpenInAMissingFolderNamesTheFile() throws {
        let missing = try makeTemporaryDirectory(prefix: "image-open-missing").appending(path: "gone")

        switch ImageContentView.writeImageToOpen(try bytes(.png), in: missing) {
        case .success(let url):
            XCTFail("expected a failure, got \(url)")
        case .failure(let failure):
            XCTAssertTrue(failure.message.contains(".png"))
            XCTAssertTrue(failure.message.contains("could not be saved"))
        }
    }

    // MARK: - Helpers

    /// Real bytes in `format`, encoded here rather than checked in as a fixture.
    private func bytes(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                rep.setColor(.systemTeal, atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: format, properties: [:]))
    }
}
