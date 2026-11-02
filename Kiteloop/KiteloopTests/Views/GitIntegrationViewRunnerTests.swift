import XCTest
@testable import Kiteloop

/// `GitIntegrationView.runGit` used to call `Process.run()` /
/// `readDataToEndOfFile()` / `waitUntilExit()` inline with no deadline,
/// parking a cooperative-pool thread for as long as a stuck git ran — an
/// index lock held by another process, a stalled network mount, a hook that
/// stops to ask. These cases mirror `GitBranchDetectionTests` for the
/// well-behaved paths and add the deadline arm `ChatView.runGitBranch` has no
/// equivalent for.
final class GitIntegrationViewRunnerTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        try makeTemporaryDirectory(prefix: label)
    }

    private func commit(in directory: URL) throws {
        try git(["-c", "user.email=t@example.com", "-c", "user.name=T",
                 "commit", "--allow-empty", "-m", "first"], in: directory)
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testRunGit_ValidRepoReturnsBranchName() async throws {
        let tempDir = try makeTempDir("git-runner-valid")
        try git(["init", "-b", "main"], in: tempDir)

        let branch = await GitIntegrationView.runGit(
            ["branch", "--show-current"], at: tempDir.path(percentEncoded: false)
        )
        XCTAssertEqual(branch.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    func testRunGit_NonGitDirReturnsEmptyString() async throws {
        let tempDir = try makeTempDir("git-runner-non-git")

        let branch = await GitIntegrationView.runGit(
            ["branch", "--show-current"], at: tempDir.path(percentEncoded: false)
        )
        XCTAssertEqual(branch, "")
    }

    /// A non-zero exit — a fatal git error on stderr, nothing on stdout — must
    /// still read back as "", the same panel state a bad command reached
    /// before.
    func testRunGit_NonZeroExitReturnsEmptyString() async throws {
        let tempDir = try makeTempDir("git-runner-bad-command")
        try git(["init", "-b", "main"], in: tempDir)

        let output = await GitIntegrationView.runGit(
            ["log", "-1", "--format=%s", "not-a-ref"], at: tempDir.path(percentEncoded: false)
        )
        XCTAssertEqual(output, "")
    }

    /// The defect this item exists for: a child that never exits must be
    /// abandoned at the deadline rather than parking the caller forever. Driven
    /// through the injectable `executable` with a stub that sleeps far longer
    /// than the deadline, so the call completing at all — well inside this
    /// test's own timeout — proves the deadline fired.
    func testRunGit_AbandonsAChildThatOutlivesItsDeadline() async throws {
        let tempDir = try makeTempDir("git-runner-deadline")
        let started = Date()

        let output = await GitIntegrationView.runGit(
            ["-c", "sleep 810602"],
            at: tempDir.path(percentEncoded: false),
            executable: "/bin/sh",
            timeout: 1
        )

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(output, "")
        // The stub would have slept for over a week: coming back near the
        // deadline proves the wait was bounded rather than the child exiting.
        XCTAssertLessThan(elapsed, 15)
    }

    // MARK: - Classifying HEAD

    /// The classifier is a pure function of three readings, so each outcome is
    /// asserted on the readings directly, with no git in the way.
    func testClassifyBranch_NamedBranchWins() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: 0, output: "main\n", timedOut: false),
            insideWorkTree: (status: 0, output: "true\n", timedOut: false),
            shortCommit: (status: 0, output: "abc1234\n", timedOut: false)
        )
        XCTAssertEqual(reading, .branch("main"))
    }

    func testClassifyBranch_EmptyBranchInAWorkTreeIsDetached() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: 0, output: "\n", timedOut: false),
            insideWorkTree: (status: 0, output: "true\n", timedOut: false),
            shortCommit: (status: 0, output: "abc1234\n", timedOut: false)
        )
        XCTAssertEqual(reading, .detached(commit: "abc1234"))
    }

    func testClassifyBranch_NotInsideAWorkTreeIsNotARepository() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: 128, output: "", timedOut: false),
            insideWorkTree: (status: 128, output: "", timedOut: false),
            shortCommit: (status: 128, output: "", timedOut: false)
        )
        XCTAssertEqual(reading, .notARepository)
    }

    /// A deadline kill must never be read as a missing repository: nothing was
    /// learned about the directory at all.
    func testClassifyBranch_DeadlineKillIsUnavailable() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: -1, output: "", timedOut: true),
            insideWorkTree: (status: -1, output: "", timedOut: true),
            shortCommit: (status: -1, output: "", timedOut: true)
        )
        XCTAssertEqual(reading, .unavailable(timedOut: true))
    }

    /// A branch command that failed inside a real work tree — an index lock
    /// held by another process — is git not answering, not a missing repo.
    func testClassifyBranch_NonZeroBranchInAWorkTreeIsUnavailable() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: 128, output: "", timedOut: false),
            insideWorkTree: (status: 0, output: "true\n", timedOut: false),
            shortCommit: (status: 0, output: "abc1234\n", timedOut: false)
        )
        XCTAssertEqual(reading, .unavailable(timedOut: false))
    }

    /// An unborn branch — a fresh `git init` with no commit — has no HEAD to
    /// resolve, so the detached arm reports git having no answer rather than
    /// inventing a commit.
    func testClassifyBranch_NoResolvableHeadIsUnavailable() {
        let reading = GitIntegrationView.classifyBranch(
            branch: (status: 0, output: "", timedOut: false),
            insideWorkTree: (status: 0, output: "true\n", timedOut: false),
            shortCommit: (status: 128, output: "", timedOut: false)
        )
        XCTAssertEqual(reading, .unavailable(timedOut: false))
    }

    // MARK: - Classifying a real directory

    private func classify(at path: String, executable: String = "/usr/bin/git",
                          timeout: TimeInterval = GitIntegrationView.gitTimeout) async -> GitBranchReading {
        await GitIntegrationView.classifyBranch(
            branch: GitIntegrationView.readGit(["branch", "--show-current"], at: path,
                                               executable: executable, timeout: timeout),
            insideWorkTree: GitIntegrationView.readGit(["rev-parse", "--is-inside-work-tree"], at: path,
                                                       executable: executable, timeout: timeout),
            shortCommit: GitIntegrationView.readGit(["rev-parse", "--short", "HEAD"], at: path,
                                                    executable: executable, timeout: timeout)
        )
    }

    func testClassify_RepoOnANamedBranch() async throws {
        let tempDir = try makeTempDir("git-classify-branch")
        try git(["init", "-b", "main"], in: tempDir)
        try commit(in: tempDir)

        let reading = await classify(at: tempDir.path(percentEncoded: false))
        XCTAssertEqual(reading, .branch("main"))
    }

    /// The defect this item exists for: every autopilot worktree is checked
    /// out at a commit, and the panel called all of them "Not a Git
    /// Repository".
    func testClassify_DetachedHeadNamesItsShortCommit() async throws {
        let tempDir = try makeTempDir("git-classify-detached")
        try git(["init", "-b", "main"], in: tempDir)
        try commit(in: tempDir)
        try git(["checkout", "--detach", "HEAD"], in: tempDir)
        let expected = try gitOutput(["rev-parse", "--short", "HEAD"], in: tempDir)

        let reading = await classify(at: tempDir.path(percentEncoded: false))
        XCTAssertEqual(reading, .detached(commit: expected))
        XCTAssertNotEqual(reading, .notARepository)
    }

    func testClassify_NonGitDirectoryIsStillNotARepository() async throws {
        let tempDir = try makeTempDir("git-classify-non-git")

        let reading = await classify(at: tempDir.path(percentEncoded: false))
        XCTAssertEqual(reading, .notARepository)
    }

    /// Driven through the injectable `executable` with a stub that sleeps far
    /// longer than the deadline, so nothing waits out a real timeout.
    ///
    /// The stub is a script that sleeps whatever it is handed: `classify`
    /// passes git's own arguments, and `/bin/sh branch --show-current` does
    /// not sleep — it fails to open a script named `branch` and exits 127 at
    /// once, which reads as a git that answered "no repository here".
    func testClassify_DeadlineKillSaysGitDidNotAnswer() async throws {
        let tempDir = try makeTempDir("git-classify-deadline")
        let stub = tempDir.appending(path: "sleeping-git")
        try "#!/bin/sh\nexec sleep 810602\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path(percentEncoded: false))

        let reading = await classify(at: tempDir.path(percentEncoded: false),
                                     executable: stub.path(percentEncoded: false), timeout: 1)
        XCTAssertEqual(reading, .unavailable(timedOut: true))
    }

    // MARK: - Parsing the log and the working tree

    private func commit(_ subject: String, in directory: URL) throws {
        try git(["-c", "user.email=t@example.com", "-c", "user.name=T",
                 "commit", "--allow-empty", "-m", subject], in: directory)
    }

    private func log(in directory: URL) async -> [GitCommitLine] {
        GitIntegrationView.parseLog(
            await GitIntegrationView.runGit(
                ["log", "--oneline", "--format=\(GitIntegrationView.logFormat)", "-10"],
                at: directory.path(percentEncoded: false)
            )
        )
    }

    private func status(in directory: URL) async -> [GitStatusLine] {
        GitIntegrationView.parseStatus(
            await GitIntegrationView.runGit(["status", "--porcelain", "-z"],
                                            at: directory.path(percentEncoded: false))
        )
    }

    /// The defect this item exists for: the log was read with `%h|%s|%cr` and
    /// split on `|`, so a subject holding one was cut at it and its tail
    /// spilled into the date cell.
    func testParseLog_SubjectWithAPipeIsWholeAndTheDateIsOnlyTheDate() async throws {
        let tempDir = try makeTempDir("git-log-pipe")
        try git(["init", "-b", "main"], in: tempDir)
        try commit("fix: handle a|b in parser", in: tempDir)

        let commits = await log(in: tempDir)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.message, "fix: handle a|b in parser")
        // Only the date: the tail of the subject used to land here.
        XCTAssertTrue(commits.first?.relativeDate.hasSuffix("ago") == true,
                      "unexpected date cell: \(commits.first?.relativeDate ?? "nil")")
        XCTAssertFalse(commits.first?.relativeDate.contains("parser") == true)
    }

    func testParseLog_PlainSubjectStillReadsBack() async throws {
        let tempDir = try makeTempDir("git-log-plain")
        try git(["init", "-b", "main"], in: tempDir)
        try commit("first", in: tempDir)

        let commits = await log(in: tempDir)
        XCTAssertEqual(commits.map(\.message), ["first"])
        XCTAssertFalse(commits[0].shortHash.isEmpty)
    }

    /// Plain `--porcelain` quotes a path holding a space, so the panel showed
    /// the quotes as part of the name.
    func testParseStatus_UntrackedPathWithASpaceHasNoQuotes() async throws {
        let tempDir = try makeTempDir("git-status-space")
        try git(["init", "-b", "main"], in: tempDir)
        try "x".write(to: tempDir.appendingPathComponent("plain space.txt"),
                      atomically: true, encoding: .utf8)

        let lines = await status(in: tempDir)
        XCTAssertEqual(lines.map(\.file), ["plain space.txt"])
        XCTAssertEqual(lines.first?.status, "??")
    }

    /// Plain `--porcelain` C-escapes a non-ASCII byte, so `naïve` reached the
    /// panel as `na\303\257ve`.
    func testParseStatus_UntrackedPathKeepsItsNonASCIICharacter() async throws {
        let tempDir = try makeTempDir("git-status-unicode")
        try git(["init", "-b", "main"], in: tempDir)
        try "x".write(to: tempDir.appendingPathComponent("naïve file.txt"),
                      atomically: true, encoding: .utf8)

        let lines = await status(in: tempDir)
        XCTAssertEqual(lines.map(\.file), ["naïve file.txt"])
        XCTAssertFalse(lines[0].file.contains("\\"))
    }

    /// A rename spends two NUL records — the new path, then the old one. The
    /// second must be consumed, not listed as a file of its own.
    func testParseStatus_RenameIsOneRowNamingTheNewPath() async throws {
        let tempDir = try makeTempDir("git-status-rename")
        try git(["init", "-b", "main"], in: tempDir)
        try "hello".write(to: tempDir.appendingPathComponent("old.txt"),
                          atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: tempDir)
        try commit("first", in: tempDir)
        try git(["mv", "old.txt", "new.txt"], in: tempDir)

        let lines = await status(in: tempDir)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.file, "new.txt")
        XCTAssertEqual(lines.first?.status, "R")
    }

    /// Several changed paths at once still read back one row each, in order.
    func testParseStatus_ClassifiesEachRecord() {
        let lines = GitIntegrationView.parseStatus(" M one.txt\0?? two three.txt\0A  four.txt\0")
        XCTAssertEqual(lines.map(\.file), ["one.txt", "two three.txt", "four.txt"])
        XCTAssertEqual(lines.map(\.status), ["M", "??", "A"])
    }

    /// Several concurrent calls must not starve the cooperative pool — the
    /// same shape `ChatView`'s `testRunGitBranch_DoesNotBlockCooperativePool`
    /// asserts for its own runner.
    func testRunGit_DoesNotBlockCooperativePool() async throws {
        let tempDir = try makeTempDir("git-runner-pool")
        try git(["init", "-b", "feature"], in: tempDir)
        let path = tempDir.path(percentEncoded: false)

        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await GitIntegrationView.runGit(["branch", "--show-current"], at: path)
                }
            }
            var results: [String] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "feature" })
    }
}
