import XCTest
@testable import Kiteloop

/// The item pages render a groomed field's inline markdown rather than printing
/// its backticks and asterisks.
final class GroomedTextTests: XCTestCase {

    func testBacktickedSpanReadsAsCodeWithoutItsBackticks() {
        let text = GroomedText.attributed("Edit `Services/Foo.swift` first")
        XCTAssertEqual(String(text.characters), "Edit Services/Foo.swift first")
        let code = text.runs.first { String(text[$0.range].characters) == "Services/Foo.swift" }
        XCTAssertEqual(code?.inlinePresentationIntent, .code)
    }

    func testDoubleAsterisksReadAsBoldWithoutTheirAsterisks() {
        let text = GroomedText.attributed("a **bold** word")
        XCTAssertEqual(String(text.characters), "a bold word")
        let bold = text.runs.first { String(text[$0.range].characters) == "bold" }
        XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testNewlinesInAFieldSurvive() {
        let text = GroomedText.attributed("first line\nsecond line\n\nthird")
        XCTAssertEqual(String(text.characters), "first line\nsecond line\n\nthird")
    }

    func testUnbalancedMarkupIsPrintedAsWritten() {
        let text = GroomedText.attributed("a lone ` backtick")
        XCTAssertEqual(String(text.characters), "a lone ` backtick")
    }
}
