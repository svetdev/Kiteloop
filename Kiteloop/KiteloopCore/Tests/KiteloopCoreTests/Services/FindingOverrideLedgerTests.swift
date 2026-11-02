import XCTest
@testable import KiteloopCore

/// The project-local ledger `RunKnowledgeDistiller` reads back: one line per
/// gate approval that overrode a review's last blocking finding.
final class FindingOverrideLedgerTests: XCTestCase {

    private var project: URL!

    override func setUp() async throws {
        project = try makeTemporaryDirectory(prefix: "finding-override-ledger")
    }

    func testUrlSitsBesideCoordinatorKnowledgeInTheProjectsKiteloopDirectory() {
        let url = FindingOverrideLedger.url(projectPath: project.path)

        XCTAssertEqual(url, project.appending(path: ".kiteloop").appending(path: "finding-overrides.jsonl"))
    }

    /// A fresh project has no `.kiteloop` yet — reading it must not throw, and
    /// must not create the directory just to say there is nothing there.
    func testReadingAMissingLedgerIsEmpty() {
        let url = FindingOverrideLedger.url(projectPath: project.path)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The whole point: what `append` writes is what `read` hands back, making
    /// the `.kiteloop` directory on the project's first override.
    func testAnAppendedOverrideRoundTrips() throws {
        let url = FindingOverrideLedger.url(projectPath: project.path)
        let record = FindingOverrideLedger.Record(itemID: "task-9", findingClass: "blocking: md missing changelog",
                                                   at: Date(timeIntervalSince1970: 1_756_684_800))

        try FindingOverrideLedger.append(record, to: url)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [record])
    }

    /// One JSON line per override, oldest first — the shape every other JSONL
    /// ledger in this app keeps.
    func testMultipleAppendsAreReadBackInOrder() throws {
        let url = FindingOverrideLedger.url(projectPath: project.path)
        let first = FindingOverrideLedger.Record(itemID: "task-1", findingClass: "blocking: swift a b c", at: at(0))
        let second = FindingOverrideLedger.Record(itemID: "task-2", findingClass: "blocking: md d e f", at: at(1))

        try FindingOverrideLedger.append(first, to: url)
        try FindingOverrideLedger.append(second, to: url)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [first, second])
    }

    /// A line the decoder refuses is dropped rather than failing the whole
    /// read — the same leniency every other ledger here reads with.
    func testAnUnreadableLineIsSkippedRatherThanFailingTheWholeRead() throws {
        let url = FindingOverrideLedger.url(projectPath: project.path)
        let record = FindingOverrideLedger.Record(itemID: "task-1", findingClass: "blocking: swift a b c", at: at(0))
        try FindingOverrideLedger.append(record, to: url)
        try Data("not json\n".utf8).appendToFile(at: url)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [record])
    }

    /// The truncation `AtomicFileWriter.append` is written to survive, read
    /// back: a kill part-way through a multi-byte character leaves a last line
    /// whose bytes are not valid UTF-8. Decoding the file as one string lost
    /// every earlier override to that one line, and the distiller saw a
    /// project that had never overridden a finding.
    func testATruncatedLastLineCostsOnlyItselfAndEarlierOverridesRemain() throws {
        let url = FindingOverrideLedger.url(projectPath: project.path)
        let first = FindingOverrideLedger.Record(itemID: "task-1", findingClass: "blocking: swift a b c", at: at(0))
        let second = FindingOverrideLedger.Record(itemID: "task-2", findingClass: "blocking: md d e f", at: at(1))
        try FindingOverrideLedger.append(first, to: url)
        try FindingOverrideLedger.append(second, to: url)
        let cut = Data(#"{"itemID":"task-3","findingClass":"blocking: swift cut — "#.utf8).dropLast(2)
        XCTAssertNil(String(data: cut, encoding: .utf8), "the em dash is genuinely cut in half")
        try cut.appendToFile(at: url)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [first, second])
    }

    /// A blank line — what `AtomicFileWriter.append`'s repair leaves when it
    /// prepends a newline nobody needed — contributes no override and is not an
    /// error.
    func testABlankLineContributesNoOverride() throws {
        let url = FindingOverrideLedger.url(projectPath: project.path)
        let record = FindingOverrideLedger.Record(itemID: "task-1", findingClass: "blocking: swift a b c", at: at(0))
        try FindingOverrideLedger.append(record, to: url)
        try Data("\n\n".utf8).appendToFile(at: url)

        XCTAssertEqual(FindingOverrideLedger.read(from: url), [record])
    }

    private func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_756_684_800 + offset)
    }
}

private extension Data {
    func appendToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(self)
    }
}
