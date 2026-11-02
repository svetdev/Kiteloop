import XCTest
@testable import KiteloopCore

/// `PackageAgentRef.ref` is the hand-editable string in a project's `.kiteloop/team.json`
/// (`"shared:coder"`, `"local:my-agent"`, `"user:scratch"`). `PackageResolver.resolve(ref:localAgentsURL:)`
/// dispatches purely on `isLocal` / `isShared` / `isUser` and then looks the package up by
/// `refName`, so these computed properties decide *which source tree* an agent is loaded
/// from. These tests pin the split rules — including the malformed and prefix-less inputs a
/// human can easily type into `team.json`.
final class PackageAgentRefTests: XCTestCase {

    // MARK: - Helpers

    private func makeRef(_ ref: String, id: String = "agent") -> PackageAgentRef {
        PackageAgentRef(id: id, ref: ref, version: nil, overrides: nil)
    }

    // MARK: - Well-formed refs

    func testSharedRefSplitsIntoPrefixAndName() {
        let ref = makeRef("shared:coder")

        XCTAssertEqual(ref.refPrefix, "shared")
        XCTAssertEqual(ref.refName, "coder")
    }

    func testLocalRefSplitsIntoPrefixAndName() {
        let ref = makeRef("local:my-agent")

        XCTAssertEqual(ref.refPrefix, "local")
        XCTAssertEqual(ref.refName, "my-agent")
    }

    func testUserRefSplitsIntoPrefixAndName() {
        let ref = makeRef("user:scratch")

        XCTAssertEqual(ref.refPrefix, "user")
        XCTAssertEqual(ref.refName, "scratch")
    }

    /// The wizard writes `"shared:<agent.id>"`; the resolver must read back the same name.
    func testSetupWizardRefShapeRoundTripsThroughRefName() {
        let agentID = "product-manager"
        let ref = makeRef("shared:\(agentID)", id: agentID)

        XCTAssertTrue(ref.isShared)
        XCTAssertEqual(ref.refName, agentID)
    }

    // MARK: - Source predicates

    func testSourcePredicatesAreMutuallyExclusive() {
        let cases: [(ref: String, shared: Bool, local: Bool, user: Bool)] = [
            ("shared:coder", true, false, false),
            ("local:coder", false, true, false),
            ("user:coder", false, false, true),
        ]

        for testCase in cases {
            let ref = makeRef(testCase.ref)
            XCTAssertEqual(ref.isShared, testCase.shared, "isShared for \(testCase.ref)")
            XCTAssertEqual(ref.isLocal, testCase.local, "isLocal for \(testCase.ref)")
            XCTAssertEqual(ref.isUser, testCase.user, "isUser for \(testCase.ref)")
        }
    }

    /// An unrecognised prefix is not an error — `resolve` falls through to the scan paths
    /// with no preferred source, so all three predicates must read false.
    func testUnknownPrefixMatchesNoSource() {
        let ref = makeRef("git:some-agent")

        XCTAssertEqual(ref.refPrefix, "git")
        XCTAssertEqual(ref.refName, "some-agent")
        XCTAssertFalse(ref.isShared)
        XCTAssertFalse(ref.isLocal)
        XCTAssertFalse(ref.isUser)
    }

    /// Prefix matching is exact and case-sensitive — `"Shared:"` must not silently resolve
    /// as a shared package.
    func testPrefixMatchingIsCaseSensitive() {
        for ref in ["Shared:coder", "LOCAL:coder", "User:coder"].map({ makeRef($0) }) {
            XCTAssertFalse(ref.isShared, "isShared for \(ref.ref)")
            XCTAssertFalse(ref.isLocal, "isLocal for \(ref.ref)")
            XCTAssertFalse(ref.isUser, "isUser for \(ref.ref)")
        }
    }

    /// Whitespace is not trimmed; a padded prefix is treated as unknown rather than matched.
    func testPaddedPrefixIsNotMatched() {
        let ref = makeRef(" shared:coder")

        XCTAssertEqual(ref.refPrefix, " shared")
        XCTAssertFalse(ref.isShared)
    }

    // MARK: - Prefix-less refs

    func testRefWithoutColonHasEmptyPrefixAndIsWholeName() {
        let ref = makeRef("coder")

        XCTAssertEqual(ref.refPrefix, "")
        XCTAssertEqual(ref.refName, "coder")
        XCTAssertFalse(ref.isShared)
        XCTAssertFalse(ref.isLocal)
        XCTAssertFalse(ref.isUser)
    }

