import XCTest
@testable import Kiteloop

/// A knowledge install replaces the installed copy only once the new one is in
/// place, and a failed one leaves the old copy exactly as it was.
final class SetupWizardKnowledgeInstallTests: XCTestCase {
    private var root: URL!
    private var dest: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory(prefix: "knowledge-install")
        dest = root.appending(path: "home/knowledge")
        try FileManager.default.createDirectory(at: dest.appending(path: "agents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appending(path: "agents/old.md"))
    }

    private var leftovers: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path(percentEncoded: false)))?
            .filter { $0 != "knowledge" } ?? []
    }

    func testAFailedCopyLeavesTheInstalledCopyAndNoStaging() {
        let missing = root.appending(path: "no-such-source")
        XCTAssertThrowsError(try SetupWizardViewModel.installKnowledge(from: missing, to: dest))
        XCTAssertEqual(try? String(contentsOf: dest.appending(path: "agents/old.md"), encoding: .utf8), "old")
        XCTAssertEqual(leftovers, [])
    }

    func testASuccessfulInstallReplacesTheContents() throws {
        let source = root.appending(path: "chosen")
        try FileManager.default.createDirectory(at: source.appending(path: "agents"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appending(path: "agents/new.md"))

        try SetupWizardViewModel.installKnowledge(from: source, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appending(path: "agents/new.md").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "agents/old.md").path(percentEncoded: false)))
        XCTAssertEqual(leftovers, [])
    }

    func testAFirstInstallNeedsNoOldCopy() throws {
        try FileManager.default.removeItem(at: dest)
        let source = root.appending(path: "chosen")
        try FileManager.default.createDirectory(at: source.appending(path: "agents"), withIntermediateDirectories: true)
        try SetupWizardViewModel.installKnowledge(from: source, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appending(path: "agents").path(percentEncoded: false)))
    }
}
