import XCTest
@testable import KiteloopCore

/// Finding a repository's backlog in an Obsidian-style vault: `Projects/<name>/Backlog.md`
/// located by the registry, by a `repo:` frontmatter field, or by the folder's name —
/// in that order, each strategy falling through to the next when it names a file that
/// is not there. Every case builds its own vault in a temporary directory.
final class BacklogParserVaultTests: XCTestCase {
    private var vault: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        vault = try makeTemporaryDirectory(prefix: "vault")
        projects = vault.appending(path: "Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    @discardableResult
    private func project(_ folder: String, backlog: String = "# Backlog\n") throws -> URL {
        let dir = projects.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Backlog.md")
        try backlog.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func registry(_ yaml: String) throws {
        let logs = vault.appending(path: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try yaml.write(to: logs.appending(path: "registry.yaml"), atomically: true, encoding: .utf8)
    }

    private func found(_ repoPath: String) -> String? {
        BacklogParser.findBacklogPath(vaultURL: vault, repoPath: repoPath)?.standardizedFileURL.path(percentEncoded: false)
    }

    private func path(_ file: URL) -> String { file.standardizedFileURL.path(percentEncoded: false) }

    // MARK: - The registry

    func testTheRegistryMapsARepoPathToItsBacklog() throws {
        let kite = try project("Kiteloop")
        try project("Other")
        try registry("""
        projects:
          kiteloop:
            name: Kiteloop
            backlog: Projects/Kiteloop/Backlog.md
            repo: /Users/me/code/kiteloop
        """)
        XCTAssertEqual(found("/Users/me/code/kiteloop/"), path(kite), "a trailing slash does not change the repo")
    }

    func testTheRegistryMatchesOnTheRepoNameAlone() throws {
        let kite = try project("Kiteloop")
        try registry("""
        projects:
          kiteloop:
            backlog: Projects/Kiteloop/Backlog.md
            repo: /somewhere/else/kiteloop
        """)
        XCTAssertEqual(found("/Users/me/work/kiteloop"), path(kite), "the same last component is the same repo")
    }

    func testAnAliasNamesTheRepoCaseInsensitively() throws {
        let kite = try project("Kiteloop")
        try registry("""
        projects:
          kiteloop:
            backlog: Projects/Kiteloop/Backlog.md
            repo: /elsewhere/unrelated
            aliases: [KL, loop]
        """)
        XCTAssertEqual(found("/Users/me/code/kl"), path(kite))
    }

    func testARegistryEntryWhoseFileIsGoneFallsThrough() throws {
        let real = try project("my-app", backlog: "---\nrepo: /Users/me/code/my-app\n---\n# Backlog\n")
        try registry("""
        projects:
          my-app:
            backlog: Projects/Moved/Backlog.md
            repo: /Users/me/code/my-app
        """)
        XCTAssertEqual(found("/Users/me/code/my-app"), path(real), "a stale registry line does not end the search")
    }

    // MARK: - Frontmatter

    func testARepoFrontmatterFieldLocatesTheBacklog() throws {
        try project("Decoy")
        let mine = try project("Anything", backlog: "---\nrepo: /Users/me/code/thing\ntitle: x\n---\n# Backlog\n")
        XCTAssertEqual(found("/Users/me/code/thing"), path(mine))
    }

    func testTheFrontmatterRepoMatchesAParentOrChildPath() throws {
        let mine = try project("Mono", backlog: "---\nrepo: /Users/me/code/mono\n---\n")
        XCTAssertEqual(found("/Users/me/code/mono/packages/leaf"), path(mine), "a repo path inside the declared one")
    }

    /// One byte that is not UTF-8 in the body must not hide the `repo:` match —
    /// `Unrelated` shares nothing with the repo's name, so no fallback finds it.
    func testARepoFrontmatterMatchSurvivesABadByteInTheBody() throws {
        let mine = try project("Unrelated")
        var data = Data("---\nrepo: /Users/me/code/thing\n---\n# Backlog\n\nNotes ".utf8)
        data.append(0xFF)
        data.append(Data(" here.\n".utf8))
        try data.write(to: mine)

        XCTAssertEqual(found("/Users/me/code/thing"), path(mine))
    }

    func testAFieldOutsideTheFrontmatterIsNotRead() throws {
        try project("Notes", backlog: "# Backlog\n\nrepo: /Users/me/code/late\n")
        XCTAssertNil(found("/Users/me/code/late"), "a `repo:` line after the frontmatter is prose, and `Notes` is no name match")
    }

    // MARK: - The folder's name

    func testTheFolderNameMatchesTheRepoNameIgnoringCaseAndDashes() throws {
        let mine = try project("MyApp")
        XCTAssertEqual(found("/Users/me/code/my-app"), path(mine))
        XCTAssertEqual(found("/Users/me/code/my_app"), path(mine))
    }

    func testAFolderWithoutABacklogFileIsSkipped() throws {
        try FileManager.default.createDirectory(at: projects.appending(path: "my-app"), withIntermediateDirectories: true)
        XCTAssertNil(found("/Users/me/code/my-app"))
    }

    // MARK: - Nothing

    func testNoMatchIsNil() throws {
        try project("Unrelated")
        XCTAssertNil(found("/Users/me/code/something-else"))
    }

    func testAVaultWithoutAProjectsFolderIsNil() throws {
        let bare = try makeTemporaryDirectory(prefix: "bare-vault")
        XCTAssertNil(BacklogParser.findBacklogPath(vaultURL: bare, repoPath: "/Users/me/code/x"))
    }

    // MARK: - The registry decides, not the folder's name

    /// The registry exists precisely for the case nothing else covers: a
    /// backlog folder whose name shares nothing with the repository's.
    func testTheRegistryAloneLocatesABacklogInAnUnrelatedlyNamedFolder() throws {
        let site = try project("Website")
        try registry("""
        projects:
          acme:
            backlog: Projects/Website/Backlog.md
            repo: /somewhere/else/acme-site
        """)
        XCTAssertEqual(found("/Users/me/work/acme-site"), path(site),
                       "a repo-name match must be enough on its own — no folder here resembles the repo")
    }

    /// One byte that is not UTF-8 in an unrelated line must not throw the whole
    /// registry away — `Website` has no `repo:` frontmatter and shares nothing
    /// with the repo's name, so only the registry can find it.
    func testTheRegistrySurvivesABadByteInAnUnrelatedLine() throws {
        let site = try project("Website")
        let logs = vault.appending(path: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var data = Data("# notes ".utf8)
        data.append(0xFF)
        data.append(Data("""

        projects:
          acme:
            backlog: Projects/Website/Backlog.md
            repo: /somewhere/else/acme-site
        """.utf8))
        try data.write(to: logs.appending(path: "registry.yaml"))

        XCTAssertEqual(found("/Users/me/work/acme-site"), path(site))
    }

    func testARegistryEntryForADifferentRepoMatchesNothing() throws {
        try project("Website")
        try registry("""
        projects:
          acme:
            backlog: Projects/Website/Backlog.md
            repo: /code/alpha
            aliases: [alpha]
        """)
        XCTAssertNil(found("/Users/me/code/beta"), "neither the repo nor an alias names this path")
    }

    func testAFrontmatterRepoForADifferentPathIsNoMatch() throws {
        try project("Docs", backlog: "---\nrepo: /code/gamma\n---\n# Backlog\n")
        XCTAssertNil(found("/code/delta"), "an unrelated `repo:` frontmatter field claims nothing")
    }

    func testAFolderNamedByAFragmentOfTheRepoNameStillMatches() throws {
        let mine = try project("App")
        XCTAssertEqual(found("/Users/me/code/my-app"), path(mine),
                       "the folder's whole name appears in the repo's — that is the fuzzy match working")
    }

    // MARK: - parseRegistry

    func testEveryRegistryEntryKeepsItsOwnFields() {
        let entries = BacklogParser.parseRegistry("""
        projects:
          alpha:
            name: Alpha
            backlog: Projects/One/Backlog.md
            repo: /code/red-canyon
            aliases: [red]
          beta:
            name: Beta
            backlog: Projects/Two/Backlog.md
            repo: /code/blue-sky
        """)

        XCTAssertEqual(entries.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(entries.map(\.backlogPath), ["Projects/One/Backlog.md", "Projects/Two/Backlog.md"])
        XCTAssertEqual(entries.map(\.repo), ["/code/red-canyon", "/code/blue-sky"])
        XCTAssertEqual(entries.map(\.aliases), [["red"], []])
    }

    func testACommentedOutEntryContributesNothing() {
        let entries = BacklogParser.parseRegistry("""
        projects:
          #old:

          kiteloop:
            backlog: Projects/Kiteloop/Backlog.md
        """)

        XCTAssertEqual(entries.map(\.name), ["kiteloop"], "a `#`-prefixed line is a comment, not an entry")
    }
}