    func testEmptyRefYieldsEmptyPrefixAndEmptyName() {
        let ref = makeRef("")

        XCTAssertEqual(ref.refPrefix, "")
        XCTAssertEqual(ref.refName, "")
        XCTAssertFalse(ref.isShared)
        XCTAssertFalse(ref.isLocal)
        XCTAssertFalse(ref.isUser)
    }

    // MARK: - Malformed refs

    /// A leading colon means "empty prefix" — the name keeps everything after it, so the
    /// ref still resolves through the scan paths instead of dropping the agent.
    func testLeadingColonYieldsEmptyPrefix() {
        let ref = makeRef(":coder")

        XCTAssertEqual(ref.refPrefix, "")
        XCTAssertEqual(ref.refName, "coder")
        XCTAssertFalse(ref.isShared)
    }

    /// A trailing colon keeps the source predicate true but leaves nothing to look up.
    func testTrailingColonYieldsEmptyName() {
        let ref = makeRef("shared:")

        XCTAssertEqual(ref.refPrefix, "shared")
        XCTAssertEqual(ref.refName, "")
        XCTAssertTrue(ref.isShared)
    }

    func testOnlyColonYieldsEmptyPrefixAndEmptyName() {
        let ref = makeRef(":")

        XCTAssertEqual(ref.refPrefix, "")
        XCTAssertEqual(ref.refName, "")
        XCTAssertFalse(ref.isShared)
        XCTAssertFalse(ref.isLocal)
        XCTAssertFalse(ref.isUser)
    }

    /// The split happens at the *first* colon only — later colons belong to the name, so a
    /// namespaced package name survives intact.
    func testSplitsOnFirstColonOnly() {
        let ref = makeRef("shared:acme:coder")

        XCTAssertEqual(ref.refPrefix, "shared")
        XCTAssertEqual(ref.refName, "acme:coder")
        XCTAssertTrue(ref.isShared)
    }

    func testNameMayContainPathSeparatorsAndDots() {
        let ref = makeRef("local:team/coder.v2")

        XCTAssertEqual(ref.refPrefix, "local")
        XCTAssertEqual(ref.refName, "team/coder.v2")
        XCTAssertTrue(ref.isLocal)
    }

    /// `refPrefix`/`refName` slice by `Character`, so multi-scalar graphemes in a name must
    /// not be split apart.
    func testUnicodeNameIsPreserved() {
        let ref = makeRef("shared:agent-🧑‍🚀")

        XCTAssertEqual(ref.refPrefix, "shared")
        XCTAssertEqual(ref.refName, "agent-🧑‍🚀")
    }

    // MARK: - Decoded from team.json

    /// Parsing runs on refs read off disk, so pin the whole path: `team.json` bytes →
    /// `PackageTeamConfig` → per-ref source routing.
    func testRefsDecodedFromTeamConfigParseCorrectly() throws {
        let json = """
        {
          "agents": [
            { "id": "coder", "ref": "shared:coder" },
            { "id": "scratch", "ref": "user:scratch", "version": "1.2.0" },
            { "id": "custom", "ref": "local:custom", "overrides": { "model": "opus" } },
            { "id": "bare", "ref": "bare" }
          ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PackageTeamConfig.self, from: json)

        XCTAssertEqual(config.agents.count, 4)

        XCTAssertTrue(config.agents[0].isShared)
        XCTAssertEqual(config.agents[0].refName, "coder")

        XCTAssertTrue(config.agents[1].isUser)
        XCTAssertEqual(config.agents[1].refName, "scratch")

        XCTAssertTrue(config.agents[2].isLocal)
        XCTAssertEqual(config.agents[2].refName, "custom")

        XCTAssertEqual(config.agents[3].refPrefix, "")
        XCTAssertEqual(config.agents[3].refName, "bare")
    }

    /// `id` and `ref` are independent — routing must follow `ref`, never the identifier the
    /// agent is displayed under.
    func testParsingIgnoresIdentifier() {
        let ref = makeRef("local:actual-package", id: "shared:looks-shared")

        XCTAssertTrue(ref.isLocal)
        XCTAssertFalse(ref.isShared)
        XCTAssertEqual(ref.refName, "actual-package")
    }
}
