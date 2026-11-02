import UIKit
import XCTest
@testable import KiteloopMobile

/// A photo is scaled to the edge a model looks at and sent as JPEG, so a
/// full-resolution screenshot fits the Mac's request limit.
final class PhotoAttachmentTests: XCTestCase {
    private func png(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testALargePhotoIsScaledToTheModelsEdgeAndFitsTheRequestLimit() throws {
        let photo = try XCTUnwrap(PhotoAttachment.prepared(from: png(width: 4032, height: 3024)))
        let image = try XCTUnwrap(UIImage(data: photo.jpeg))

        XCTAssertEqual(max(image.size.width, image.size.height), PhotoAttachment.maxEdge)
        XCTAssertLessThan(photo.body["data"].map { ($0 as? String)?.utf8.count ?? 0 } ?? 0, 2 * 1024 * 1024)
    }

    func testASmallPhotoIsNotEnlarged() {
        XCTAssertEqual(PhotoAttachment.fittedSize(CGSize(width: 800, height: 600)), CGSize(width: 800, height: 600))
    }

    func testTheAspectRatioIsKept() {
        XCTAssertEqual(PhotoAttachment.fittedSize(CGSize(width: 3136, height: 1568)), CGSize(width: 1568, height: 784))
    }

    func testDataThatIsNotAnImageIsRefused() {
        XCTAssertNil(PhotoAttachment.prepared(from: Data("not an image".utf8)))
    }

    func testTheBodyIsWhatTheMacTakes() throws {
        let photo = try XCTUnwrap(PhotoAttachment.prepared(from: png(width: 10, height: 10)))

        XCTAssertEqual(photo.body["mediaType"] as? String, "image/jpeg")
        XCTAssertEqual(photo.body["filename"] as? String, "photo.jpg")
        XCTAssertEqual((photo.body["data"] as? String).flatMap { Data(base64Encoded: $0) }, photo.jpeg)
    }
}
