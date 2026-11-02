import XCTest
import KiteloopCore
@testable import Kiteloop

/// `TeamConfigWatcher` holds one `O_EVTONLY` descriptor on the project's
/// `.kiteloop/` directory for as long as the project is open. `stop()` used to
/// close it *and* cancel the dispatch source whose cancel handler closes it too,
/// so every project close, project switch and `deinit` closed the same fd number
/// twice. A descriptor number is reused the moment it is free: between the two
/// closes the process can hand it to any other open file, socket or tool-bridge
/// FIFO, and the second close then shuts that under its new owner.
///
/// "Closed once" is not readable off the code — the second close is asynchronous
/// and silent — so these tests count the closes through the closer the watcher
/// releases its descriptor with.
final class TeamConfigWatcherTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "team-config-watcher-test")
    }

    // MARK: - Descriptor ownership

    func testStopThenDeinitClosesTheDescriptorExactlyOnce() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])
        let closes = CloseRecorder()

        var watcher: TeamConfigWatcher? = TeamConfigWatcher(
            teamConfigURL: configURL,
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) { _ in }

        watcher?.stop()
        try await eventually("the cancel handler released the descriptor") { closes.count == 1 }
        XCTAssertEqual(closes.count, 1, "stop() must leave the close to the cancel handler")

        watcher = nil                       // deinit calls stop() again
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 1, "deinit after stop() must not close the fd a second time")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(closes.descriptors.first), 0, "a real descriptor was closed")
    }

    func testStopCalledTwiceClosesTheDescriptorExactlyOnce() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])
        let closes = CloseRecorder()

        let watcher = TeamConfigWatcher(
            teamConfigURL: configURL,
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) { _ in }
        defer { watcher.stop() }

        watcher.stop()
        watcher.stop()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 1)
    }

    /// `deinit` on its own is the project-switch path where nobody called `stop()`.
    /// The cancel handler runs after the watcher is gone, so it must not need it.
    func testDeinitWithoutStopClosesTheDescriptorExactlyOnce() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])
        let closes = CloseRecorder()

        var watcher: TeamConfigWatcher? = TeamConfigWatcher(
            teamConfigURL: configURL,
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) { _ in }

        watcher = nil
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(watcher)
        XCTAssertEqual(closes.count, 1, "the descriptor must not leak when only deinit releases the watcher")
    }

    /// `startWatching` returns early when `open` fails — a project whose
    /// `.kiteloop/` directory is not there. There is no descriptor to release, and
    /// `stop()` must not release the `-1` that stands in for one.
    func testWatcherThatNeverOpenedADescriptorClosesNothing() async throws {
        let missingDir = tempDir.appending(path: "no-such-directory")
        let closes = CloseRecorder()

        var watcher: TeamConfigWatcher? = TeamConfigWatcher(
            teamConfigURL: missingDir.appending(path: "team.json"),
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) { _ in }

        watcher?.stop()
        watcher = nil
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(closes.count, 0)
    }

    // MARK: - Watching

    func testEditingTeamConfigReportsTheDecodedTemplates() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])

        let sawChange = XCTestExpectation(description: "onChanged for the edit")
        let recorder = LoadRecorder(first: sawChange)
        let watcher = TeamConfigWatcher(teamConfigURL: configURL, debounceInterval: 0.05) {
            recorder.record($0)
        }
        defer { watcher.stop() }

        // Give the dispatch source time to arm, and put the edit's mtime clear of
        // the one the watcher recorded when it started.
        try await Task.sleep(for: .milliseconds(1100))
        _ = try writeTeam([AgentTemplate(name: "Reviewer"), AgentTemplate(name: "Builder")])

        await fulfillment(of: [sawChange], timeout: 5.0)
        XCTAssertEqual(recorder.lastInlineNames, ["Reviewer", "Builder"])
    }

    /// The regression: a team.json in the package-ref shape — what the setup
    /// wizard writes, and what `~/.kiteloop/home/.kiteloop/team.json` holds — was
    /// decoded as an `[AgentTemplate]` array, failed, and was dropped without a
    /// word, so an agent added to it by hand only appeared at the next project
    /// open. End to end here: the watcher reports the file, and the resolution
    /// the boot path's closure performs turns it into both agents' templates.
    @MainActor
    func testEditingAPackageShapedTeamConfigReportsBothResolvedAgents() async throws {
        try writeAgentPackage(handle: "reviewer", name: "Reviewer", model: "sonnet")
        try writeAgentPackage(handle: "builder", name: "Builder", model: "sonnet")
        let resolver = try await loadedResolver()

        let configURL = try writePackageTeam([ref(id: "reviewer")])

        let sawChange = XCTestExpectation(description: "onChanged for the package-ref edit")
        let recorder = LoadRecorder(first: sawChange)
        let watcher = TeamConfigWatcher(teamConfigURL: configURL, debounceInterval: 0.05) {
            recorder.record($0)
        }
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(1100))
        _ = try writePackageTeam([ref(id: "reviewer"), ref(id: "builder")])

        await fulfillment(of: [sawChange], timeout: 5.0)

        let load = try XCTUnwrap(recorder.lastLoad)
        let templates = ProjectSession.liveTemplates(
            for: load,
            resolver: resolver,
            localAgentsURL: localAgentsURL
        )
        XCTAssertEqual(templates.map(\.name), ["Reviewer", "Builder"])
        XCTAssertEqual(templates.map(\.id), ["reviewer", "builder"])
    }

    /// A file that is neither shape — a truncated save, an editor's half-written
    /// buffer — is nothing to act on, and reporting it would hand a live project
    /// an empty team.
    func testAFileOfNeitherShapeReportsNothing() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])

        let recorder = LoadRecorder()
        let watcher = TeamConfigWatcher(teamConfigURL: configURL, debounceInterval: 0.05) {
            recorder.record($0)
        }
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(1100))
        try Data(#"[{"name": "Reviewer", "mod"#.utf8).write(to: configURL, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(recorder.count, 0)
    }

    func testStopPreventsCallbacks() async throws {
        let configURL = try writeTeam([AgentTemplate(name: "Reviewer")])

        let recorder = LoadRecorder()
        let watcher = TeamConfigWatcher(teamConfigURL: configURL, debounceInterval: 0.05) {
            recorder.record($0)
        }
        try await Task.sleep(for: .milliseconds(1100))
        watcher.stop()

        _ = try writeTeam([AgentTemplate(name: "Reviewer"), AgentTemplate(name: "Builder")])
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - What a reported change resolves to

    /// The overrides on a ref are the same ones the boot path lays over the
    /// package's template — one mapping, so a live reload can't drift from what
    /// opening the project would have produced.
    @MainActor
    func testPackageRefOverridesAreAppliedToTheResolvedTemplate() async throws {
        try writeAgentPackage(handle: "reviewer", name: "Reviewer", model: "sonnet")
        let resolver = try await loadedResolver()

        let overridden = ref(id: "reviewer", overrides: AgentOverrides(model: "opus", denied: ["Bash"]))
        let templates = ProjectSession.liveTemplates(
            for: .packages(PackageTeamConfig(agents: [overridden])),
            resolver: resolver,
            localAgentsURL: localAgentsURL
        )

        XCTAssertEqual(templates.map(\.model), ["opus"])
        XCTAssertEqual(templates.first?.denied, ["Bash"])
    }

    @MainActor
    func testInlineTemplatesResolveToThemselves() async throws {
        let resolver = try await loadedResolver()
        let inline = [AgentTemplate(name: "Reviewer"), AgentTemplate(name: "Builder")]

        let templates = ProjectSession.liveTemplates(
            for: .templates(inline),
            resolver: resolver,
            localAgentsURL: localAgentsURL
        )

        XCTAssertEqual(templates.map(\.name), ["Reviewer", "Builder"])
    }

    /// An empty `agents` list is a decodable package config that configures no
    /// team, and a ref naming a package that isn't installed resolves to nothing.
    /// Both must leave the running team alone rather than empty it — the same
    /// answer the old `!templates.isEmpty` guard gave.
    @MainActor
    func testAPackageConfigThatResolvesToNoAgentsResolvesToNoTemplates() async throws {
        try writeAgentPackage(handle: "reviewer", name: "Reviewer", model: "sonnet")
        let resolver = try await loadedResolver()

        XCTAssertTrue(ProjectSession.liveTemplates(
            for: .packages(PackageTeamConfig(agents: [])),
            resolver: resolver,
            localAgentsURL: localAgentsURL
        ).isEmpty, "an empty agents list configures no team")

        XCTAssertTrue(ProjectSession.liveTemplates(
            for: .packages(PackageTeamConfig(agents: [ref(id: "nobody")])),
            resolver: resolver,
            localAgentsURL: localAgentsURL
        ).isEmpty, "a ref naming no installed package resolves to nothing")
    }

    /// Without a resolver there is nothing to look refs up in — the boot path
    /// falls back to the predefined agents there, which is not something to do to
    /// a project already running its team.
    @MainActor
    func testPackageRefsWithoutAResolverResolveToNoTemplates() {
        XCTAssertTrue(ProjectSession.liveTemplates(
            for: .packages(PackageTeamConfig(agents: [ref(id: "reviewer")])),
            resolver: nil,
            localAgentsURL: localAgentsURL
        ).isEmpty)
    }

    @MainActor
    func testAbsentAndUnreadableResolveToNoTemplates() async throws {
        let resolver = try await loadedResolver()

        XCTAssertTrue(ProjectSession.liveTemplates(
            for: .absent, resolver: resolver, localAgentsURL: localAgentsURL
        ).isEmpty)
        XCTAssertTrue(ProjectSession.liveTemplates(
            for: .unreadable(reason: "truncated"), resolver: resolver, localAgentsURL: localAgentsURL
        ).isEmpty)
    }

    // MARK: - Helpers

    /// Writes `team.json` the way `TeamConfigManager.saveTeam` does — encoded the
    /// same way, and landed by a write-to-temp + rename, which is what the app,
    /// an editor and an agent's Edit tool all do — and hands back its URL.
    @discardableResult
    private func writeTeam(_ templates: [AgentTemplate]) throws -> URL {
        try write(templates)
    }

    /// The other shape: what `SetupWizardViewModel.writeTeamConfig` writes.
    @discardableResult
    private func writePackageTeam(_ refs: [PackageAgentRef]) throws -> URL {
        try write(PackageTeamConfig(agents: refs))
    }

    private func write<T: Encodable>(_ value: T) throws -> URL {
        let url = tempDir.appending(path: "team.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        return url
    }

    private func ref(id: String, overrides: AgentOverrides? = nil) -> PackageAgentRef {
        PackageAgentRef(id: id, ref: "shared:\(id)", version: nil, overrides: overrides)
    }

    /// The shared scan path a resolver reads packages from, and the project's
    /// local agents directory a `local:` ref would resolve against.
    private var knowledgeURL: URL { tempDir.appending(path: "knowledge") }
    private var localAgentsURL: URL { tempDir.appending(path: "local-agents") }

    private func writeAgentPackage(handle: String, name: String, model: String) throws {
        let dir = knowledgeURL.appending(path: "agents").appending(path: handle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"handle": "\(handle)", "version": "1.0.0",
         "template": {"name": "\(name)", "model": "\(model)", "systemPrompt": "You are \(name)."},
         "knowledge": {"critical": [], "files": [], "imports": []}}
        """
        try Data(json.utf8).write(to: dir.appending(path: "agent.json"))
    }

    @MainActor
    private func loadedResolver() async throws -> PackageResolver {
        let resolver = PackageResolver(scanPaths: [AgentScanPath(url: knowledgeURL, source: .shared)])
        await resolver.ensureLoaded()
        return resolver
    }
}

/// Thread-safe tally of the descriptors the watcher released. The closer runs on
/// the dispatch source's queue, and it really closes the fd so a test never leaks
/// one.
private final class CloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptors: [Int32] = []

    var descriptors: [Int32] { lock.withLock { _descriptors } }
    var count: Int { lock.withLock { _descriptors.count } }

    func record(_ fd: Int32) {
        lock.withLock { _descriptors.append(fd) }
        close(fd)
    }
}

/// Thread-safe tally for the watcher's `@Sendable` callback, which fires on a
/// background queue.
private final class LoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _lastLoad: ProjectSession.TeamConfigLoad?
    private var firstFulfilled = false
    private let first: XCTestExpectation?

    init(first: XCTestExpectation? = nil) {
        self.first = first
    }

    var count: Int { lock.withLock { _count } }
    var lastLoad: ProjectSession.TeamConfigLoad? { lock.withLock { _lastLoad } }

    /// The names in the last load, when it was the self-contained shape — the
    /// package shape carries refs, not names, until a resolver has been at it.
    var lastInlineNames: [String] {
        guard case .templates(let templates) = lastLoad else { return [] }
        return templates.map(\.name)
    }

    func record(_ load: ProjectSession.TeamConfigLoad) {
        let fulfillFirst = lock.withLock { () -> Bool in
            _count += 1
            _lastLoad = load
            let isFirst = !firstFulfilled
            firstFulfilled = true
            return isFirst
        }
        if fulfillFirst { first?.fulfill() }
    }
}
