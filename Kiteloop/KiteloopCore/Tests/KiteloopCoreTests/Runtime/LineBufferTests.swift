import XCTest
@testable import KiteloopCore

final class LineBufferTests: XCTestCase {
    func testSplitsCompleteLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\nb\nc\n".utf8)), ["a", "b", "c"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testHoldsPartialLineUntilNewlineArrives() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"type\":\"as".utf8)), [])
        XCTAssertEqual(buffer.append(Data("sistant\"}\n".utf8)), ["{\"type\":\"assistant\"}"])
    }

    func testReassemblesLineSplitAcrossManyChunks() {
        let line = "{\"type\":\"result\",\"subtype\":\"success\"}"
        var buffer = LineBuffer()

        var lines: [String] = []
        for byte in Data((line + "\n").utf8) {
            lines += buffer.append(Data([byte]))
        }

        XCTAssertEqual(lines, [line])
    }

    /// A read boundary can fall between the bytes of a multi-byte character.
    /// Decoding each chunk on its own fails there, which used to drop the whole
    /// chunk — every complete line in it included.
    func testSplitMultiByteCharacterDoesNotDropSurroundingLines() {
        var buffer = LineBuffer()
        let payload = Data("before\n{\"text\":\"héllo 🚀\"}\nafter\n".utf8)

        // Cut inside the rocket's 4-byte UTF-8 sequence.
        guard let rocketStart = payload.firstIndex(of: 0xF0) else {
            return XCTFail("expected a 4-byte UTF-8 lead byte in the payload")
        }
        let cut = payload.index(rocketStart, offsetBy: 2)

        var lines = buffer.append(Data(payload[..<cut]))
        lines += buffer.append(Data(payload[cut...]))

        XCTAssertEqual(lines, ["before", "{\"text\":\"héllo 🚀\"}", "after"])
    }

    func testSkipsEmptyLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\n\n\nb\n".utf8)), ["a", "b"])
    }

    func testStripsCarriageReturn() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\r\nb\r\n".utf8)), ["a", "b"])
    }

    func testFlushReturnsUnterminatedTrailingLine() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("done\ntrailing".utf8)), ["done"])
        XCTAssertEqual(buffer.flush(), "trailing")
        XCTAssertNil(buffer.flush())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFlushReturnsNilWhenNothingBuffered() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("done\n".utf8)), ["done"])
        XCTAssertNil(buffer.flush())
    }

    func testDropsInvalidUTF8LineButKeepsTheRest() {
        var buffer = LineBuffer()
        var payload = Data("good\n".utf8)
        payload.append(contentsOf: [0xFF, 0xFE])
        payload.append(contentsOf: Data("\nalso good\n".utf8))

        XCTAssertEqual(buffer.append(payload), ["good", "also good"])
    }
}
