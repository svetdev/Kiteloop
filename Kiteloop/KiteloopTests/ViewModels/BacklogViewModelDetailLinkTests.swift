import XCTest
import KiteloopCore
@testable import Kiteloop

/// Detail links (`→ [detail](path)`) are relative to the *backlog file*, not to
/// the repo and not to the process working directory. That distinction only
/// shows up when the two differ — a vault-hosted backlog lives outside the repo,
/// so resolving against the repo would silently read (or write) the wrong file.
/// These tests pin the resolution used by `loadDetail`, `createDetail` and the
/// rejection note that `reject` appends.
@MainActor
final class BacklogViewModelDetailLinkTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-detail-link")
    }

    // MARK: - loadDetail resolution

    func testLoadDetailResolvesPathRelativeToTheBacklogDirectory() throws {
        let repo = try makeRepo(detailLink: "backlog/task-1.md")
        try writeDetail(at: repo.appending(path: "backlog/task-1.md"), title: "From the backlog dir")

        let vm = try loadLocal(repo: repo)

        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "From the backlog dir")
    }

    /// The crux: repo root and backlog directory are different directories, and
    /// both hold a file at the linked path. The one next to the backlog wins.
    func testLoadDetailResolvesAgainstTheBacklogFileNotTheRepo() throws {
        let (repo, vaultBacklogDir) = try makeVaultProject(detailLink: "backlog/task-1.md")
        try writeDetail(at: vaultBacklogDir.appending(path: "backlog/task-1.md"), title: "Next to the backlog")
        try writeDetail(at: repo.appending(path: "backlog/task-1.md"), title: "Next to the repo")

        let vm = try loadVault(repo: repo)
        XCTAssertEqual(vm.backlogURL.map { resolved($0.deletingLastPathComponent()) },
                       resolved(vaultBacklogDir),
                       "Precondition: the backlog is the vault copy, not the repo copy")

        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "Next to the backlog")
    }

    func testLoadDetailResolvesNestedSubdirectoryPaths() throws {
        let repo = try makeRepo(detailLink: "docs/items/task-1.md")
        try writeDetail(at: repo.appending(path: "docs/items/task-1.md"), title: "Nested")

        let vm = try loadLocal(repo: repo)

        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "Nested")
    }

    func testLoadDetailResolvesDotSlashPrefixedPaths() throws {
        let repo = try makeRepo(detailLink: "./backlog/task-1.md")
        try writeDetail(at: repo.appending(path: "backlog/task-1.md"), title: "Dot slash")

        let vm = try loadLocal(repo: repo)

        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "Dot slash")
    }

    /// A vault backlog commonly links to shared detail files that sit above it.
    func testLoadDetailResolvesParentRelativePaths() throws {
        let repo = try makeRepo(detailLink: "../shared/task-1.md")
        try writeDetail(at: tempDir.appending(path: "shared/task-1.md"), title: "One level up")

        let vm = try loadLocal(repo: repo)

        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "One level up")
    }

    func testLoadDetailResolvesPathsContainingSpaces() throws {
        let repo = try makeRepo(detailLink: "my backlog/task 1.md")
        try writeDetail(at: repo.appending(path: "my backlog/task 1.md"), title: "Spaced out")

        let vm = try loadLocal(repo: repo)

        XCTAssertEqual(try item(vm, "task-1").detailPath, "my backlog/task 1.md")
        XCTAssertEqual(vm.loadDetail(for: try item(vm, "task-1"))?.title, "Spaced out")
    }

    func testLoadDetailReturnsNilWhenTheItemHasNoDetailLink() throws {
        let repo = try makeRepo(detailLink: nil)
        // A file at the conventional location must not be picked up implicitly.
        try writeDetail(at: repo.appending(path: "backlog/task-1.md"), title: "Unlinked")

        let vm = try loadLocal(repo: repo)

        XCTAssertNil(vm.loadDetail(for: try item(vm, "task-1")))
    }

    func testLoadDetailReturnsNilWhenTheResolvedFileIsMissing() throws {
        let repo = try makeRepo(detailLink: "backlog/task-1.md")

        let vm = try loadLocal(repo: repo)

        XCTAssertNil(vm.loadDetail(for: try item(vm, "task-1")))
    }

    func testLoadDetailReturnsNilWithoutALoadedBacklog() throws {
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
        let orphan = BacklogItem(id: "task-1", title: "First task", status: .ready,
                                 type: .local, detailPath: "backlog/task-1.md")

        XCTAssertNil(vm.backlogURL, "Precondition: nothing to resolve against")
        XCTAssertNil(vm.loadDetail(for: orphan))
    }

    // MARK: - createDetail

    func testCreateDetailWritesNextToTheBacklogFileAndLinksItRelatively() throws {
        let (repo, vaultBacklogDir) = try makeVaultProject(detailLink: nil)
        let vm = try loadVault(repo: repo)

        vm.createDetail(for: try item(vm, "task-1"))

        XCTAssertEqual(try item(vm, "task-1").detailPath, "backlog/task-1.md",
                       "The link is stored relative to the backlog file")
        XCTAssertTrue(exists(vaultBacklogDir.appending(path: "backlog/task-1.md")),
                      "Scaffold lands beside the backlog file")
        XCTAssertFalse(exists(repo.appending(path: "backlog/task-1.md")),
                       "Nothing is written into the repo")
    }

    func testCreateDetailProducesAFileThatLoadDetailResolves() throws {
        let (repo, _) = try makeVaultProject(detailLink: nil)
        let vm = try loadVault(repo: repo)

        vm.createDetail(for: try item(vm, "task-1"))

        let detail = try XCTUnwrap(vm.loadDetail(for: try item(vm, "task-1")))
        XCTAssertEqual(detail.id, "task-1")
        XCTAssertEqual(detail.title, "First task")
    }

    /// The scaffold copies the item line's verify into a quoted YAML scalar, so
    /// it needs the same escaping the coordinator's writer uses: written raw, a
    /// backslashed command came back off disk one backslash short — `-exec … {}
    /// ;`, which `find` refuses — and the run executed something nobody wrote.
    func testCreateDetailScaffoldsAVerifyThatReadsBackByteForByte() throws {
        let command = "find . -name '*.swift' -exec grep -l x {} \\;"
        let (repo, _) = try makeVaultProject(detailLink: nil, verify: command)
        let vm = try loadVault(repo: repo)
        XCTAssertEqual(try item(vm, "task-1").verify, command, "Precondition: the line carries it")

        vm.createDetail(for: try item(vm, "task-1"))

        let detail = try XCTUnwrap(vm.loadDetail(for: try item(vm, "task-1")))
        XCTAssertEqual(detail.verifyCommands.first?.cmd, command)
    }

    // MARK: - overwriteDetail

    /// The mirror image of `createDetail`: the file is already linked, and the
    /// write lands over it rather than being skipped for already existing.
    func testOverwriteDetailReplacesAnExistingFileBesideTheBacklog() throws {
        let (repo, vaultBacklogDir) = try makeVaultProject(detailLink: "backlog/task-1.md")
        try writeDetail(at: vaultBacklogDir.appending(path: "backlog/task-1.md"), title: "Before")
        let vm = try loadVault(repo: repo)

        let outcome = vm.overwriteDetail(for: try item(vm, "task-1"), content: "## What\n\nAfter\n")

        XCTAssertEqual(outcome, .filed)
        let onDisk = try String(contentsOf: vaultBacklogDir.appending(path: "backlog/task-1.md"),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "## What\n\nAfter\n")
    }

    /// An item with nothing linked has nowhere for this write to land — it is
    /// `createDetail`'s job to make the link, not this one's.
    func testOverwriteDetailFailsWithNoDetailLinked() throws {
        let (repo, _) = try makeVaultProject(detailLink: nil)
        let vm = try loadVault(repo: repo)

        let outcome = vm.overwriteDetail(for: try item(vm, "task-1"), content: "anything")

        guard case .detailWriteFailed = outcome else {
            return XCTFail("expected a failed write, got \(outcome)")
        }
    }

    // MARK: - rejection notes

    func testRejectAppendsTheNoteToTheDetailFileBesideTheBacklog() throws {
        let (repo, vaultBacklogDir) = try makeVaultProject(detailLink: "backlog/task-1.md")
        let linked = vaultBacklogDir.appending(path: "backlog/task-1.md")
        let decoy = repo.appending(path: "backlog/task-1.md")
        try writeDetail(at: linked, title: "Next to the backlog")
        try writeDetail(at: decoy, title: "Next to the repo")
        let decoyBefore = try String(contentsOf: decoy, encoding: .utf8)

        let vm = try loadVault(repo: repo)
        vm.reject(itemID: "task-1", reason: "verify failed")

        XCTAssertTrue(try String(contentsOf: linked, encoding: .utf8).contains("rejected: verify failed"),
                      "Feedback lands in the linked detail file")
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), decoyBefore,
                       "The same-named file under the repo is untouched")
    }

    // MARK: - Fixtures

    private func backlog(detailLink: String?, verify: String? = nil) -> String {
        let suffix = detailLink.map { " → [detail](\($0))" } ?? ""
        let verifyField = verify.map { " | verify:\($0)" } ?? ""
        return """
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] task-1 | First task | ready\(verifyField)\(suffix)
        """
    }

    /// A repo with its own `BACKLOG.md` in the root — backlog dir == repo dir.
    private func makeRepo(detailLink: String?) throws -> URL {
        let repo = tempDir.appending(path: "demo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try backlog(detailLink: detailLink).write(to: repo.appending(path: "BACKLOG.md"),
                                                  atomically: true, encoding: .utf8)
        return repo
    }

    /// A repo with *no* local backlog plus a vault whose `Projects/demo/Backlog.md`
    /// points back at it — backlog dir and repo dir are different directories.
    private func makeVaultProject(detailLink: String?,
                                  verify: String? = nil) throws -> (repo: URL, backlogDir: URL) {
        let repo = tempDir.appending(path: "repo/demo")
        let backlogDir = tempDir.appending(path: "vault/Projects/demo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backlogDir, withIntermediateDirectories: true)

        let content = backlog(detailLink: detailLink, verify: verify).replacingOccurrences(
            of: "project: demo",
            with: "project: demo\nrepo: \(repo.path(percentEncoded: false))"
        )
        try content.write(to: backlogDir.appending(path: "Backlog.md"), atomically: true, encoding: .utf8)
        return (repo, backlogDir)
    }

    private func writeDetail(at url: URL, title: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try """
        ---
        id: task-1
        title: \(title)
        ---

        ## What

        Something.

        ## Notes
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
    }

    private func loadLocal(repo: URL) throws -> BacklogViewModel {
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
        vm.loadForProject(repoPath: repo.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func loadVault(repo: URL) throws -> BacklogViewModel {
        let store = makeConfigStore()
        store.setVaultPath(tempDir.appending(path: "vault").path(percentEncoded: false))
        let vm = BacklogViewModel(globalConfigStore: store)
        vm.loadForProject(repoPath: repo.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "Backlog.md")
        return vm
    }

    private func item(_ vm: BacklogViewModel, _ id: String) throws -> BacklogItem {
        try XCTUnwrap(vm.backlogFile?.sections.flatMap(\.items).first { $0.id == id })
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Temp dirs live behind the `/private` symlink, so directory URLs only
    /// compare equal once resolved (and stripped of a trailing slash).
    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }
}
