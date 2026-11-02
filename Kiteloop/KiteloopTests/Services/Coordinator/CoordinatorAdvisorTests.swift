import XCTest
@testable import Kiteloop

final class CoordinatorAdvisorTests: XCTestCase {

    // MARK: - Learning parsing

    /// `n` words of "lorem " — 6 characters each, so length is predictable.
    private func words(_ n: Int) -> String {
        Array(repeating: "lorem", count: n).joined(separator: " ")
    }

    private func learnings(_ items: [String]) -> [String] {
        let json = try! JSONSerialization.data(withJSONObject: ["learnings": items])
        return CoordinatorAdvisor.parseLearnings(String(data: json, encoding: .utf8)!)
    }

    func testParseLearningsKeepsShortOnesVerbatim() {
        let short = words(10)                      // 59 chars
        XCTAssertEqual(learnings([short]), [short])
    }

    func testParseLearningsKeepsAnExactBudgetLearningVerbatim() {
        let padded = words(40) + "x"               // 40 * 6 - 1 + 1 = exactly 240 chars
        XCTAssertEqual(padded.count, 240)
        XCTAssertEqual(learnings([padded]), [padded])
    }

    func testParseLearningsTruncatesAtAWordBoundary() {
        let long = words(60)                       // 359 chars
        let out = learnings([long]).first!
        XCTAssertLessThanOrEqual(out.count, 240)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertTrue(out.hasSuffix("lorem…"))     // ends on a whole word, not "lor…"
        XCTAssertTrue(long.hasPrefix(out.dropLast()))   // the kept text is a real prefix
    }

    func testParseLearningsHardCapsAWordWithNoWhitespace() {
        let blob = String(repeating: "z", count: 500)
        let out = learnings([blob]).first!
        XCTAssertEqual(out.count, 240)
        XCTAssertFalse(out.hasSuffix("…"))         // nowhere to cut — plain hard cap
    }

    func testParseLearningsHardCapsWhenTheFirstWordExceedsTheBudget() {
        let blob = String(repeating: "z", count: 400) + " tail"
        let out = learnings([blob]).first!
        XCTAssertEqual(out.count, 240)
    }

    func testParseLearningsKeepsAtMostThreeTrimmedNonEmptyOnes() {
        let out = learnings(["  first  ", "", "   ", "second", "third", "fourth"])
        XCTAssertEqual(out, ["first", "second", "third"])
    }

    func testParseLearningsGarbageReturnsEmpty() {
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings("not json at all"), [])
        XCTAssertEqual(CoordinatorAdvisor.parseLearnings(#"{"other":[]}"#), [])
    }

    // MARK: - loadKiteloopFile / capToReadBudget

    /// A throwaway project root with `<name>` written under `.kiteloop/`.
    private func makeProject(name: String, contents: String) throws -> String {
        let root = try makeTemporaryDirectory(prefix: "advisor-read")
        try FileManager.default.createDirectory(at: root.appending(path: ".kiteloop"),
                                                withIntermediateDirectories: true)
        try contents.write(to: root.appending(path: ".kiteloop/\(name)"), atomically: true, encoding: .utf8)
        return root.path(percentEncoded: false)
    }

    private func autoKnowledgeFile(bulletCount: Int, head: String = "# Coordinator knowledge") -> String {
        var out = head + "\n\n" + CoordinatorKnowledge.autoHeader + "\n"
        for i in 0..<bulletCount { out += "- learning number \(i) is a durable, specific gotcha worth keeping\n" }
        return out
    }

    func testLoadKiteloopFileReturnsAnUnderBudgetFileUnchanged() throws {
        let contents = autoKnowledgeFile(bulletCount: 3)
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: contents)
        let out = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFile(projectPath: path, name: CoordinatorKnowledge.fileName))
        XCTAssertEqual(out, contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testLoadKiteloopFileOverBudgetKeepsHeadHeaderAndNewestBulletDropsOldest() throws {
        let contents = autoKnowledgeFile(bulletCount: 200)
        XCTAssertGreaterThan(contents.count, CoordinatorAdvisor.readBudget)
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: contents)
        let out = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFile(projectPath: path, name: CoordinatorKnowledge.fileName))

