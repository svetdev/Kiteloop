import XCTest
@testable import Kiteloop

/// The rules that keep an agent's always-injected memory bounded, exercised
/// without touching disk — `MemoryManagerTests` covers the file side.
final class AgentMemoryIndexTests: XCTestCase {

    private func fact(_ headline: String, date: String = "2026-08-11", topic: String? = nil, supersedes: String? = nil) -> AgentMemoryIndex.Fact {
        AgentMemoryIndex.Fact(
            date: date,
            headline: headline,
            topic: topic ?? AgentMemoryIndex.slug(for: headline),
            supersedes: supersedes
        )
    }

    // MARK: - The line

    func testRenderedLineRoundTrips() {
        let original = fact("Bedrock SSO tokens expire after eight hours", supersedes: "old-token-note")
        let parsed = AgentMemoryIndex.parseLine(original.rendered())
        XCTAssertEqual(parsed, original)
    }

    func testLineWithoutDateOrSupersedesRoundTrips() {
        let original = fact("The suite must not run while the app is up", date: "")
        let parsed = AgentMemoryIndex.parseLine(original.rendered())
        XCTAssertEqual(parsed, original)
    }

    func testParseSkipsHeaderAndPreamble() {
        let text = AgentMemoryIndex.render(facts: [fact("One thing"), fact("Another thing")])
        let facts = AgentMemoryIndex.parse(text)
        XCTAssertEqual(facts.map(\.headline), ["One thing", "Another thing"])
    }

    // MARK: - The human's own text

    /// A file with nothing but the frame and the facts has no tail — the common
    /// case, and the one every round-trip test above already exercises.
    func testATailLessFileHasNoTail() {
        let text = AgentMemoryIndex.render(facts: [fact("One thing")])
        XCTAssertEqual(AgentMemoryIndex.tail(of: text), "")
    }

    /// A `## ` section a human appended below the fact list round-trips through
    /// `tail(of:)` and back through `render(facts:tail:)`.
    func testTailReadsASectionAHumanAddedBelowTheFactList() {
        let withTail = AgentMemoryIndex.render(facts: [fact("One thing")]) + "\n## Notes\nAsk before pruning this file.\n"
        let tail = AgentMemoryIndex.tail(of: withTail)
        XCTAssertEqual(tail, "## Notes\nAsk before pruning this file.")

        let rendered = AgentMemoryIndex.render(facts: [fact("One thing")], tail: tail)
        XCTAssertEqual(AgentMemoryIndex.tail(of: rendered), tail)
        XCTAssertEqual(AgentMemoryIndex.parse(rendered).map(\.headline), ["One thing"])
    }

    /// The same, with no facts at all in the index — the tail is still read back
    /// rather than being mistaken for an empty fact list with nothing after it.
    func testTailIsReadEvenWhenTheFactListIsEmpty() {
        let text = AgentMemoryIndex.render(facts: []) + "\nProse a human wrote directly into the file.\n"
        XCTAssertEqual(AgentMemoryIndex.tail(of: text), "Prose a human wrote directly into the file.")
    }

    /// A headline containing a dash must not have part of itself eaten as a date.
    func testNonDatePrefixStaysInTheHeadline() {
        let parsed = AgentMemoryIndex.parseLine("- the runner — not the harness — owns the retry")
        XCTAssertEqual(parsed?.date, "")
        XCTAssertEqual(parsed?.headline, "the runner — not the harness — owns the retry")
    }

    func testNonBulletLinesAreNotFacts() {
        XCTAssertNil(AgentMemoryIndex.parseLine("# Memory Index"))
        XCTAssertNil(AgentMemoryIndex.parseLine(""))
        XCTAssertNil(AgentMemoryIndex.parseLine("- "))
    }

    // MARK: - Reading a proposal

    func testFactTakesTheFirstLineAsItsHeadline() {
        let f = AgentMemoryIndex.fact(
            from: "Xcode picks the wrong destination\n\nSo pass -destination explicitly.",
            date: "2026-08-11",
            taken: []
        )
        XCTAssertEqual(f?.headline, "Xcode picks the wrong destination")
    }

