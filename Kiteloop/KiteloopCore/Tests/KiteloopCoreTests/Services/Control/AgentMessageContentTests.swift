import XCTest
@testable import KiteloopCore

/// A phone message's body: text, images, or both — and the refusals that say
/// why anything else is not one.
final class AgentMessageContentTests: XCTestCase {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func attachment(_ mediaType: String = "image/png", data: Data? = nil) -> [String: Any] {
        ["filename": "screenshot.png", "mediaType": mediaType, "data": (data ?? png).base64EncodedString()]
    }

    func testTextAloneIsAMessage() throws {
        let content = try AgentMessageContent.parse(["message": "hi"]).get()

        XCTAssertEqual(content.text, "hi")
        XCTAssertTrue(content.attachments.isEmpty)
    }

    func testAnImageCarriesItsBytesAndType() throws {
        let content = try AgentMessageContent.parse(["message": "look", "attachments": [attachment()]]).get()

        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.attachments.first?.data, png)
        XCTAssertEqual(content.attachments.first?.mimeType, "image/png")
    }

    func testAnImageAloneIsAMessage() throws {
        let content = try AgentMessageContent.parse(["attachments": [attachment()]]).get()

        XCTAssertEqual(content.text, "")
        XCTAssertEqual(content.attachments.count, 1)
    }

    func testNeitherTextNorImageIs400() {
        XCTAssertEqual(refusal(["message": "  "])?.status, 400)
    }

    func testANonImageIs415() {
        XCTAssertEqual(refusal(["message": "x", "attachments": [attachment("application/pdf")]])?.status, 415)
    }

    func testAnImageOverTheModelsLimitIs413() {
        let big = Data(count: ChatAttachment.maxImageBytes + 1)
        XCTAssertEqual(refusal(["message": "x", "attachments": [attachment(data: big)]])?.status, 413)
    }

    func testDataThatIsNotBase64Is400() {
        let bad: [String: Any] = ["filename": "a.png", "mediaType": "image/png", "data": "%%%"]
        XCTAssertEqual(refusal(["message": "x", "attachments": [bad]])?.status, 400)
    }

    private func refusal(_ json: [String: Any]) -> AgentMessageContent.Refusal? {
        if case .failure(let refusal) = AgentMessageContent.parse(json) { return refusal }
        return nil
    }
}
