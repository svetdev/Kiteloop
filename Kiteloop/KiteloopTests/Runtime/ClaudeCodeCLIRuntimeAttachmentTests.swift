import XCTest
import KiteloopCore
@testable import Kiteloop

final class ClaudeCodeCLIRuntimeAttachmentTests: XCTestCase {
    func testMessageEncodingPlainText() {
        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "hello", attachments: [])
        let data = result.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "user")
        let message = json["message"] as! [String: Any]
        XCTAssertEqual(message["role"] as? String, "user")
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "hello")
    }

    func testMessageEncodingWithImage() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let attachment = ChatAttachment(filename: "screenshot.png", data: imageData, mimeType: "image/png")

        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "describe", attachments: [attachment])
        let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let message = json["message"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)

        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "describe")

        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = content[1]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, imageData.base64EncodedString())
    }

    func testMessageEncodingWithTextFile() {
        let textData = "func main() {}".data(using: .utf8)!
        let attachment = ChatAttachment(filename: "main.swift", data: textData, mimeType: "text/x-swift")

        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "review this", attachments: [attachment])
        let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let message = json["message"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)

        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "review this")

        XCTAssertEqual(content[1]["type"] as? String, "text")
        let fileContent = content[1]["text"] as! String
        XCTAssertTrue(fileContent.contains("main.swift"))
        XCTAssertTrue(fileContent.contains("func main() {}"))
    }

    func testMessageEncodingWithTextFileHoldingOneBadByte() {
        let textData = Data("before ".utf8) + Data([0xFF]) + Data(" after".utf8)
        let attachment = ChatAttachment(filename: "server.log", data: textData, mimeType: "text/plain")

        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "why", attachments: [attachment])
        let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let message = json["message"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["text"] as? String, "--- server.log ---\nbefore \u{FFFD} after")
    }

    func testMessageEncodingWithNulByteNamesTheFileAsBinary() {
        let binaryData = Data("text".utf8) + Data([0x00]) + Data("more".utf8)
        let attachment = ChatAttachment(filename: "dump.txt", data: binaryData, mimeType: "text/plain")

        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "why", attachments: [attachment])
        let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let message = json["message"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content[1]["text"] as? String, "--- dump.txt ---\n[binary file: dump.txt]")
    }

    func testMessageEncodingSendsSVGAsMarkupBesideARealImage() {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"1\"/></svg>"
        let svg = ChatAttachment(filename: "logo.svg", data: Data(markup.utf8), mimeType: "image/svg+xml")
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let png = ChatAttachment(filename: "shot.png", data: pngData, mimeType: "image/png")

        let result = ClaudeCodeCLIRuntime.buildMultimodalMessage(text: "look", attachments: [svg, png])
        let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        let message = json["message"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 3)

        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "--- logo.svg ---\n\(markup)")

        XCTAssertEqual(content[2]["type"] as? String, "image")
        let source = content[2]["source"] as! [String: Any]
        XCTAssertEqual(source["media_type"] as? String, "image/png")

        XCTAssertFalse(
            result.contains("image/svg+xml"),
            "an SVG must not be sent as an image block the model refuses"
        )
    }

    func testMimeTypeDetection() {
        XCTAssertEqual(ChatAttachment.mimeType(for: "photo.png"), "image/png")
        XCTAssertEqual(ChatAttachment.mimeType(for: "img.jpg"), "image/jpeg")
        XCTAssertEqual(ChatAttachment.mimeType(for: "img.jpeg"), "image/jpeg")
        XCTAssertEqual(ChatAttachment.mimeType(for: "anim.gif"), "image/gif")
        XCTAssertEqual(ChatAttachment.mimeType(for: "pic.webp"), "image/webp")
        XCTAssertEqual(ChatAttachment.mimeType(for: "readme.md"), "text/markdown")
        XCTAssertEqual(ChatAttachment.mimeType(for: "data.json"), "application/json")
        XCTAssertEqual(ChatAttachment.mimeType(for: "app.swift"), "text/x-swift")
        XCTAssertEqual(ChatAttachment.mimeType(for: "unknown.xyz"), "application/octet-stream")
    }
}
