import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// What the phone may read of a project: the agent's uncommitted changes, and
/// a file inside the project that git does not ignore. Against a real
/// temporary repository, since the refusals are about real paths.
final class WorkspaceReaderTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        repo = try makeTemporaryDirectory(prefix: "workspace-reader")
        git(["init", "-q"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        try write("src/refund.ts", "export const a = 1\n")
        try write(".gitignore", ".env\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "one"])
    }

    // MARK: - Changes

    func testAChangedAndAnUntrackedFileBothAppear() throws {
        try write("src/refund.ts", "export const a = 2\n")
        try write("test/refund.test.ts", "it('works')\n")

        guard case .changes(let files, let patch, let truncated) = WorkspaceReader.changes(root: repo.path(percentEncoded: false)) else {
            return XCTFail("a repository has changes to read")
        }

        XCTAssertEqual(files, [WorkspaceReader.ChangedFile(status: " M", path: "src/refund.ts"),
                               WorkspaceReader.ChangedFile(status: "??", path: "test/refund.test.ts")])
        XCTAssertTrue(patch.contains("+export const a = 2"))
        XCTAssertFalse(truncated)
    }

    func testACleanTreeIsAnEmptyListNotAnError() {
        XCTAssertEqual(WorkspaceReader.changes(root: repo.path(percentEncoded: false)),
                       .changes(files: [], patch: "", truncated: false))
    }

    func testAPatchOverTheCapIsCutAndSaysSo() throws {
        try write("src/refund.ts", String(repeating: "x", count: WorkspaceReader.patchCap + 10) + "\n")

        guard case .changes(_, let patch, let truncated) = WorkspaceReader.changes(root: repo.path(percentEncoded: false)) else {
            return XCTFail("changes")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(patch.count, WorkspaceReader.patchCap)
    }

    func testAFolderThatIsNotARepositoryIsSaidSo() throws {
        let plain = try makeTemporaryDirectory(prefix: "workspace-plain")
        XCTAssertEqual(WorkspaceReader.changes(root: plain.path(percentEncoded: false)), .notARepository)
    }

    func testARenameKeepsItsNewPath() {
        XCTAssertEqual(WorkspaceReader.parseStatus("R  old.ts -> new.ts\n"),
                       [WorkspaceReader.ChangedFile(status: "R ", path: "new.ts")])
    }

    // MARK: - Files

    func testAFileInsideTheProjectIsReturned() {
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "src/refund.ts"), .text("export const a = 1\n"))
    }

    func testADirectoryAnswersItsListing() {
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "src"),
                       .directory([WorkspaceReader.Entry(name: "refund.ts", isDirectory: false)]))
    }

    func testAnAbsolutePathInsideTheProjectIsReadAndOneOutsideRefused() {
        let inside = repo.appending(path: "src/refund.ts").path(percentEncoded: false)

        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: inside), .text("export const a = 1\n"))
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "/etc/hosts"), .outside)
    }

    func testDotDotLeavingTheProjectIsRefused() {
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "../../etc/hosts"), .outside)
    }

    func testASymlinkPointingOutsideIsRefused() throws {
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "escape"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "escape/hosts"), .outside)
    }

    func testTheGitDirectoryIsRefused() {
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: ".git/config"), .outside)
    }

    func testAGitIgnoredFileIsRefused() throws {
        try write(".env", "SECRET=1\n")
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: ".env"), .ignored)
    }

    func testABinaryFileIsRefused() throws {
        try Data([0x00, 0x01, 0x02]).write(to: repo.appending(path: "blob.bin"))
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "blob.bin"), .binary)
    }

    func testAMissingFileIsSaidSo() {
        XCTAssertEqual(WorkspaceReader.read(root: repo, relative: "nope.ts"), .missing)
    }

    // MARK: - Helpers

    private func write(_ relative: String, _ text: String) throws {
        let url = repo.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
