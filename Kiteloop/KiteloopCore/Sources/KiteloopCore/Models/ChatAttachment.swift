import Foundation
import ImageIO
import UniformTypeIdentifiers

package struct ChatAttachment: Identifiable, Sendable {
    package let id: UUID
    package let filename: String
    package let data: Data
    package let mimeType: String

    package init(id: UUID = UUID(), filename: String, data: Data, mimeType: String) {
        self.id = id
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }

    /// The media types an image content block actually takes.
    ///
    /// Narrower than the `image/` prefix: `image/svg+xml` is a real media type
    /// for a real picture format, but a model's image block refuses it, and an
    /// SVG is markup a model reads perfectly well as text. So it is not an
    /// image here, and falls through to `textContent`.
    private static let imageMediaTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp"
    ]

    package var isImage: Bool {
        Self.imageMediaTypes.contains(mimeType)
    }

    /// The attachment as text to put in a prompt, or nil when it is not text.
    ///
    /// Decoded leniently, so a file that is text but for a bad or cut-off byte
    /// arrives with U+FFFD in that place rather than not at all. An image, data
    /// holding a NUL byte, or data whose decode is more than 1% replacement
    /// characters (one is always tolerated) is taken as binary.
    package var textContent: String? {
        guard !isImage, !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let scalars = text.unicodeScalars
        let replacements = scalars.lazy.filter { $0 == "\u{FFFD}" }.count
        return replacements > max(1, scalars.count / 100) ? nil : text
    }

    /// Why a file picked for the chat did not become an attachment.
    package enum ReadFailure: Error, Equatable, Sendable {
        /// No permission, a broken alias, a file gone between the panel and the read.
        case unreadable
        /// Over `maxBytes`, with the size the file system recorded for it.
        case tooLarge(bytes: Int)
    }

    /// The largest file the chat will take: big enough for any screenshot or
    /// source file, small enough that reading it whole and base64-encoding it
    /// onto the CLI's stdin does not freeze the app.
    package static let maxBytes = 10 * 1024 * 1024

    /// The largest image a model's image block takes: the API refuses one over
    /// it, and the whole turn fails with it.
    package static let maxImageBytes = 5 * 1024 * 1024

    /// The longest edge, in pixels, a model looks at. A larger image costs
    /// bytes and buys nothing, so it is downscaled to this.
    package static let maxImageEdge = 1568

    /// The attachment at `url`, or why it cannot be one.
    ///
    /// The size the file system records is consulted first, so a file over the
    /// ceiling is refused without a byte of it being read.
    package static func read(contentsOf url: URL) -> Result<ChatAttachment, ReadFailure> {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            return .failure(.tooLarge(bytes: size))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        let filename = url.lastPathComponent
        if let png = pngRendering(of: data) {
            return .success(fittedImage(filename: filename, data: png, mimeType: "image/png"))
        }
        let attachment = ChatAttachment(filename: filename, data: data, mimeType: mimeType(for: filename))
        guard attachment.isImage else { return .success(attachment) }
        return .success(fittedImage(filename: filename, data: data, mimeType: attachment.mimeType))
    }

    /// An image attachment at a size a model accepts: every path that stages
    /// image bytes goes through here.
    ///
    /// An image within both `maxImageEdge` and `maxImageBytes` comes back
    /// untouched, byte for byte. Otherwise it is downscaled so its long edge is
    /// at most `maxImageEdge` and encoded as PNG, or as JPEG when the PNG is
    /// still over `maxImageBytes`; the filename's extension then says which. An
    /// animated GIF within `maxImageBytes` is left alone whatever its size,
    /// because downscaling keeps only its first frame.
    package static func fittedImage(filename: String, data: Data, mimeType: String) -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              needsFitting(source, byteCount: data.count),
              let fitted = fittedEncoding(of: source) else {
            return ChatAttachment(filename: filename, data: data, mimeType: mimeType)
        }
        let ext = fitted.mimeType == "image/jpeg" ? "jpg" : "png"
        let stem = (filename as NSString).deletingPathExtension
        return ChatAttachment(filename: "\(stem).\(ext)", data: fitted.data, mimeType: fitted.mimeType)
    }

    private static func needsFitting(_ source: CGImageSource, byteCount: Int) -> Bool {
        let overBytes = byteCount > maxImageBytes
        if CGImageSourceGetCount(source) > 1 { return overBytes }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return overBytes || max(width, height) > maxImageEdge
    }

    /// The first frame of `source`, its long edge at most `maxImageEdge` and its
    /// orientation applied, as PNG — or as JPEG when the PNG is over `maxImageBytes`.
    private static func fittedEncoding(of source: CGImageSource) -> (data: Data, mimeType: String)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = encoded(image, as: .png) else { return nil }
        if png.count <= maxImageBytes { return (png, "image/png") }
        let jpegOptions = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        return encoded(image, as: .jpeg, options: jpegOptions).map { ($0, "image/jpeg") }
    }

    private static func encoded(_ image: CGImage, as type: UTType, options: CFDictionary? = nil) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// `data` re-encoded as PNG when it is a picture the Mac decodes but a
    /// model's image block will not take — a HEIC photo, a TIFF, a BMP — and nil
    /// for everything else, which keeps the bytes it already has.
    ///
    /// The type is read from the bytes rather than the name, the way
    /// `ImageContentView.imageType(for:)` does, so a HEIC screenshot saved
    /// without an extension converts too. Data that is not a picture at all is
    /// not one ImageIO recognises, and an SVG is deliberately left alone: it
    /// goes through as the markup a model reads.
    private static func pngRendering(of data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              !type.conforms(to: .svg),
              !imageMediaTypes.contains(type.preferredMIMEType ?? ""),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encoded(image, as: .png)
    }

    package static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "swift": return "text/x-swift"
        case "ts", "tsx": return "text/typescript"
        case "js", "jsx": return "text/javascript"
        case "py": return "text/x-python"
        default: return "application/octet-stream"
        }
    }
}
