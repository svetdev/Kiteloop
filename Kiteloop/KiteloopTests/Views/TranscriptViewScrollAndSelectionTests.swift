import AppKit
import XCTest
@testable import Kiteloop

/// Transcript mode opens on the newest message and keeps the reader's place
/// while an agent is streaming: the end stays the end, a view scrolled up stays
/// where it is, and a selection survives the rebuild.
@MainActor
final class TranscriptViewScrollAndSelectionTests: XCTestCase {

    /// A scroll view over a text view with a real frame, laid out — the shape
    /// `makeNSView` builds, so the scroll offsets below are the ones the app sees.
    private func makeTranscript() -> (NSScrollView, NSTextView, TranscriptView.Coordinator) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("scrollableTextView() has no NSTextView")
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = TranscriptView.Coordinator()
        coordinator.textView = textView
        return (scrollView, textView, coordinator)
    }

    /// `lines` numbered lines — enough of them to overflow the 100pt frame.
    private func transcript(lines: Int) -> NSAttributedString {
        NSAttributedString(
            string: (1...lines).map { "line \($0)" }.joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
    }

    private func isScrolledToEnd(_ scrollView: NSScrollView) -> Bool {
        let visible = scrollView.documentVisibleRect
        let contentHeight = scrollView.documentView?.bounds.height ?? visible.maxY
        return visible.maxY >= contentHeight - 2
    }

    func testOpeningTheTranscriptShowsItsEndNotItsStart() {
        let (scrollView, _, coordinator) = makeTranscript()

        coordinator.apply(transcript(lines: 60), to: scrollView, openingAtTheEnd: true)

        XCTAssertGreaterThan(scrollView.documentVisibleRect.origin.y, 0, "the transcript opened at the top")
        XCTAssertTrue(isScrolledToEnd(scrollView))
    }

    func testAMessageArrivingWhileAtTheEndLeavesTheTranscriptAtTheEnd() {
        let (scrollView, _, coordinator) = makeTranscript()
        coordinator.apply(transcript(lines: 60), to: scrollView, openingAtTheEnd: true)
        let wasAt = scrollView.documentVisibleRect.origin.y

        coordinator.apply(transcript(lines: 90), to: scrollView)

        XCTAssertGreaterThan(scrollView.documentVisibleRect.origin.y, wasAt, "the content grew but the view did not follow")
        XCTAssertTrue(isScrolledToEnd(scrollView))
    }

    func testAMessageArrivingWhileScrolledUpLeavesTheViewWhereItWas() {
        let (scrollView, _, coordinator) = makeTranscript()
        coordinator.apply(transcript(lines: 60), to: scrollView, openingAtTheEnd: true)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let wasAt = scrollView.documentVisibleRect.origin.y

        coordinator.apply(transcript(lines: 90), to: scrollView)

        XCTAssertEqual(scrollView.documentVisibleRect.origin.y, wasAt, accuracy: 2)
        XCTAssertFalse(isScrolledToEnd(scrollView), "a view scrolled up was dragged to the end")
    }

    func testASelectionStillCoversTheSameCharactersAfterAMessageArrives() {
        let (scrollView, textView, coordinator) = makeTranscript()
        coordinator.apply(transcript(lines: 60), to: scrollView, openingAtTheEnd: true)
        textView.setSelectedRange(NSRange(location: 21, length: 13))
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())

        coordinator.apply(transcript(lines: 90), to: scrollView)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 21, length: 13))
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), selected)
    }

    func testASelectionTooLongForShorterTextIsClampedRatherThanDropped() {
        let (scrollView, textView, coordinator) = makeTranscript()
        coordinator.apply(transcript(lines: 60), to: scrollView, openingAtTheEnd: true)
        textView.setSelectedRange(NSRange(location: 3, length: 200))

        coordinator.apply(transcript(lines: 3), to: scrollView)

        let length = textView.textStorage?.length ?? 0
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: length - 3))
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "e 1\nline 2\nline 3")
    }
}
