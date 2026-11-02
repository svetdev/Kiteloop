import XCTest
@testable import Kiteloop

final class CoordinatorKnowledgeTests: XCTestCase {

    func testMergeIntoEmptyCreatesAutoSection() {
        let out = CoordinatorKnowledge.merge(existing: "", newLearnings: ["ci-local takes ~8 min"])
        XCTAssertTrue(out.contains(CoordinatorKnowledge.autoHeader))
        XCTAssertTrue(out.contains("- ci-local takes ~8 min"))
    }

    func testMergePreservesHumanHead() {
        let existing = "# Coordinator knowledge — travel\n\n## Verify\n- npm test\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["new thing"])
        XCTAssertTrue(out.contains("## Verify"))
        XCTAssertTrue(out.contains("- npm test"))
        XCTAssertTrue(out.contains("- new thing"))
    }

    func testMergePreservesSectionsBelowTheAutoSection() {
        let existing = """
        # k

        \(CoordinatorKnowledge.autoHeader)
        - alpha

        ## Gotchas
        - the sandbox has no network
        Xcode picks the wrong destination unless one is passed
        explicitly on the command line.

        """
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["brand new thing"])
        XCTAssertTrue(out.contains("- brand new thing"))
        guard let gotchas = out.range(of: "## Gotchas"),
              let bullet = out.range(of: "- the sandbox has no network"),
              let prose = out.range(of: "Xcode picks the wrong destination unless one is passed\nexplicitly on the command line.")
        else { return XCTFail("the section below the auto header was dropped: \(out)") }
        XCTAssertTrue(gotchas.lowerBound < bullet.lowerBound && bullet.lowerBound < prose.lowerBound,
                      "heading, bullets and prose must come back in their original order")
        XCTAssertTrue(out.range(of: "- brand new thing")!.lowerBound < gotchas.lowerBound,
                      "new learnings stay in the auto section, above the human tail")
    }

    func testMergeDoesNotEvictTailBulletsWhenAutoSectionIsAtItsCap() {
        var existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n"
        for i in 0..<CoordinatorKnowledge.maxAutoEntries { existing += "- entry number \(i)\n" }
        existing += "\n## Gotchas\n- the sandbox has no network\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["brand new tail entry"])

        let autoBullets = Self.bullets(in: out, between: CoordinatorKnowledge.autoHeader, and: "## Gotchas")
        XCTAssertEqual(autoBullets.count, CoordinatorKnowledge.maxAutoEntries,
                       "the tail bullet must not be counted against the cap")
        XCTAssertTrue(autoBullets.contains("- brand new tail entry"))
        XCTAssertFalse(autoBullets.contains("- entry number 0"), "the oldest auto entry is still evicted")
        XCTAssertTrue(out.contains("## Gotchas\n- the sandbox has no network"),
                      "the tail section survives an auto section at its cap: \(out)")
    }

    func testMergeRoundTripsAFileWhoseAutoSectionIsLast() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- alpha\n- beta\n"
        XCTAssertEqual(CoordinatorKnowledge.merge(existing: existing, newLearnings: []), existing,
                       "nothing new to add must leave the file byte-for-byte unchanged")
        XCTAssertEqual(CoordinatorKnowledge.merge(existing: existing, newLearnings: ["gamma"]),
                       existing + "- gamma\n",
                       "the only difference is the appended bullet")
    }

    /// The bullets of one section — `after` is the heading it starts at, `before` the
    /// heading that ends it.
    private static func bullets(in text: String, between after: String, and before: String) -> [String] {
        guard let start = text.range(of: after) else { return [] }
        let rest = text[start.upperBound...]
        let end = rest.range(of: before)?.lowerBound ?? rest.endIndex
        return rest[..<end].components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
    }

    func testMergeDedupesNearDuplicates() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- ci-local takes about 8 minutes\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["ci-local takes about 8 minutes."])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 1, "a normalized near-duplicate must not be added again")
    }

    func testMergeSkipsLearningCoveredByExistingBullet() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- ci-local takes about 8 minutes on a warm cache\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["ci-local takes about 8 minutes"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- ci-local takes about 8 minutes on a warm cache"],
                       "the longer bullet already covers the new text")
    }

    func testMergeReplacesTruncatedBulletWithFullText() {
        let full = "ci-local takes about 8 minutes on a warm cache, and roughly twice that when the toolchain has to be fetched again"
        let truncated = String(full.prefix(60))   // cut mid-word, as parseLearnings does at 240
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- before\n- \(truncated)\n- after\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: [full])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- before", "- \(full)", "- after"],
                       "the full text replaces the truncated bullet in place, without growing the section")
    }

    func testMergeReplacementIsStillDedupedAfterwards() {
        let full = "the verify command must be run from the Kiteloop directory, not the repo root"
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- \(full.prefix(30))\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: [full, full + "."])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- \(full)"], "the replaced bullet still catches the later duplicate")
    }

    func testMergeReplacementKeepsCapAndNewest() {
        var existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n"
        for i in 0..<CoordinatorKnowledge.maxAutoEntries { existing += "- entry number \(i)\n" }
        // "entry number 0 with the rest of the sentence" strictly contains "entry number 0".
        let out = CoordinatorKnowledge.merge(existing: existing,
                                             newLearnings: ["entry number 0 with the rest of the sentence"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, CoordinatorKnowledge.maxAutoEntries, "a replacement must not grow the section")
        XCTAssertEqual(bullets.first, "- entry number 0 with the rest of the sentence",
                       "replaced in place, so nothing is evicted")
        XCTAssertTrue(out.contains("- entry number \(CoordinatorKnowledge.maxAutoEntries - 1)"))
    }

    /// A learning whose text spells a short bullet's letters inside a longer word
    /// is not that bullet restated: both are kept, and the short one is not
    /// overwritten.
    func testMergeKeepsBothWhenTheMatchIsOnlyMidWord() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- CI\n"
        let out = CoordinatorKnowledge.merge(existing: existing,
                                             newLearnings: ["deploys are specific to the staging bucket"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- CI", "- deploys are specific to the staging bucket"],
                       "\"specific\" does not restate the CI bullet")
    }

    /// The other direction: a long bullet that spells the new learning inside one
    /// of its words does not cover it, so the learning is not skipped.
    func testMergeAddsALearningOnlyMatchedMidWordByAnExistingBullet() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- deploys are specific to the staging bucket\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["CI"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- deploys are specific to the staging bucket", "- CI"])
    }

    func testMergeAddsGenuinelyNew() {
        let existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n- alpha\n"
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["something completely different xyz"])
        XCTAssertTrue(out.contains("- alpha"))
        XCTAssertTrue(out.contains("- something completely different xyz"))
    }

    func testMergeCapsSectionKeepingNewest() {
        var existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n"
        for i in 0..<CoordinatorKnowledge.maxAutoEntries { existing += "- entry number \(i)\n" }
        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["brand new tail entry"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, CoordinatorKnowledge.maxAutoEntries)
        XCTAssertTrue(out.contains("- brand new tail entry"))   // newest kept
        XCTAssertFalse(out.contains("- entry number 0\n"))      // oldest evicted
    }

    /// An override lesson (`overrideLessonMarker`) is exempt from the FIFO trim:
    /// even sitting at the oldest position, it must not be the bullet dropped
    /// just because something unrelated was learned this pass. Evicting it here
    /// is indistinguishable, on the next pass, from a file that never mentioned
    /// the class — see `RunKnowledgeDistillerTests
    /// .testAnOverrideLessonSurvivesAFloodOfUnrelatedLearningsPastTheCap`.
    func testMergeExemptsAnOverrideLessonFromTheCapEvenAtTheOldestPosition() {
        let overrideBullet = "- `blocking: swift missing tests` findings were overridden 5 of 6 times since 2026-08-01"
        var existing = "# k\n\n\(CoordinatorKnowledge.autoHeader)\n\(overrideBullet)\n"
        for i in 0..<CoordinatorKnowledge.maxAutoEntries { existing += "- entry number \(i)\n" }

        let out = CoordinatorKnowledge.merge(existing: existing, newLearnings: ["brand new tail entry"])
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }

        XCTAssertEqual(bullets.count, CoordinatorKnowledge.maxAutoEntries)
        XCTAssertTrue(bullets.contains(overrideBullet),
                      "the override lesson must survive the trim even from the oldest position")
        XCTAssertTrue(bullets.contains("- brand new tail entry"), "the newest ordinary bullet is kept too")
        XCTAssertFalse(bullets.contains("- entry number 0"), "an ordinary bullet is evicted in its place")
    }

    func testNormalize() {
        XCTAssertEqual(CoordinatorKnowledge.normalize("Ci-Local: ~8 min!!"), "ci local 8 min")
    }

    // MARK: - The read side (`background`)

    /// A throwaway project root, with `coordinator-knowledge.md` written only
    /// when `contents` says so — a nil writes no file at all, which is the state
    /// of every project that has never finished a run.
    private func makeProject(contents: String?) throws -> String {
        let root = try makeTemporaryDirectory(prefix: "knowledge-bg")
        try FileManager.default.createDirectory(at: root.appending(path: ".kiteloop"),
                                                withIntermediateDirectories: true)
        if let contents {
            try contents.write(to: root.appending(path: ".kiteloop/\(CoordinatorKnowledge.fileName)"),
                               atomically: true, encoding: .utf8)
        }
        return root.path(percentEncoded: false)
    }

    /// The populated case: the run gets the file as it stands — human head and
    /// auto section alike — and a count it can log.
    func testBackgroundReadsAPopulatedFileWithItsBulletCount() throws {
        let path = try makeProject(contents: """
        # Coordinator knowledge

        \(CoordinatorKnowledge.autoHeader)
        - the app-hosted suite kills the running app
        - xcodebuild needs an explicit destination

        ## Gotchas
        - the sandbox has no network
        """)
        let background = try XCTUnwrap(CoordinatorKnowledge.background(projectPath: path))
        XCTAssertTrue(background.text.contains("- the app-hosted suite kills the running app"))
        XCTAssertTrue(background.text.contains("- the sandbox has no network"),
                      "a human section is knowledge too — the whole file goes over")
        XCTAssertEqual(background.bullets, 3, "bullets are counted across every section")
    }

    /// A file that says nothing must read as nothing: the prompts key off nil to
    /// leave the section out entirely, so whitespace here would buy a bare header.
    func testBackgroundIsNilForAnEmptyFile() throws {
        XCTAssertNil(CoordinatorKnowledge.background(projectPath: try makeProject(contents: "")))
        XCTAssertNil(CoordinatorKnowledge.background(projectPath: try makeProject(contents: "\n  \n\t\n")))
    }

    /// A project that has never distilled anything has no file, and that is not
    /// an error — it is simply a run with nothing to hand over.
    func testBackgroundIsNilWhenTheFileIsMissing() throws {
        XCTAssertNil(CoordinatorKnowledge.background(projectPath: try makeProject(contents: nil)))
    }

    /// The count is the injection's size in the run log, so it counts what a
    /// reader would call a bullet — at any indent, in either spelling — and
    /// nothing else.
    func testBulletCountIgnoresProseAndCountsIndentedBullets() {
        XCTAssertEqual(CoordinatorKnowledge.bulletCount(in: """
        # Heading

        Some prose that is not a bullet.
        - one
          - one, nested
        * two, in the other spelling
        -not a bullet, no space
        """), 3)
        XCTAssertEqual(CoordinatorKnowledge.bulletCount(in: ""), 0)
    }

    // parseLearnings lives on CoordinatorAdvisor
    func testParseLearnings() {
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings(#"{"learnings":["a","b"]}"#), ["a", "b"])
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings(#"{"learnings":[]}"#), [])
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings("not json"), [])
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings(#"{"learnings":[" x ","y","z","w"]}"#), ["x", "y", "z"])
    }
}
