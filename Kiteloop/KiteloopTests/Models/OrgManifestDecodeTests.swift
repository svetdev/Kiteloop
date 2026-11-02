// Kiteloop/KiteloopTests/Models/OrgManifestDecodeTests.swift
import XCTest
@testable import Kiteloop

/// `OrgManifest` is the decoded form of a `manifest.json` dropped next to a shared or
/// user agent package directory. `OrgManifestLoader.read` decodes it with a plain
/// `JSONDecoder` behind `try?` — a manifest that fails to decode is silently skipped and
/// the app carries on with no org config. That makes the exact optionality of each field
/// load-bearing: these tests pin which blocks a manifest may omit (`version`, `org`, and
/// every field inside them), which it may not (`name`), and that unknown keys written by
/// a newer Kiteloop — or by an older one, which is what the retired `evals` block now is
/// — don't take the whole manifest down.
final class OrgManifestDecodeTests: XCTestCase {

    // MARK: - Helpers

    /// Mirrors `OrgManifestLoader.read` — no key or date strategy.
    private func decoder() -> JSONDecoder { JSONDecoder() }

    private func decode(_ json: String) throws -> OrgManifest {
        try decoder().decode(OrgManifest.self, from: Data(json.utf8))
    }

    private func keys<T: Encodable>(of value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - Full manifest

    func testDecodesManifestWithOrgBlock() throws {
        let json = """
        {
          "name": "Acme Platform",
          "version": "1.2.0",
          "org": { "githubOrg": "acme", "workspaceName": "Platform" }
        }
        """

        let manifest = try decode(json)

        XCTAssertEqual(manifest.name, "Acme Platform")
        XCTAssertEqual(manifest.version, "1.2.0")
        XCTAssertEqual(manifest.org?.githubOrg, "acme")
        XCTAssertEqual(manifest.org?.workspaceName, "Platform")
    }

    // MARK: - Optional blocks omitted

    func testDecodesMinimalManifestWithNoOrg() throws {
        // The smallest manifest a team can write — just a name.
        let manifest = try decode(#"{"name": "Acme"}"#)

        XCTAssertEqual(manifest.name, "Acme")
        XCTAssertNil(manifest.version)
        XCTAssertNil(manifest.org)
    }

    func testDecodesExplicitNullOrgAsNil() throws {
        // A generator that always writes every key emits JSON null rather than omitting.
        let json = #"{"name": "Acme", "version": null, "org": null}"#

        let manifest = try decode(json)

        XCTAssertNil(manifest.version)
        XCTAssertNil(manifest.org)
    }

    func testDecodesEmptyOrgBlockWithAllFieldsNil() throws {
        let manifest = try decode(#"{"name": "Acme", "org": {}}"#)

        XCTAssertNotNil(manifest.org)
        XCTAssertNil(manifest.org?.githubOrg)
        XCTAssertNil(manifest.org?.workspaceName)
    }

    func testDecodesPartiallyFilledOrgBlock() throws {
        let onlyGitHub = try decode(#"{"name": "Acme", "org": {"githubOrg": "acme"}}"#)
        XCTAssertEqual(onlyGitHub.org?.githubOrg, "acme")
        XCTAssertNil(onlyGitHub.org?.workspaceName)

        let onlyWorkspace = try decode(#"{"name": "Acme", "org": {"workspaceName": "Core"}}"#)
        XCTAssertNil(onlyWorkspace.org?.githubOrg)
        XCTAssertEqual(onlyWorkspace.org?.workspaceName, "Core")
    }

    // MARK: - Retired blocks

    func testDecodesManifestThatStillCarriesARetiredEvalsBlock() throws {
        // `evals` seeded the eval-scenario store, which no longer exists. Manifests
        // written against the old schema are still sitting in package directories, so
        // the block has to read as an unknown key rather than a decode failure — the
        // whole manifest, org config included, would otherwise be dropped by `try?`.
        let json = """
        {
          "name": "Acme",
          "org": {"githubOrg": "acme"},
          "evals": [
            {"id": "e1", "title": "T", "prompt": "P", "tags": ["sre"]}
          ]
        }
        """

        let manifest = try decode(json)

        XCTAssertEqual(manifest.name, "Acme")
        XCTAssertEqual(manifest.org?.githubOrg, "acme")
    }

    func testDecodesManifestWhoseRetiredEvalsBlockIsMalformed() throws {
        // A half-written eval def used to take the manifest down with it. Nothing reads
        // the block now, so its shape stops mattering entirely — including the shapes
        // the old decoder rejected outright.
        let missingRequiredFields = #"{"name": "Acme", "evals": [{"id": "e1"}]}"#
        XCTAssertEqual(try decode(missingRequiredFields).name, "Acme")

        let notAnArray = #"{"name": "Acme", "evals": {"id": "e1"}}"#
        XCTAssertEqual(try decode(notAnArray).name, "Acme")
    }

    // MARK: - Rejected manifests

    func testDecodeRejectsManifestWithoutName() {
        // `name` is the one required field; without it the loader's `try?` drops the
        // whole manifest and the org runs unconfigured.
        let json = #"{"version": "1.0", "org": {"githubOrg": "acme"}}"#

        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeRejectsNullName() {
        XCTAssertThrowsError(try decode(#"{"name": null}"#))
    }

    func testDecodeRejectsNonStringName() {
        XCTAssertThrowsError(try decode(#"{"name": 42}"#))
    }

    func testDecodeRejectsOrgBlockOfWrongShape() {
        XCTAssertThrowsError(try decode(#"{"name": "Acme", "org": "acme"}"#))
        XCTAssertThrowsError(try decode(#"{"name": "Acme", "org": {"githubOrg": ["acme"]}}"#))
    }

    func testDecodeRejectsMalformedJSON() {
        XCTAssertThrowsError(try decode(#"{"name": "Acme","#))
        XCTAssertThrowsError(try decode(""))
    }

    // MARK: - Forward compatibility

    func testDecodeIgnoresUnknownTopLevelAndNestedKeys() throws {
        // A manifest written by a newer Kiteloop must still load in an older one.
        let json = """
        {
          "name": "Acme",
          "schemaVersion": 3,
          "policies": {"maxCostUSD": 5},
          "org": {"githubOrg": "acme", "slackWorkspace": "acme-hq"}
        }
        """

        let manifest = try decode(json)

        XCTAssertEqual(manifest.name, "Acme")
        XCTAssertEqual(manifest.org?.githubOrg, "acme")
    }

    func testDecodesPrettyPrintedManifestWithUnicodeAndMultilineFields() throws {
        // Manifests are hand-edited: expect BOM-free but multi-line values and accents.
        let json = """
        {
          "name": "Café Ops — 東京",
          "org": { "workspaceName": "Café Ops" }
        }
        """

        let manifest = try decode(json)

        XCTAssertEqual(manifest.name, "Café Ops — 東京")
        XCTAssertEqual(manifest.org?.workspaceName, "Café Ops")
    }

    // MARK: - Round-trip

    func testRoundTripPreservesFullManifest() throws {
        let original = try decode("""
        {
          "name": "Acme", "version": "2.0",
          "org": {"githubOrg": "acme", "workspaceName": "Core"}
        }
        """)

        let data = try JSONEncoder().encode(original)
        let decoded = try decoder().decode(OrgManifest.self, from: data)

        XCTAssertEqual(decoded.name, "Acme")
        XCTAssertEqual(decoded.version, "2.0")
        XCTAssertEqual(decoded.org?.githubOrg, "acme")
        XCTAssertEqual(decoded.org?.workspaceName, "Core")
    }

    func testRoundTripKeepsOmittedBlocksOmitted() throws {
        let minimal = try decode(#"{"name": "Acme"}"#)

        XCTAssertEqual(try keys(of: minimal), ["name"])

        let decoded = try decoder().decode(
            OrgManifest.self, from: try JSONEncoder().encode(minimal)
        )
        XCTAssertEqual(decoded.name, "Acme")
        XCTAssertNil(decoded.version)
        XCTAssertNil(decoded.org)
    }
}
