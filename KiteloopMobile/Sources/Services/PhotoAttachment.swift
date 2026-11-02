import UIKit

/// A photo picked on the phone, made ready to go to an agent: scaled so its
/// long edge is at most the 1568 pixels a model looks at, and re-encoded as
/// JPEG, which keeps a screenshot well under the 2 MB the Mac takes per request.
struct PhotoAttachment: Equatable {
    let filename: String
    let jpeg: Data

    /// The longest edge a model looks at (`ChatAttachment.maxImageEdge` on the Mac).
    static let maxEdge: CGFloat = 1568
    static let quality: CGFloat = 0.8

    /// The picked image's bytes, scaled and re-encoded; nil for data that is
    /// not an image.
    static func prepared(from data: Data, filename: String = "photo.jpg") -> PhotoAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        let size = fittedSize(image.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = scaled.jpegData(compressionQuality: quality) else { return nil }
        return PhotoAttachment(filename: filename, jpeg: jpeg)
    }

    /// `size` shrunk to fit `maxEdge` on its long side; never enlarged.
    static func fittedSize(_ size: CGSize) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxEdge else { return size }
        let factor = maxEdge / longEdge
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    /// The attachment as `POST /v1/agents/message` takes it.
    var body: [String: Any] {
        ["filename": filename, "mediaType": "image/jpeg", "data": jpeg.base64EncodedString()]
    }
}
