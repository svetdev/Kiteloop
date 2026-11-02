import XCTest
@testable import KiteloopCore

final class AnyCodableTests: XCTestCase {
    func testEncodeDecodeString() throws {
        let value = AnyCodable.string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "\"hello\"")
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeInt() throws {
        let value = AnyCodable.int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "42")
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeDouble() throws {
        let value = AnyCodable.double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeBool() throws {
        let value = AnyCodable.bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "true")
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeArray() throws {
        let value = AnyCodable.array([.string("a"), .int(1)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeDictionary() throws {
        let value = AnyCodable.dictionary(["key": .string("val"), "num": .int(5)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeDecodeNull() throws {
        let value = AnyCodable.null
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "null")
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testStringValue() {
        XCTAssertEqual(AnyCodable.string("hello").stringValue, "hello")
        XCTAssertEqual(AnyCodable.int(42).stringValue, "42")
        XCTAssertEqual(AnyCodable.bool(true).stringValue, "true")
        XCTAssertEqual(AnyCodable.null.stringValue, nil)
    }

    func testDictionaryRoundTrip() throws {
        let state: [String: AnyCodable] = [
            "name": .string("kiteloop"),
            "count": .int(3),
            "items": .array([.string("a"), .string("b")])
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