    func testFactStripsMarkdownMarkersFromTheHeadline() {
        let f = AgentMemoryIndex.fact(from: "## Always pass a destination", date: "", taken: [])
        XCTAssertEqual(f?.headline, "Always pass a destination")
    }

    func testFactReadsASupersedesLineAndKeepsItOutOfTheHeadline() {
        let f = AgentMemoryIndex.fact(
            from: "supersedes: old-topic\nThe token now lives in the keychain",
            date: "",
            taken: []
        )
        XCTAssertEqual(f?.supersedes, "old-topic")
        XCTAssertEqual(f?.headline, "The token now lives in the keychain")
    }

    func testFactSlugIsUniqueAgainstTopicsAlreadyTaken() {
        let first = AgentMemoryIndex.fact(from: "Use actors for shared state", date: "", taken: [])
        let second = AgentMemoryIndex.fact(from: "Use actors for shared state", date: "", taken: [first!.topic])
        XCTAssertNotEqual(first?.topic, second?.topic)
        XCTAssertEqual(second?.topic, first!.topic + "-2")
    }

    /// Shortening the headline is not a loss — the body file has the whole text —
    /// but the line has to say on its face that there is more of it.
    func testAnOverlongHeadlineIsShortenedVisibly() {
        let long = String(repeating: "a", count: AgentMemoryIndex.maxHeadlineLength + 40)
        let f = AgentMemoryIndex.fact(from: long, date: "", taken: [])
        XCTAssertEqual(f?.headline.count, AgentMemoryIndex.maxHeadlineLength + 1)
        XCTAssertTrue(f?.headline.hasSuffix("…") ?? false)
    }

    func testContentWithNoTextIsNotAFact() {
        XCTAssertNil(AgentMemoryIndex.fact(from: "   \n\n  ", date: "", taken: []))
    }

    // MARK: - The budget

    func testAppendsUnderTheCap() {
        let existing = [fact("One thing")]
        guard case .appended(let out) = AgentMemoryIndex.apply(fact: fact("A different thing"), to: existing) else {
            return XCTFail("expected an append")
        }
        XCTAssertEqual(out.count, 2)
    }

