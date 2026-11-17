import XCTest
@testable import KiteloopCore

final class CompanionRepoTests: XCTestCase {
    private let projectRoot = URL(fileURLWithPath: "/work/app")

    func testAPathIsReadAbsoluteOrFromTheProjectsRoot() {
        XCTAssertEqual(CompanionRepo(name: "a", path: "/src/library").root(projectRoot: projectRoot).path, "/src/library")
        XCTAssertEqual(CompanionRepo(name: "a", path: "../library").root(projectRoot: projectRoot).path, "/work/library")
        XCTAssertEqual(CompanionRepo(name: "a", path: "~/library").root(projectRoot: projectRoot).path,
                       NSHomeDirectory() + "/library")
    }

    func testItsWorktreeSitsUnderTheRunsOwn() {
        let companion = CompanionRepo(name: "library", path: "../library")

        XCTAssertEqual(companion.relativePath, ".kiteloop/repos/library")
        XCTAssertEqual(companion.checkout(in: URL(fileURLWithPath: "/tree")).path, "/tree/.kiteloop/repos/library")
    }

    func testANameIsAFolderName() {
        XCTAssertTrue(CompanionRepo.isValidName("ref-app_2.0"))
        for bad in ["", ".hidden", "a/b", "two words", ".."] {
            XCTAssertFalse(CompanionRepo.isValidName(bad), bad)
        }
    }

    func testFrontmatterNamesAreACommaListWithOrWithoutBrackets() {
        XCTAssertEqual(CompanionRepo.names(fromFrontmatter: "library, client"), ["library", "client"])
        XCTAssertEqual(CompanionRepo.names(fromFrontmatter: "[library, \"client\"]"), ["library", "client"])
        XCTAssertEqual(CompanionRepo.names(fromFrontmatter: ""), [])
    }

    func testResolveKeepsTheItemsOrderAndReportsTheUnknown() {
        let companions = [CompanionRepo(name: "library", path: "a"), CompanionRepo(name: "client", path: "b")]

        let resolved = CompanionRepo.resolve(["client", "ghost", "library", "client"], among: companions)

        XCTAssertEqual(resolved.found.map(\.name), ["client", "library"])
        XCTAssertEqual(resolved.unknown, ["ghost"])
    }

    func testTheDetailFileCarriesReposInItsFrontmatter() throws {
        let detail = try XCTUnwrap(BacklogParser.parseDetail("""
            ---
            id: sync-api
            title: Sync API
            repos: library, client
            ---
            ## What
            Change both.
            """, fallbackID: "sync-api"))

        XCTAssertEqual(detail.repos, ["library", "client"])
    }

    func testAnItemWithoutTheFieldNamesNone() throws {
        let detail = try XCTUnwrap(BacklogParser.parseDetail("""
            ---
            id: plain
            title: Plain
            ---
            ## What
            One repository.
            """, fallbackID: "plain"))

        XCTAssertNil(detail.repos)
    }

    func testTheProjectConfigReadsItsCompanionsAndToleratesTheirAbsence() throws {
        let with = try JSONDecoder().decode(ProjectConfig.self, from: Data("""
            {"permissionMode": "auto", "deniedTools": [],
             "companions": [{"name": "library", "path": "../library", "baseBranch": "main"}]}
            """.utf8))
        let without = try JSONDecoder().decode(ProjectConfig.self, from: Data("""
            {"permissionMode": "auto", "deniedTools": []}
            """.utf8))

        XCTAssertEqual(with.companions, [CompanionRepo(name: "library", path: "../library", baseBranch: "main")])
        XCTAssertNil(without.companions)
        let saved = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(saved.companions, with.companions)
    }

    // MARK: - The settings page's rows

    func testRowsAreTrimmedAndABlankBaseIsNil() {
        let edit = CompanionRepo.edit(fromRows: [
            .init(name: "  library ", path: " ../library\t", baseBranch: "  "),
            .init(name: "client", path: "../client", baseBranch: " develop "),
        ])

        XCTAssertEqual(edit, .store([
            CompanionRepo(name: "library", path: "../library", baseBranch: nil),
            CompanionRepo(name: "client", path: "../client", baseBranch: "develop"),
        ]))
    }

    func testAFullyBlankRowIsSkipped() {
        let edit = CompanionRepo.edit(fromRows: [
            .init(name: " ", path: "", baseBranch: "main"),
            .init(name: "library", path: "../library"),
        ])

        XCTAssertEqual(edit, .store([CompanionRepo(name: "library", path: "../library")]))
    }

    func testNoRowsLeftStoresNil() {
        XCTAssertEqual(CompanionRepo.edit(fromRows: []), .store(nil))
        XCTAssertEqual(CompanionRepo.edit(fromRows: [.init(name: "", path: "  ")]), .store(nil))
    }

    func testAListWithProblemsIsRefusedWithThem() {
        let rows: [CompanionRepo.Row] = [
            .init(name: "two words", path: "../a"),
            .init(name: "library", path: "../library"),
            .init(name: "library", path: "../other"),
            .init(name: "client", path: " "),
        ]

        XCTAssertEqual(CompanionRepo.edit(fromRows: rows), .refused([
            "companion name \"two words\" takes letters, digits, - _ and . only",
            "companion \"library\" is listed twice",
            "companion \"client\" has no path",
        ]))
    }
}
