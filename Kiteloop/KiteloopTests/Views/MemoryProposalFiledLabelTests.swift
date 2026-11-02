import KiteloopCore
import XCTest
@testable import Kiteloop

/// A proposal card says when the proposal was filed the way the chat says when
/// a message was sent — not as a ticking span with no "ago".
final class MemoryProposalFiledLabelTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let posix = Locale(identifier: "en_US_POSIX")

    private let proposal = MemoryProposal(agentID: "a1", proposedContent: "Builds run from Kiteloop/")

    /// A proposal filed earlier today says its time and nothing else.
    func testAProposalFromTodayIsLabelledWithItsTimeAlone() {
        let now = proposal.timestamp
        let label = MemoryProposalView.filedLabel(for: proposal, now: now, calendar: utc, locale: posix)

        XCTAssertFalse(label.contains(String(utc.component(.year, from: proposal.timestamp))), label)
        XCTAssertEqual(label, MessageBubble.sentTimeLabel(for: proposal.timestamp, now: now,
                                                          calendar: utc, locale: posix))
    }

    /// A proposal filed on an earlier day says its date as well as its time.
    func testAProposalFromAnEarlierDayIsLabelledWithItsDateAndTime() {
        let now = proposal.timestamp.addingTimeInterval(2 * 24 * 60 * 60)
        let label = MemoryProposalView.filedLabel(for: proposal, now: now, calendar: utc, locale: posix)
        let timeAlone = MemoryProposalView.filedLabel(for: proposal, now: proposal.timestamp,
                                                      calendar: utc, locale: posix)

        XCTAssertTrue(label.contains(String(utc.component(.year, from: proposal.timestamp))), label)
        XCTAssertTrue(label.contains(timeAlone), label)
        XCTAssertNotEqual(label, timeAlone)
    }
}
