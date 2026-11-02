import SwiftUI
import XCTest
@testable import Kiteloop

/// Coverage for the icon and colour a tool row wears in the chat transcript.
/// `ToolAppearance` is the only source of both, and `ToolCallView.body` its only
/// caller. The CLI sends a delegated subagent call under either of two names,
/// `Agent` and `Task`, so both must draw as delegation rather than falling to the
/// default arm — whose orange is the colour this view reserves for a file write.
final class ToolAppearanceTests: XCTestCase {

    // MARK: - Delegation under either name

    func testTaskWearsTheSameIconAsAgent() {
        XCTAssertEqual(ToolAppearance.icon(for: "Task"), ToolAppearance.icon(for: "Agent"))
    }

    func testTaskWearsTheSameTintAsAgent() {
        XCTAssertEqual(ToolAppearance.tint(for: "Task"), ToolAppearance.tint(for: "Agent"))
    }

    func testTaskIsNotDrawnAsAFileWrite() {
        XCTAssertNotEqual(ToolAppearance.tint(for: "Task"), ToolAppearance.tint(for: "Write"))
    }

    // MARK: - Everything else is unchanged

    func testFamiliarToolsKeepTheirIcons() {
        XCTAssertEqual(ToolAppearance.icon(for: "Read"), "doc.text")
        XCTAssertEqual(ToolAppearance.icon(for: "Bash"), "terminal")
        XCTAssertEqual(ToolAppearance.icon(for: "Write"), "square.and.pencil")
        XCTAssertEqual(ToolAppearance.icon(for: "Agent"), "person.2")
    }

    func testFamiliarToolsKeepTheirTints() {
        XCTAssertEqual(ToolAppearance.tint(for: "Read"), .blue)
        XCTAssertEqual(ToolAppearance.tint(for: "Bash"), Color(nsColor: .secondaryLabelColor))
        XCTAssertEqual(ToolAppearance.tint(for: "Write"), .orange)
        XCTAssertEqual(ToolAppearance.tint(for: "Agent"), .teal)
    }

    /// A name the view does not know still falls to the generic wrench.
    func testAnUnknownToolStillFallsToTheDefault() {
        XCTAssertEqual(ToolAppearance.icon(for: "NoSuchTool"), "wrench")
        XCTAssertEqual(ToolAppearance.tint(for: "NoSuchTool"), .orange)
    }
}
