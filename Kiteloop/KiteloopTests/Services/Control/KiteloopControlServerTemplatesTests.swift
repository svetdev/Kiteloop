import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/backlog/templates` and `POST /v1/backlog/templates/stamp`, over a
/// real loopback socket.
///
/// The endpoint is the whole entry point — a recurring process nobody can stamp
/// without opening the UI is still tribal knowledge — so the refusals matter as
/// much as the filing: a stamp refused by a constraint or a collision must leave
/// the backlog exactly as it found it.
@MainActor
final class KiteloopControlServerTemplatesTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var globalConfigStore: GlobalConfigStore!
    private let token = "control-templates-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-templates")
        registry = ControlSessionRegistry()
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        globalConfigStore = nil
    }

    /// Two ordered items and one constrained variable — the release checklist's
    /// shape. `verify:` cites `BACKLOG.md`, which the fixture project really has,
    /// so the grounding gate passes and the items file as `ready`.
    private let template = """
    ---
    description: A two-item process
    epic: Now
    variables:
      - name: version
        description: The version being shipped
        pattern: ^\\d+\\.\\d+\\.\\d+$
    ---

    ## Item

    - [ ] release-{{version}}-spec | Bump the spec to {{version}} | size:XS | verify:grep -q {{version}} BACKLOG.md

    ## What

    The spec reads {{version}}.

    ## How

    Edit `BACKLOG.md`.

    ## Validation

    - [ ] The spec reads {{version}}

    ## Out of Scope

    - Anything else

    ## Item

    - [ ] release-{{version}}-notes | Flip the notes to {{version}} | size:XS | verify:grep -q {{version}} BACKLOG.md | needs:release-{{version}}-spec

    ## What

    The notes name {{version}}.

    ## How

    Edit `BACKLOG.md`.

    ## Validation

    - [ ] The notes name {{version}}

    ## Out of Scope

    - Writing new entries
    """

    // MARK: - Listing

    func testListReturnsEachTemplateWithItsVariables() async throws {
        try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.get("/v1/backlog/templates?project=alpha")

        XCTAssertEqual(status, 200)
        let templates = try XCTUnwrap(body["templates"] as? [[String: Any]])
        // The three built-in kind skeletons are always listed too — see
        // testListAlwaysIncludesTheThreeGroomingKindSkeletons.
        XCTAssertEqual(templates.count, 4)
        XCTAssertEqual(templates[0]["name"] as? String, "release")
        XCTAssertEqual(templates[0]["epic"] as? String, "Now")
        XCTAssertEqual(templates[0]["items"] as? Int, 2)
        let variables = try XCTUnwrap(templates[0]["variables"] as? [[String: Any]])
        XCTAssertEqual(variables.count, 1)
        XCTAssertEqual(variables[0]["name"] as? String, "version")
        XCTAssertEqual(variables[0]["required"] as? Bool, true)
        XCTAssertEqual(variables[0]["pattern"] as? String, #"^\d+\.\d+\.\d+$"#)
    }

    /// An empty list is unreadable on its own — it can't be told from "the app
    /// looked somewhere else" — so where it looked comes with it.
    func testAnEmptyListSaysWhereTheAppLooked() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.get("/v1/backlog/templates?project=alpha")

        XCTAssertEqual(status, 200)
        // No `templates/*.md` in this project, but the three kind skeletons
        // are Swift constants, not files, so they're still listed.
        XCTAssertEqual((body["templates"] as? [[String: Any]])?.count, 3)
        let directories = try XCTUnwrap(body["directories"] as? [String])
        XCTAssertFalse(directories.isEmpty)
        XCTAssertTrue(directories.contains { $0.hasSuffix("/templates") }, "\(directories)")
    }

    /// `ItemKind.gate` is unreachable if nothing surfaces its three skeletons —
    /// `bug`, `feature`, `tooling` — to whoever is hand-grooming an item, so the
    /// listing always includes them, sourced from the constants in
    /// `BacklogTemplate.swift` rather than a `templates/*.md` duplicate.
    func testListAlwaysIncludesTheThreeGroomingKindSkeletons() async throws {
        try registerProject(named: "alpha")

        let (_, body) = try await harness.get("/v1/backlog/templates?project=alpha")

        let templates = try XCTUnwrap(body["templates"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: templates.map { ($0["name"] as? String ?? "", $0) })
        for name in ["bug", "feature", "tooling"] {
            let entry = try XCTUnwrap(byName[name], name)
            XCTAssertEqual(entry["kind"] as? Bool, true, name)
            XCTAssertNil(entry["path"], name)
            XCTAssertEqual(entry["items"] as? Int, 1, name)
            XCTAssertNotNil(entry["description"] as? String, name)
            XCTAssertFalse((entry["variables"] as? [[String: Any]] ?? []).isEmpty, name)
        }
    }

    /// A file-backed template takes precedence over a kind skeleton of the same
    /// name — the same shadowing rule that already lets a project-local
    /// template shadow a repo one.
    func testAFileBackedTemplateShadowsAKindSkeletonOfTheSameName() async throws {
        try registerProject(named: "alpha")
        try writeTemplate(named: "bug", content: template)

        let (_, body) = try await harness.get("/v1/backlog/templates?project=alpha")

        let templates = try XCTUnwrap(body["templates"] as? [[String: Any]])
        let bugs = templates.filter { $0["name"] as? String == "bug" }
        XCTAssertEqual(bugs.count, 1)
        XCTAssertNotNil(bugs[0]["path"], "the file-backed template should win, not the skeleton")
        XCTAssertNil(bugs[0]["kind"])
    }

    func testAnUnparseableTemplateIsListedWithItsError() async throws {
        try registerProject(named: "alpha")
        try writeTemplate(named: "broken", content: "Just prose about a process.")

        let (_, body) = try await harness.get("/v1/backlog/templates?project=alpha")

        let templates = try XCTUnwrap(body["templates"] as? [[String: Any]])
        XCTAssertEqual(templates[0]["name"] as? String, "broken")
        XCTAssertNotNil(templates[0]["error"] as? String)
        XCTAssertNil(templates[0]["variables"])
    }

    func testListWithoutAProjectIs400() async throws {
        let (status, body) = try await harness.get("/v1/backlog/templates")
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Missing ?project=")
    }

    func testListForAnUnknownProjectIs409() async throws {
        let (status, body) = try await harness.get("/v1/backlog/templates?project=nope")
        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: nope")
    }

    func testListRequiresBearerToken() async throws {
        try registerProject(named: "alpha")
        let (status, _) = try await harness.get("/v1/backlog/templates?project=alpha", bearer: nil)
        XCTAssertEqual(status, 401)
    }

    // MARK: - Preview

    /// The default is a preview: a driver can show what it is about to file
    /// without having filed it.
    func testStampWithoutApplyPreviewsAndWritesNothing() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release", "variables": ["version": "1.2.3"]
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["applied"] as? Bool, false)
        XCTAssertNil(body["filed"])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String },
                       ["release-1.2.3-spec", "release-1.2.3-notes"])
        XCTAssertTrue((items[1]["detail"] as? String ?? "").contains("## Validation"))
        XCTAssertNil(backlog.item(withID: "release-1.2.3-spec"), "a preview writes nothing")
    }

    // MARK: - Filing

    func testApplyFilesEveryItemWithItsDetailFileAndItsOrdering() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["applied"] as? Bool, true)
        XCTAssertEqual(body["filed"] as? [String], ["release-1.2.3-spec", "release-1.2.3-notes"])
        XCTAssertEqual(body["epic"] as? String, "Now")

        // The lines, with the template's ordering as `needs:` edges.
        let first = try XCTUnwrap(backlog.item(withID: "release-1.2.3-spec"))
        let second = try XCTUnwrap(backlog.item(withID: "release-1.2.3-notes"))
        XCTAssertEqual(first.needs, [])
        XCTAssertEqual(second.needs, ["release-1.2.3-spec"])
        XCTAssertEqual(first.size, .xs)
        XCTAssertEqual(first.verify, "grep -q 1.2.3 BACKLOG.md")

        // And their groomed detail files, which is what makes them runnable.
        for id in ["release-1.2.3-spec", "release-1.2.3-notes"] {
            let url = tempDir.appendingPathComponent("alpha/backlog/\(id).md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), id)
            let detail = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(detail.contains("## What"), id)
            XCTAssertFalse(detail.contains("{{"), "\(id) still holds a placeholder")
        }
    }

    /// The same two gates a coordinator filing faces. Everything the fixture
    /// cites exists, so the items are queued rather than parked.
    func testFiledItemsPassTheSameGatesAsACoordinatorFiling() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (_, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["ready", "ready"])
        XCTAssertEqual(items.compactMap { $0["gates"] as? [String] }.flatMap { $0 }, [])
        XCTAssertEqual(backlog.item(withID: "release-1.2.3-spec")?.status, .ready)
    }

    // MARK: - Kind gate

    /// The acceptance criterion `ItemKind.gate` exists for: a `kind: "feature"`
    /// stamp whose `## What` carries no user-visible-outcome sentence is filed
    /// `draft`, naming the missing clause — on top of, not instead of, the same
    /// two gates every stamp already faces.
    func testAKindFeatureStampWithoutTheOutcomeSentenceIsFiledAsDraft() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (_, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release", "kind": "feature",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["draft", "draft"])
        for item in items {
            XCTAssertTrue((item["gates"] as? [String] ?? []).contains { $0.contains("User-visible outcome:") },
                          "\(item["gates"] ?? "")")
        }
        XCTAssertEqual(backlog.item(withID: "release-1.2.3-spec")?.status, .draft)
    }

    /// The same detail, with the sentence, passes — `kind` adds no field to
    /// judge, only a clause the existing `## What` must carry.
    func testAKindFeatureStampWithTheOutcomeSentencePasses() async throws {
        let backlog = try registerProject(named: "alpha")
        let withOutcome = template
            .replacingOccurrences(of: "The spec reads {{version}}.",
                                  with: "The spec reads {{version}}.\n\nUser-visible outcome: the spec file itself shows {{version}}.")
            .replacingOccurrences(of: "The notes name {{version}}.",
                                  with: "The notes name {{version}}.\n\nUser-visible outcome: the notes now name {{version}}.")
        try writeTemplate(named: "release", content: withOutcome)

        let (_, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release", "kind": "feature",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["ready", "ready"])
        XCTAssertEqual(backlog.item(withID: "release-1.2.3-spec")?.status, .ready)
    }

    /// A request that leaves `kind` out is today's behaviour, byte for byte:
    /// the same detail with no outcome sentence still files `ready`, because
    /// nothing but an explicit `kind` runs this gate.
    func testAKindlessStampIgnoresTheMissingOutcomeSentence() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (_, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["ready", "ready"])
        XCTAssertEqual(backlog.item(withID: "release-1.2.3-spec")?.status, .ready)
    }

    func testAnUnrecognisedKindIs400() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release", "kind": "epic",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        XCTAssertEqual(status, 400)
        XCTAssertTrue((body["error"] as? String ?? "").contains("bug"), "\(body["error"] ?? "")")
        XCTAssertNil(backlog.item(withID: "release-1.2.3-spec"))
    }

    /// An item whose `verify:` cites a file the repo does not have is parked as
    /// `draft` with the reason, rather than queued to fail at pickup — which is
    /// how a checklist that went stale is caught.
    func testAnItemThatFailsAGateIsFiledAsDraftWithTheReason() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "stale", content: template
            .replacingOccurrences(of: "BACKLOG.md", with: "MOVED-AWAY.md"))

        let (_, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "stale",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["status"] as? String, "draft")
        XCTAssertTrue((items[0]["gates"] as? [String] ?? []).contains { $0.contains("grounding") },
                      "\(items[0]["gates"] ?? "")")
        XCTAssertEqual(backlog.item(withID: "release-1.2.3-spec")?.status, .draft)
    }

    // MARK: - Whole-stamp refusals

    /// The acceptance criterion this feature turns on: a constraint violation
    /// refuses everything and names the variable.
    func testAValueFailingItsConstraintRefusesTheWholeStamp() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "next"], "apply": true
        ])

        XCTAssertEqual(status, 422)
        let error = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(error.contains("version"), error)
        XCTAssertTrue(error.contains("next"), error)
        XCTAssertNil(backlog.item(withID: "release-next-spec"), "nothing may be written")
    }

    /// An id collision refuses the whole stamp — no partial. The second item of
    /// the template collides, so the *first* is the one that must not appear:
    /// filing it alone would leave it queued and its successor missing.
    func testAnIDCollisionRefusesTheWholeStampWithNoPartialWrite() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")
        backlog.addItem(sectionName: "Now", id: "release-1.2.3-notes", title: "Filed by hand",
                        verify: nil)

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "1.2.3"], "apply": true
        ])

        XCTAssertEqual(status, 422)
        XCTAssertTrue((body["error"] as? String ?? "").contains("release-1.2.3-notes"),
                      "\(body["error"] ?? "")")
        XCTAssertNil(backlog.item(withID: "release-1.2.3-spec"),
                     "the first item must not be filed when a later one collides")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("alpha/backlog/release-1.2.3-spec.md")
                .path(percentEncoded: false)),
            "no detail file may be written either")
    }

    /// Re-stamping a release that was already filed collides on every id and
    /// refuses — the guard against double-filing, since a stamped item keeps no
    /// link back to its template.
    func testReStampingTheSameReleaseIsRefused() async throws {
        try registerProject(named: "alpha")
        try writeTemplate(named: "release")
        let payload: [String: Any] = ["project": "alpha", "template": "release",
                                      "variables": ["version": "1.2.3"], "apply": true]

        let (first, _) = try await harness.post("/v1/backlog/templates/stamp", payload)
        let (second, body) = try await harness.post("/v1/backlog/templates/stamp", payload)

        XCTAssertEqual(first, 201)
        XCTAssertEqual(second, 422)
        XCTAssertTrue((body["error"] as? String ?? "").contains("release-1.2.3-spec"),
                      "\(body["error"] ?? "")")
    }

    func testAMissingRequiredVariableIs422() async throws {
        try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, body) = try await harness.post("/v1/backlog/templates/stamp",
                                            ["project": "alpha", "template": "release"])

        XCTAssertEqual(status, 422)
        XCTAssertTrue((body["error"] as? String ?? "").contains("version"), "\(body["error"] ?? "")")
    }

    // MARK: - Bad requests

    func testStampWithoutATemplateIs400() async throws {
        try registerProject(named: "alpha")
        let (status, body) = try await harness.post("/v1/backlog/templates/stamp",
                                            ["project": "alpha"])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"template\"")
    }

    func testStampOfATemplateThatDoesNotExistIs404() async throws {
        try registerProject(named: "alpha")
        let (status, body) = try await harness.post("/v1/backlog/templates/stamp",
                                            ["project": "alpha", "template": "nope"])
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "No template \"nope\" in this project")
    }

    func testStampForAnUnknownProjectIs409() async throws {
        let (status, _) = try await harness.post("/v1/backlog/templates/stamp",
                                         ["project": "nope", "template": "release"])
        XCTAssertEqual(status, 409)
    }

    func testStampRequiresBearerToken() async throws {
        let backlog = try registerProject(named: "alpha")
        try writeTemplate(named: "release")

        let (status, _) = try await harness.post("/v1/backlog/templates/stamp", [
            "project": "alpha", "template": "release",
            "variables": ["version": "1.2.3"], "apply": true
        ], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertNil(backlog.item(withID: "release-1.2.3-spec"),
                     "an unauthenticated call writes nothing")
    }

    // MARK: - Helpers

    private func writeTemplate(named name: String, content: String? = nil) throws {
        let url = tempDir.appendingPathComponent("alpha/templates/\(name).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (content ?? template).write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func registerProject(named name: String) throws -> BacklogViewModel {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        try "# \(name) Backlog\n\n## Now\n\n"
            .write(to: root.appendingPathComponent("BACKLOG.md"), atomically: true, encoding: .utf8)

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        session.backlogViewModel.loadForProject(repoPath: rootURL.path(percentEncoded: false))

        let autopilot = BacklogAutopilot()
        autopilot.workerAgentID = "worker"
        autopilot.reviewerAgentID = "reviewer"
        registry.register(session: session, autopilot: autopilot)
        return session.backlogViewModel
    }

    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: globalConfigStore,
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
