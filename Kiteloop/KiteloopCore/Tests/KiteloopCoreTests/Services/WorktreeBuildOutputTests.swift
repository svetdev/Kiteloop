import XCTest
@testable import KiteloopCore

/// Keeping a worktree run's build output inside the worktree: which commands get
/// redirected, which are left alone, and what teardown takes with it.
final class WorktreeBuildOutputTests: XCTestCase {
    private let worktree = URL(fileURLWithPath: "/tmp/proj/.kiteloop/worktrees/some-item")

    private var derivedData: String {
        "/tmp/proj/.kiteloop/worktrees/some-item/.kiteloop/DerivedData"
    }

    // MARK: - Where the output goes

    func testDerivedDataLivesInTheWorktreesGitignoredDirectory() {
        // Inside .kiteloop/ specifically: anywhere else and the build would dirty
        // the worktree's git status, and teardown would read that as work left
        // behind and keep the checkout.
        XCTAssertEqual(
            WorktreeBuildOutput.derivedDataDirectory(for: worktree).path(percentEncoded: false),
            derivedData
        )
    }

    // MARK: - Redirecting builds

    func testAddsFlagToAPlainXcodebuild() {
        let command = WorktreeBuildOutput.redirectingBuilds(
            in: "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build",
            worktree: worktree
        )
        XCTAssertEqual(
            command,
            "xcodebuild -derivedDataPath '\(derivedData)' -project Kiteloop.xcodeproj -scheme Kiteloop build"
        )
    }

    func testAddsFlagAfterACdAndToEveryInvocationInAChain() {
        let command = WorktreeBuildOutput.redirectingBuilds(
            in: "cd Kiteloop && xcodebuild build; xcrun xcodebuild analyze",
            worktree: worktree
        )
        XCTAssertEqual(
            command,
            "cd Kiteloop && xcodebuild -derivedDataPath '\(derivedData)' build; "
                + "xcrun xcodebuild -derivedDataPath '\(derivedData)' analyze"
        )
    }

    func testAddsFlagPastAnEnvironmentAssignmentAndAnAbsolutePath() {
        let command = WorktreeBuildOutput.redirectingBuilds(
            in: "CI=1 /usr/bin/xcodebuild build",
            worktree: worktree
        )
        XCTAssertEqual(command, "CI=1 /usr/bin/xcodebuild -derivedDataPath '\(derivedData)' build")
    }

    func testLeavesACommandThatAlreadyChoseAPathAlone() {
        // Both the item that set its own path and a second application of this
        // function: rewriting either way would produce two conflicting flags.
        let original = "xcodebuild -derivedDataPath /tmp/mine build"
        XCTAssertEqual(WorktreeBuildOutput.redirectingBuilds(in: original, worktree: worktree), original)

        let once = WorktreeBuildOutput.redirectingBuilds(in: "xcodebuild build", worktree: worktree)
        XCTAssertEqual(WorktreeBuildOutput.redirectingBuilds(in: once, worktree: worktree), once)
    }

    func testLeavesNonBuildCommandsAlone() {
        for command in ["swift test", "make build", "./scripts/kiteloop-verify.py"] {
            XCTAssertEqual(WorktreeBuildOutput.redirectingBuilds(in: command, worktree: worktree), command)
        }
    }

    func testLeavesTheWordXcodebuildAloneWhenItIsNotTheCommand() {
        // An argument or a quoted string that happens to say "xcodebuild" is not a
        // build; injecting a flag into it would corrupt the command. That holds
        // even when a separator sits just before it — a `;` inside quotes or
        // behind a backslash does not start a new command.
        for command in ["grep xcodebuild build.log", "echo 'xcodebuild build'", "test -f xcodebuild",
                        "sh -c 'cd app; xcodebuild build'", "echo \\; xcodebuild"] {
            XCTAssertEqual(WorktreeBuildOutput.redirectingBuilds(in: command, worktree: worktree), command)
        }
    }

    func testRedirectsABuildBehindASubshellOrLeadingWhitespace() {
        // `(` opens a new command, and stray leading whitespace is still the
        // same command — both shapes a hand-written verify: line can take.
        XCTAssertEqual(
            WorktreeBuildOutput.redirectingBuilds(in: "(xcodebuild build) 2>&1", worktree: worktree),
            "(xcodebuild -derivedDataPath '\(derivedData)' build) 2>&1"
        )
        XCTAssertEqual(
            WorktreeBuildOutput.redirectingBuilds(in: " xcodebuild build", worktree: worktree),
            " xcodebuild -derivedDataPath '\(derivedData)' build"
        )
    }

    func testRedirectsABuildAfterAPathWithAnEscapedSpace() {
        // `My\ Projects` is one word; the escape covers one character, not the
        // rest of the line, or the build behind && would never be redirected.
        XCTAssertEqual(
            WorktreeBuildOutput.redirectingBuilds(in: "cd My\\ Projects && xcodebuild build", worktree: worktree),
            "cd My\\ Projects && xcodebuild -derivedDataPath '\(derivedData)' build"
        )
    }

