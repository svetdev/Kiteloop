import XCTest
@testable import Kiteloop

/// The copy rules in `PanelEmptyState`'s doc comment, asserted against the main
/// surfaces that follow them.
///
/// The rules were written for the companion panels, which all mount the same
/// view, so a call site either followed them or was visibly odd next to its
/// neighbours. The main surfaces are drawn in six different layouts — a sidebar
/// column, a `List` row, a mid-page block, a state with its own button — and
/// there is nothing to look odd next to. These cases are what stands in for
/// that: they read `PanelEmptyState.Copy.mainSurfaces`, which every one of those
/// six layouts takes its words from.
final class PanelEmptyStateCopyTests: XCTestCase {

    private var surfaces: [PanelEmptyState.Copy] { PanelEmptyState.Copy.mainSurfaces }

    /// The six the audit covers: sidebar, chat, backlog, portfolio, memory,
    /// notifications. A seventh added without a case here would still be checked
    /// by every rule below — this only pins the list itself.
    func testEveryMainSurfaceIsListed() {
        XCTAssertEqual(surfaces.count, 6)
        XCTAssertEqual(Set(surfaces.map(\.title)).count, surfaces.count,
                       "Two surfaces sharing a title cannot both be saying what is missing")
    }

    // MARK: - Title

    /// Sentence case, not Title Case: "No traces yet".
    func testTitlesAreSentenceCase() {
        for copy in surfaces {
            let words = copy.title.split(separator: " ")
            XCTAssertFalse(words.isEmpty, "A surface with no title is the bare-title failure at its limit")
            XCTAssertTrue(words[0].first?.isUppercase == true,
                          "\(copy.title): a sentence still opens with a capital")
            for word in words.dropFirst() {
                XCTAssertFalse(word.first?.isUppercase == true,
                               "\(copy.title): '\(word)' is Title Case")
            }
        }
    }

    // MARK: - Message

    /// Never a bare title: every surface says what will appear, or what to do.
    func testMessagesArePresent() {
        for copy in surfaces {
            XCTAssertFalse(copy.message.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(copy.title) shows a bare title")
        }
    }

    /// One sentence, ending in a full stop. The control labels are cut out
    /// first: "New Agent..." and "Open Project..." carry the ellipsis a macOS
    /// control uses to mean "this opens something", not a second sentence.
    func testMessagesAreOneSentence() {
        for copy in surfaces {
            let message = copy.message
            XCTAssertTrue(message.hasSuffix("."), "\(copy.title): '\(message)' does not end in a full stop")

            var body = String(message.dropLast())
            if let control = copy.control {
                body = body.replacingOccurrences(of: control, with: "")
            }
            for terminator in [".", "!", "?"] {
                XCTAssertFalse(body.contains(terminator),
                               "\(copy.title): '\(message)' is more than one sentence")
            }
        }
    }

    /// The rule the audit exists to enforce: name the next action in the words
    /// of the control that performs it. "No agents" says nothing a new user can
    /// act on; "Press + above and pick New Agent..." names the menu item they
    /// are looking for.
    func testMessagesNameTheirControl() {
        for copy in surfaces {
            guard let control = copy.control else { continue }
            XCTAssertTrue(copy.message.contains(control),
                          "\(copy.title): '\(copy.message)' never names its control, '\(control)'")
        }
    }

    /// Only the notification list is allowed no control, and only because
    /// nothing is pressed to fill it — an agent sends a notification or it stays
    /// empty. Every other surface has something to point at.
    func testOnlyNotificationsHaveNoControl() {
        let controlless = surfaces.filter { $0.control == nil }
        XCTAssertEqual(controlless, [.notifications])
    }

    // MARK: - Icon

    func testEverySurfaceHasAnIcon() {
        for copy in surfaces {
            XCTAssertFalse(copy.icon.isEmpty, "\(copy.title) has no glyph")
        }
    }
}