    func testAtTheCapTheWriteIsRejectedWithAWayPastIt() {
        let full = (0..<AgentMemoryIndex.maxFacts).map { fact("fact number \($0)") }
        guard case .rejected(let reason) = AgentMemoryIndex.apply(fact: fact("something else entirely"), to: full) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.contains("\(AgentMemoryIndex.maxFacts)"), reason)
        XCTAssertTrue(reason.contains("supersedes"), reason)
    }

    /// The forbidden outcome: a full index must not quietly shed a fact to make
    /// room, and must not append past its own cap either.
    func testAFullIndexIsNeitherGrownNorSilentlyTrimmed() {
        let full = (0..<AgentMemoryIndex.maxFacts).map { fact("fact number \($0)") }
        let outcome = AgentMemoryIndex.apply(fact: fact("something else entirely"), to: full)
        if case .rejected = outcome { return }
        XCTFail("a full index accepted a write: \(outcome)")
    }

    func testSupersedesReplacesInPlaceWithoutGrowing() {
        let full = (0..<AgentMemoryIndex.maxFacts).map { fact("fact number \($0)") }
        let target = full[3].topic
        let replacement = fact("the corrected version", supersedes: target)

        guard case .replaced(let out, let displaced) = AgentMemoryIndex.apply(fact: replacement, to: full) else {
            return XCTFail("expected a replacement")
        }
        XCTAssertEqual(displaced, target)
        XCTAssertEqual(out.count, full.count)
        XCTAssertEqual(out[3].headline, "the corrected version")
        XCTAssertFalse(out.contains { $0.headline == "fact number 3" })
    }

    func testSupersedesNamingNothingIsRejectedRatherThanIgnored() {
        let existing = [fact("One thing")]
        guard case .rejected(let reason) = AgentMemoryIndex.apply(fact: fact("New thing", supersedes: "no-such-topic"), to: existing) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.contains("no-such-topic"), reason)
    }

    func testAFactAlreadyCoveredIsRejectedAndTheCoveringLineIsNamed() {
        let existing = [fact("The suite must not run while the app is up")]
        guard case .rejected(let reason) = AgentMemoryIndex.apply(fact: fact("suite must not run"), to: existing) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.contains("The suite must not run while the app is up"), reason)
        XCTAssertTrue(reason.contains(existing[0].topic), reason)
    }

    /// The other direction is a correction, not a duplicate — otherwise a fact
    /// stored short would reject its own fuller rewrite for ever.
    func testAFullerRestatementTakesTheOlderFactsPlace() {
        let existing = [fact("suite must not run"), fact("unrelated note")]
        let fuller = fact("the suite must not run while the app is up, it hosts the tests")

        guard case .replaced(let out, let displaced) = AgentMemoryIndex.apply(fact: fuller, to: existing) else {
            return XCTFail("expected a replacement")
        }
        XCTAssertEqual(displaced, existing[0].topic)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].headline, fuller.headline)
        XCTAssertEqual(out[1].headline, "unrelated note")
    }

    /// Containment is whole words: a short headline whose letters happen to sit
    /// inside a longer word says nothing about the new fact, so the new fact is
    /// its own line and the short one keeps its place.
    func testAFactMatchingAnExistingHeadlineOnlyMidWordIsAppended() {
        let existing = [fact("CI"), fact("unrelated note")]
        let unrelated = fact("Deploys are specific to the staging bucket")

        guard case .appended(let out) = AgentMemoryIndex.apply(fact: unrelated, to: existing) else {
            return XCTFail("expected an append — \"specific\" is not the CI fact restated")
        }
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].headline, "CI", "the short fact keeps its line")
        XCTAssertEqual(out[2].headline, unrelated.headline)
    }

    /// The other direction: an existing line that merely spells the new fact's
    /// text inside a longer word does not cover it.
    func testAFactWhoseTextSitsMidWordInAnExistingHeadlineIsNotRejected() {
        let existing = [fact("Deploys are specific to the staging bucket")]

        guard case .appended(let out) = AgentMemoryIndex.apply(fact: fact("CI"), to: existing) else {
            return XCTFail("expected an append — the staging fact does not cover \"CI\"")
        }
        XCTAssertEqual(out.map(\.headline), [existing[0].headline, "CI"])
    }

    func testAnEmptyFactIsRejected() {
        guard case .rejected = AgentMemoryIndex.apply(fact: fact("   "), to: []) else {
            return XCTFail("expected a rejection")
        }
    }

    // MARK: - The body file

    func testBodyKeepsTheWholeApprovedTextUnderItsFrontmatter() {
        let content = "Xcode picks the wrong destination\n\nSo pass -destination explicitly every time."
        let body = AgentMemoryIndex.renderBody(fact: fact("Xcode picks the wrong destination"), content: content)
        XCTAssertTrue(body.hasPrefix("---\ntopic: "))
        XCTAssertTrue(body.contains("date: 2026-08-11"))
        XCTAssertTrue(body.contains("So pass -destination explicitly every time."))
    }

    func testIsIndexTellsAMigratedFileFromALegacyOne() {
        XCTAssertTrue(AgentMemoryIndex.isIndex(AgentMemoryIndex.render(facts: [fact("a")])))
        XCTAssertFalse(AgentMemoryIndex.isIndex("Learned: use actors\n\nLearned: avoid locks"))
    }

    /// A date the line's own parser cannot read is worse than no date — under a
    /// Buddhist calendar an unpinned formatter writes `2569-08-11`.
    func testTodayIsWrittenInTheSpellingTheLineParserReads() {
        // 2026-08-11T12:00:00Z — midday, so every time zone still reads 2026.
        let stamp = Date(timeIntervalSince1970: 1_786_449_600)
        let today = AgentMemoryIndex.today(stamp)
        XCTAssertEqual(AgentMemoryIndex.parseLine("- \(today) — a fact [a-fact]")?.date, today)
        XCTAssertTrue(today.hasPrefix("2026-"), today)
    }
}