    func testLiveTreeRunIsUntouched() {
        // No worktree means no disposable path to build into — the developer's own
        // DerivedData is the right place, and this must not touch it.
        let command = "xcodebuild -scheme Kiteloop build"
        XCTAssertEqual(WorktreeBuildOutput.redirectingBuilds(in: command, worktree: nil), command)
    }

    func testQuotesAPathWithSpaces() {
        let spaced = URL(fileURLWithPath: "/tmp/my projects/wt")
        let command = WorktreeBuildOutput.redirectingBuilds(in: "xcodebuild build", worktree: spaced)
        XCTAssertEqual(
            command,
            "xcodebuild -derivedDataPath '/tmp/my projects/wt/.kiteloop/DerivedData' build"
        )
    }

    // MARK: - Teardown

    func testReleaseFindsTheBuiltAppsAndRemovesTheBuildOutput() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory(prefix: "worktree-build-output")

        let derived = WorktreeBuildOutput.derivedDataDirectory(for: root)
        let products = derived.appending(path: "Build/Products/Debug")
        try fileManager.createDirectory(at: products.appending(path: "Kiteloop.app"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: products.appending(path: "Kiteloop.swiftmodule"),
                                        withIntermediateDirectories: true)

        // Only bundles get unregistered — a .swiftmodule was never in LaunchServices.
        let bundles = WorktreeBuildOutput.appBundles(inDerivedDataAt: derived)
        XCTAssertEqual(bundles.map { $0.lastPathComponent }, ["Kiteloop.app"])

        WorktreeBuildOutput.release(for: root)
        XCTAssertFalse(fileManager.fileExists(atPath: derived.path(percentEncoded: false)))
        // Only the build output goes; the checkout around it is git's to remove.
        XCTAssertTrue(fileManager.fileExists(atPath: root.path(percentEncoded: false)))
    }

