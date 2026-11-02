import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import KiteloopCore

/// `ChatAttachment.read(contentsOf:)` is the one door a file walks through to
/// become an attachment — the paperclip's and the paste/drop path's alike. These
/// cases pin what it takes, what it refuses, and that a file over the ceiling is
/// refused by its recorded size rather than by reading it.
final class ChatAttachmentReadTests: XCTestCase {

    func testReadsFileUnderTheCeiling() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "notes.md")
        try Data("hello".utf8).write(to: file)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.filename, "notes.md")
        XCTAssertEqual(attachment.mimeType, "text/markdown")
        XCTAssertEqual(attachment.data, Data("hello".utf8))
    }

    func testRefusesAFileThatIsNotThere() throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appending(path: "gone.txt")

        guard case .failure(let failure) = ChatAttachment.read(contentsOf: missing) else {
            return XCTFail("a missing file must not read as an attachment")
        }
        XCTAssertEqual(failure, .unreadable)
    }

    func testRefusesAFileItHasNoPermissionToRead() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "secret.txt")
        try Data("shh".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        guard case .failure(let failure) = ChatAttachment.read(contentsOf: file) else {
            return XCTFail("an unreadable file must not read as an attachment")
        }
        XCTAssertEqual(failure, .unreadable)
    }

    func testRefusesAFileOverTheCeilingWithTheSizeItFound() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "huge.bin")
        let size = ChatAttachment.maxBytes + 1
        try sparseFile(at: file, ofSize: size)

        guard case .failure(let failure) = ChatAttachment.read(contentsOf: file) else {
            return XCTFail("a file over the ceiling must not read as an attachment")
        }
        XCTAssertEqual(failure, .tooLarge(bytes: size))
    }

    func testAFileExactlyAtTheCeilingIsTaken() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "atlimit.bin")
        try sparseFile(at: file, ofSize: ChatAttachment.maxBytes)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.data.count, ChatAttachment.maxBytes)
    }

    /// The refusal comes from the recorded size, so a file whose *bytes* cannot be
    /// read at all is still refused as too large: the reader never reaches them.
    func testTooLargeIsDecidedWithoutReadingTheContents() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "huge-and-unreadable.bin")
        let size = ChatAttachment.maxBytes + 1
        try sparseFile(at: file, ofSize: size)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        guard case .failure(let failure) = ChatAttachment.read(contentsOf: file) else {
            return XCTFail("a file over the ceiling must not read as an attachment")
        }
        XCTAssertEqual(failure, .tooLarge(bytes: size))
    }

    /// SVG is markup, not a picture a model's image block can take: it reads as
    /// text so the agent gets the source rather than a refused media type.
    func testSVGIsNotAnImageAndReadsAsItsMarkup() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "logo.svg")
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"1\"/></svg>"
        try Data(markup.utf8).write(to: file)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.mimeType, "image/svg+xml", "the file's real type is unchanged")
        XCTAssertFalse(attachment.isImage)
        XCTAssertEqual(attachment.textContent, markup)
    }

    /// Narrowing SVG out must not take a genuine picture format with it.
    func testPictureFormatsAreStillImages() {
        for filename in ["shot.png", "photo.jpg", "photo.jpeg", "anim.gif", "pic.webp"] {
            let attachment = ChatAttachment(
                filename: filename,
                data: Data([0x89, 0x50]),
                mimeType: ChatAttachment.mimeType(for: filename)
            )
            XCTAssertTrue(attachment.isImage, "\(filename) must still be sent as an image")
            XCTAssertNil(attachment.textContent, "\(filename) must not be sent as text")
        }
    }

    /// The `.svg` extension is not a promise that the bytes are text — one that
    /// is not decodable still falls to the binary wording, not to markup.
    func testSVGWhoseBytesAreNotTextIsStillBinary() {
        let attachment = ChatAttachment(
            filename: "broken.svg",
            data: Data(repeating: 0xFF, count: 64),
            mimeType: "image/svg+xml"
        )

        XCTAssertFalse(attachment.isImage)
        XCTAssertNil(attachment.textContent)
    }

    /// A TIFF is a picture the Mac decodes and a model's image block refuses: it
    /// must arrive as PNG rather than as a `[binary file]` placeholder.
    func testATIFFIsConvertedToPNG() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "scan.tiff")
        try writeImage(to: file, as: .tiff)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertNil(attachment.textContent)
    }

    /// The same branch a HEIC photo takes: the conversion is decided from the
    /// bytes, so a BMP — another type outside the four accepted media types, and
    /// one every Mac can encode — converts identically.
    func testABMPIsConvertedToPNG() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "photo.bmp")
        try writeImage(to: file, as: .bmp)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    /// A format the image block already takes is handed on untouched — no
    /// re-encoding, no recompression.
    func testAnAlreadyAcceptedImageIsNotReEncoded() throws {
        let directory = try makeTemporaryDirectory()
        for (name, type) in [("shot.png", UTType.png), ("photo.jpeg", UTType.jpeg)] {
            let file = directory.appending(path: name)
            try writeImage(to: file, as: type)
            let onDisk = try Data(contentsOf: file)

            let attachment = try ChatAttachment.read(contentsOf: file).get()

            XCTAssertEqual(attachment.data, onDisk, "\(name) must arrive byte-identical")
            XCTAssertEqual(attachment.mimeType, ChatAttachment.mimeType(for: name))
        }
    }

    /// Text is not a picture ImageIO recognises, so the conversion never sees it.
    func testAPlainTextFileIsUntouched() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "notes.txt")
        let bytes = Data("one\ntwo\n".utf8)
        try bytes.write(to: file)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.data, bytes)
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.textContent, "one\ntwo\n")
    }

    /// An image larger than a model looks at is downscaled to `maxImageEdge` on
    /// its long edge, keeping its shape.
    func testALargeImageIsDownscaledToTheLongestEdgeAModelLooksAt() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "wide.png")
        try writeImage(to: file, as: .png, width: 3000, height: 1000)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        let (width, height) = try pixelSize(of: attachment.data)
        XCTAssertEqual(max(width, height), ChatAttachment.maxImageEdge)
        XCTAssertEqual(Double(height), Double(width) / 3, accuracy: 1)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.filename, "wide.png")
    }

    /// Noise does not compress: its PNG stays over the limit a model accepts, so
    /// it goes as JPEG, and the name says so.
    func testAnImageWhosePNGIsOverTheLimitIsSentAsJPEG() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "noise.png")
        try writeImage(to: file, as: .png, width: 1568, height: 1568, noise: true)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, ChatAttachment.maxImageBytes)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertLessThanOrEqual(attachment.data.count, ChatAttachment.maxImageBytes)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.filename, "noise.jpg")
        XCTAssertEqual(Array(attachment.data.prefix(2)), [0xFF, 0xD8])
    }

    /// Within both limits an image is handed on byte for byte.
    func testASmallPNGIsNotResizedOrReEncoded() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "small.png")
        try writeImage(to: file, as: .png, width: 800, height: 600)
        let onDisk = try Data(contentsOf: file)

        let attachment = try ChatAttachment.read(contentsOf: file).get()

        XCTAssertEqual(attachment.data, onDisk)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.filename, "small.png")
    }

    /// The pixel size of encoded image `data`.
    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    /// An image of `type` on disk, so a conversion has something real to read:
    /// flat grey, or random noise that no encoder can compress.
    private func writeImage(
        to url: URL, as type: UTType, width: Int = 2, height: Int = 2, noise: Bool = false
    ) throws {
        var pixels = [UInt8](repeating: 0xA0, count: width * height * 4)
        if noise {
            var generator = SystemRandomNumberGenerator()
            for index in pixels.indices where index % 4 != 3 { pixels[index] = generator.next() }
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 0xFF }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try XCTUnwrap(context?.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A file of `size` bytes that costs no disk: the tests above need the size the
    /// file system records, not the bytes.
    private func sparseFile(at url: URL, ofSize size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}
