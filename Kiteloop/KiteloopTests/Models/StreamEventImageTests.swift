import XCTest
@testable import Kiteloop

final class StreamEventImageTests: XCTestCase {
    func testParseImageContentBlock() throws {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]}}
        """
        let event = try StreamEvent.parse(json)
        guard case .image(let base64Data, let mimeType) = event else {
            XCTFail("Expected image event, got \(event)"); return
        }
        XCTAssertEqual(base64Data, "iVBORw0KGgo=")
        XCTAssertEqual(mimeType, "image/png")
    }

    func testImageBlockParsedBeforeTextBlock() throws {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"AAAA"}},{"type":"text","text":"Here is the image"}]}}
        """
        let event = try StreamEvent.parse(json)
        guard case .image(let base64Data, let mimeType) = event else {
            XCTFail("Expected image event to take priority, got \(event)"); return
        }
        XCTAssertEqual(base64Data, "AAAA")
        XCTAssertEqual(mimeType, "image/jpeg")
    }

    func testImageBlockWithJPEGMimeType() throws {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9j/4AAQ"}}]}}
        """
        let event = try StreamEvent.parse(json)
        guard case .image(_, let mimeType) = event else {
            XCTFail("Expected image event"); return
        }
        XCTAssertEqual(mimeType, "image/jpeg")
    }
}
