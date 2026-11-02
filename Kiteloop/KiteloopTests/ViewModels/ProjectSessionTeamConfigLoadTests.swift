// Kiteloop/KiteloopTests/ViewModels/ProjectSessionTeamConfigLoadTests.swift
import XCTest
@testable import Kiteloop

/// `ProjectSession.loadTeamConfig` used to answer `nil` for two very different
/// files: one that isn't there, and one that is there and won't decode. Both
/// took the predefined agents, both logged "no team config", so a team.json
/// truncated by an unclean shutdown was indistinguishable from a project that
/// had never had a team — the user's agents were simply gone, quietly.
///
/// These pin the four answers apart, including the one that carries the reason
/// the file couldn't be read.
final class ProjectSessionTeamConfigLoadTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "team-config-load-test")
    }

    /// Writes `contents` to a team.json inside the temp dir and returns its URL.
    private func writeTeamFile(_ contents: String) throws -> URL {
        let url = tempDir.appending(path: "team.json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Absent

    @MainActor
    func testMissingFileIsAbsent() {
        let url = tempDir.appending(path: "team.json")
        switch ProjectSession.loadTeamConfig(from: url) {
        case .absent:
            break
        case let other:
            XCTFail("expected .absent for a file that isn't there, got \(other)")
        }
    }

    /// A file that decodes to an empty template array configures no team, which
    /// is a statement rather than a fault: it must not raise an error.
    @MainActor
    func testEmptyTemplateArrayIsAbsent() throws {
        let url = try writeTeamFile("[]")
        switch ProjectSession.loadTeamConfig(from: url) {
        case .absent:
            break
        case let other:
            XCTFail("expected .absent for an empty team array, got \(other)")
        }
    }

    // MARK: - Present but undecodable

    @MainActor
    func testTruncatedFileIsUnreadable() throws {
        // What an unclean shutdown leaves behind: a prefix of the real file.
        let url = try writeTeamFile(#"[{"name": "Reviewer", "mod"#)
        switch ProjectSession.loadTeamConfig(from: url) {
        case .unreadable(let reason):
            XCTAssertFalse(reason.isEmpty, "the unreadable case must carry a reason to report")
        case let other:
            XCTFail("expected .unreadable for a truncated file, got \(other)")
        }
    }

    /// Valid JSON of neither shape — an object that isn't a `PackageTeamConfig`
    /// and isn't an array of templates.
    @MainActor
    func testWellFormedJSONOfNeitherShapeIsUnreadable() throws {
        let url = try writeTeamFile(#"{"team": "Reviewer"}"#)
        switch ProjectSession.loadTeamConfig(from: url) {
        case .unreadable:
            break
        case let other:
            XCTFail("expected .unreadable for JSON of neither team shape, got \(other)")
        }
    }

    /// A zero-length file — the other thing the page cache leaves behind — is
    /// present, so it is a broken file rather than a missing one.
    @MainActor
    func testEmptyFileIsUnreadable() throws {
        let url = try writeTeamFile("")
        switch ProjectSession.loadTeamConfig(from: url) {
        case .unreadable:
            break
        case let other:
            XCTFail("expected .unreadable for a zero-length file, got \(other)")
        }
    }

    // MARK: - The two decodable shapes

    @MainActor
    func testPackageRefObjectIsPackages() throws {
        let url = try writeTeamFile(#"{"agents": [{"id": "reviewer", "ref": "shared:reviewer"}]}"#)
        switch ProjectSession.loadTeamConfig(from: url) {
        case .packages(let config):
            XCTAssertEqual(config.agents.map(\.id), ["reviewer"])
            XCTAssertEqual(config.agents.first?.ref, "shared:reviewer")
        case let other:
            XCTFail("expected .packages for a package-ref object, got \(other)")
        }
    }

    @MainActor
    func testTemplateArrayIsTemplates() throws {
        let url = try writeTeamFile(#"[{"name": "Reviewer"}, {"name": "Builder"}]"#)
        switch ProjectSession.loadTeamConfig(from: url) {
        case .templates(let templates):
            XCTAssertEqual(templates.map(\.name), ["Reviewer", "Builder"])
        case let other:
            XCTFail("expected .templates for a self-contained team array, got \(other)")
        }
    }

    // MARK: - Welcome-screen permission mode

    /// A team template that names no mode decodes as auto and takes the mode
    /// picked on the welcome screen, as does one naming "default"; a template
    /// that names any other mode keeps its own.
    @MainActor
    func testATemplateNamingNoModeTakesTheWelcomePick() throws {
        func template(_ json: String) throws -> AgentTemplate {
            try JSONDecoder().decode(AgentTemplate.self, from: Data(json.utf8))
        }
        XCTAssertTrue(ProjectSession.takesWelcomeMode(try template(#"{ "name": "Unset" }"#)))
        XCTAssertTrue(ProjectSession.takesWelcomeMode(try template(#"{ "name": "D", "permissionMode": "default" }"#)))
        XCTAssertFalse(ProjectSession.takesWelcomeMode(try template(#"{ "name": "P", "permissionMode": "plan" }"#)))
    }
}