    func testReleaseAlsoTakesTheUserDerivedDataTreeTheWorktreeProduced() throws {
        // A build that escaped the redirect — an agent typing its own xcodebuild
        // line — still minted a tree keyed to the worktree's path. That one is in
        // ~/Library and outlives the checkout, so teardown has to chase it.
        let fileManager = FileManager.default
        let scratch = try makeTemporaryDirectory(prefix: "worktree-build-output")
        let worktree = scratch.appending(path: "worktrees/some-item")
        let root = scratch.appending(path: "DerivedData")

        let mine = root.appending(path: "Kiteloop-aaaa")
        let theirs = root.appending(path: "Kiteloop-bbbb")
        try fileManager.createDirectory(at: mine, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: theirs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write(workspace: worktree.appending(path: "Kiteloop/Kiteloop.xcodeproj"), to: mine)
        try write(workspace: scratch.appending(path: "elsewhere/Kiteloop.xcodeproj"), to: theirs)

        XCTAssertEqual(
            WorktreeBuildOutput.userDerivedDataTrees(builtFrom: worktree, derivedDataRoot: root)
                .map { $0.lastPathComponent },
            ["Kiteloop-aaaa"]
        )

        WorktreeBuildOutput.release(for: worktree, derivedDataRoot: root)
        XCTAssertFalse(fileManager.fileExists(atPath: mine.path(percentEncoded: false)))
        // A tree built from anywhere else is another checkout's — never touched.
        XCTAssertTrue(fileManager.fileExists(atPath: theirs.path(percentEncoded: false)))
    }

    func testMatchesTheSameTreesWhicheverSlashFormTheWorktreeURLCarries() throws {
        // The shape that broke it: `standardizedFileURL` resolves against the
        // filesystem, so a worktree that exists as a directory — which one being
        // torn down always does — comes back already ending in `/`. Appending
        // another gave `…/some-item//`, matched nothing, and teardown silently
        // left every escaped tree in ~/Library. Both spellings of the same
        // directory must answer identically.
        let fileManager = FileManager.default
        let scratch = try makeTemporaryDirectory(prefix: "worktree-build-output")
        let worktree = scratch.appending(path: "worktrees/some-item")
        let root = scratch.appending(path: "DerivedData")

        let mine = root.appending(path: "Kiteloop-aaaa")
        try fileManager.createDirectory(at: mine, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write(workspace: worktree.appending(path: "Kiteloop/Kiteloop.xcodeproj"), to: mine)

        let trailingSlash = URL(filePath: worktree.path(percentEncoded: false) + "/",
                                directoryHint: .isDirectory)
        XCTAssertTrue(trailingSlash.standardizedFileURL.path(percentEncoded: false).hasSuffix("/"),
                      "precondition: this is the form that used to produce a `//` prefix")
        for spelling in [worktree, trailingSlash] {
            XCTAssertEqual(
                WorktreeBuildOutput.userDerivedDataTrees(builtFrom: spelling, derivedDataRoot: root)
                    .map { $0.lastPathComponent },
                ["Kiteloop-aaaa"]
            )
        }
    }

    func testIgnoresATreeWhosePathMerelyStartsWithTheSameCharacters() throws {
        // `some-item-2` is a sibling worktree, not a subdirectory of `some-item`.
        // Matching it would make teardown delete another run's build output, so
        // the prefix has to end at a path separator.
        let fileManager = FileManager.default
        let scratch = try makeTemporaryDirectory(prefix: "worktree-build-output")
        let worktree = scratch.appending(path: "worktrees/some-item")
        let root = scratch.appending(path: "DerivedData")

        let sibling = root.appending(path: "Kiteloop-cccc")
        try fileManager.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write(workspace: scratch.appending(path: "worktrees/some-item-2/Kiteloop.xcodeproj"),
                  to: sibling)

        XCTAssertEqual(
            WorktreeBuildOutput.userDerivedDataTrees(builtFrom: worktree, derivedDataRoot: root), []
        )
        WorktreeBuildOutput.release(for: worktree, derivedDataRoot: root)
        XCTAssertTrue(fileManager.fileExists(atPath: sibling.path(percentEncoded: false)))
    }

    func testTeardownStillMatchesAWorktreePathContainingSpaces() throws {
        // Both sides of the provenance match are filesystem paths, not URLs: a
        // `%20` sneaking into the prefix or an existence check makes teardown
        // silently skip everything under a path with a space — and "My
        // Projects" is exactly where people keep checkouts.
        let fileManager = FileManager.default
        let scratch = try makeTemporaryDirectory(prefix: "worktree build output")
        let worktree = scratch.appending(path: "work trees/some item")
        let root = scratch.appending(path: "DerivedData")

        let mine = root.appending(path: "Kiteloop-aaaa")
        let inWorktree = WorktreeBuildOutput.derivedDataDirectory(for: worktree)
        try fileManager.createDirectory(at: mine, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inWorktree, withIntermediateDirectories: true)
        try write(workspace: worktree.appending(path: "Kiteloop/Kiteloop.xcodeproj"), to: mine)

        XCTAssertEqual(
            WorktreeBuildOutput.userDerivedDataTrees(builtFrom: worktree, derivedDataRoot: root)
                .map { $0.lastPathComponent },
            ["Kiteloop-aaaa"]
        )
        WorktreeBuildOutput.release(for: worktree, derivedDataRoot: root)
        XCTAssertFalse(fileManager.fileExists(atPath: mine.path(percentEncoded: false)))
        XCTAssertFalse(fileManager.fileExists(atPath: inWorktree.path(percentEncoded: false)))
    }

    func testATreeWithoutProvenanceIsNeverTouched() throws {
        // A DerivedData root holds entries that are no build tree at all —
        // ModuleCache.noindex, an index, a half-written tree with no
        // info.plist. No provenance means no claim: never matched, never
        // deleted.
        let fileManager = FileManager.default
        let scratch = try makeTemporaryDirectory(prefix: "worktree-build-output")
        let worktree = scratch.appending(path: "worktrees/some-item")
        let root = scratch.appending(path: "DerivedData")
        let unclaimed = root.appending(path: "ModuleCache.noindex")
        try fileManager.createDirectory(at: unclaimed, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)

        XCTAssertEqual(WorktreeBuildOutput.userDerivedDataTrees(builtFrom: worktree, derivedDataRoot: root), [])
        WorktreeBuildOutput.release(for: worktree, derivedDataRoot: root)
        XCTAssertTrue(fileManager.fileExists(atPath: unclaimed.path(percentEncoded: false)))
    }

    func testUnregisteringHandsLsregisterEachBundlesRealPath() async {
        // The path must reach lsregister as the filesystem spells it — a
        // percent-encoded space would unregister nothing, silently, and a stale
        // registration is exactly what makes `open -a` resolve to a dead bundle.
        let runner = ScriptedSubprocessRunner()
        await withScriptedSubprocesses(runner) {
            WorktreeBuildOutput.unregisterFromLaunchServices(
                [URL(fileURLWithPath: "/tmp/my projects/wt/Build/Products/Debug/Kiteloop.app")]
            )
        }
        XCTAssertEqual(runner.calls.map(\.executable), [WorktreeBuildOutput.lsregisterPath])
        XCTAssertEqual(runner.calls.first?.arguments,
                       ["-u", "/tmp/my projects/wt/Build/Products/Debug/Kiteloop.app"])
    }

    private func write(workspace: URL, to tree: URL) throws {
        let plist = ["WorkspacePath": workspace.path(percentEncoded: false)] as NSDictionary
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: tree.appending(path: "info.plist"))
    }

    func testReleaseIsANoOpForAWorktreeThatNeverBuilt() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        // No directory at all — teardown must not care.
        WorktreeBuildOutput.release(for: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