        XCTAssertLessThanOrEqual(out.count, CoordinatorAdvisor.readBudget)
        XCTAssertTrue(out.hasPrefix("# Coordinator knowledge"))
        XCTAssertTrue(out.contains(CoordinatorKnowledge.autoHeader))
        XCTAssertTrue(out.contains("- learning number 199 is a durable, specific gotcha worth keeping"),
                      "the newest, last-written bullet must survive")
        XCTAssertFalse(out.contains("- learning number 0 "), "the oldest bullet is the one dropped")
        for line in out.components(separatedBy: "\n") where line.hasPrefix("- ") {
            XCTAssertTrue(line.hasSuffix("gotcha worth keeping"), "no bullet is returned partially: \(line)")
        }
    }

    func testLoadKiteloopFileOverBudgetWithNoAutoHeaderFallsBackToAPrefix() throws {
        let contents = "# Persona\n\n" + String(repeating: "the coordinator speaks plainly. ", count: 400)
        XCTAssertGreaterThan(contents.count, CoordinatorAdvisor.readBudget)
        let path = try makeProject(name: "coordinator-persona.md", contents: contents)
        let out = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFile(projectPath: path, name: "coordinator-persona.md"))

        XCTAssertEqual(out.count, CoordinatorAdvisor.readBudget)
        XCTAssertTrue(contents.hasPrefix(out))
    }

    func testLoadKiteloopFileReturnsNilForAMissingFile() {
        XCTAssertNil(CoordinatorAdvisor.loadKiteloopFile(projectPath: "/tmp/does-not-exist-\(UUID())", name: CoordinatorKnowledge.fileName))
    }

    func testLoadKiteloopFileReturnsNilForAnEmptyFile() throws {
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: "\n  \n\t\n")
        XCTAssertNil(CoordinatorAdvisor.loadKiteloopFile(projectPath: path, name: CoordinatorKnowledge.fileName))
    }

    /// The raw read a caller who merges-then-writes needs: nothing dropped, unlike
    /// `loadKiteloopFile`'s prompt-sized cap over the same file.
    func testLoadKiteloopFileRawKeepsTheOldestBulletTheCappedReadDrops() throws {
        let contents = autoKnowledgeFile(bulletCount: 200)
        XCTAssertGreaterThan(contents.count, CoordinatorAdvisor.readBudget)
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: contents)

        let raw = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFileRaw(projectPath: path, name: CoordinatorKnowledge.fileName))

        XCTAssertGreaterThan(raw.count, CoordinatorAdvisor.readBudget)
        XCTAssertTrue(raw.contains("- learning number 0 is a durable, specific gotcha worth keeping"),
                      "the oldest bullet, which the capped read drops, must survive the raw one")
        XCTAssertEqual(raw, contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testLoadKiteloopFileRawReturnsNilForAMissingOrEmptyFile() throws {
        XCTAssertNil(CoordinatorAdvisor.loadKiteloopFileRaw(projectPath: "/tmp/does-not-exist-\(UUID())",
                                                            name: CoordinatorKnowledge.fileName))
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: "\n  \n\t\n")
        XCTAssertNil(CoordinatorAdvisor.loadKiteloopFileRaw(projectPath: path, name: CoordinatorKnowledge.fileName))
    }

    /// A knowledge file with one byte that is not UTF-8 between two bullets.
    private func makeProjectWithABadByte() throws -> String {
        let path = try makeProject(name: CoordinatorKnowledge.fileName, contents: "")
        var data = Data("# Coordinator knowledge\n\n- first bullet survives\n".utf8)
        data.append(0xFF)
        data.append(Data("\n- second bullet survives\n".utf8))
        try data.write(to: URL(fileURLWithPath: path).appending(path: ".kiteloop/\(CoordinatorKnowledge.fileName)"))
        return path
    }

    func testLoadKiteloopFileRawKeepsEveryBulletAroundABadByte() throws {
        let path = try makeProjectWithABadByte()
        let raw = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFileRaw(projectPath: path, name: CoordinatorKnowledge.fileName),
                                "one bad byte must not read as an absent file")
        XCTAssertTrue(raw.contains("- first bullet survives"))
        XCTAssertTrue(raw.contains("- second bullet survives"))
        XCTAssertTrue(raw.contains("\u{FFFD}"), "only the bad byte is lost, as a replacement character")
    }

    func testLoadKiteloopFileReturnsTheContentOfAFileWithABadByte() throws {
        let path = try makeProjectWithABadByte()
        let out = try XCTUnwrap(CoordinatorAdvisor.loadKiteloopFile(projectPath: path, name: CoordinatorKnowledge.fileName))
        XCTAssertTrue(out.contains("- first bullet survives"))
        XCTAssertTrue(out.contains("- second bullet survives"))
    }
}
