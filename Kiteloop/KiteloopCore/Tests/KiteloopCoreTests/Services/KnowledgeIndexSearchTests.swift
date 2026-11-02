import NaturalLanguage
import XCTest
@testable import KiteloopCore

/// Covers `KnowledgeIndex.search` — the scope filter that decides which chunks are
/// eligible, and the ranking that orders the eligible ones.
final class KnowledgeIndexSearchTests: XCTestCase {

    private var tmpDir: URL!

    /// Fixture layout — one chunk per file, each on a clearly different topic so
    /// ranking assertions do not hinge on fine-grained embedding differences.
    private enum Fixture {
        static let alphaDeploy = "agents/alpha/knowledge/deploy.md"
        static let alphaCooking = "agents/alpha/knowledge/cooking.md"
        static let betaSprint = "agents/beta/knowledge/sprint.md"
        static let sharedOnboarding = "shared/onboarding.md"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = try Self.makeCanonicalTempDir(prefix: "ki-test")

        try write(Fixture.alphaDeploy, """
        # Deployments

        Deployments run every Thursday. We deploy the service to production using ArgoCD and Kubernetes.
        """)
        try write(Fixture.alphaCooking, """
        # Sourdough

        Sourdough bread needs a starter. Feed the starter with flour and water, then bake the loaf in a hot oven.
        """)
        try write(Fixture.betaSprint, """
        # Sprint Planning

        Sprint planning happens on Monday mornings. The team estimates stories and commits to the sprint backlog.
        """)
        try write(Fixture.sharedOnboarding, """
        # Onboarding

        New hires get a laptop on their first day and pair with a buddy for the first two weeks.
        """)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try super.tearDownWithError()
    }

    /// `FileManager.temporaryDirectory` reports `/var/…` while a directory enumerator
    /// yields the canonical `/private/var/…`. `KnowledgeIndex` derives a chunk's
    /// relative path by trimming its base path off the enumerated one, so the fixture
    /// root has to be canonical for those two to line up.
    private static func makeCanonicalTempDir(prefix: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
        var canonicalParent = parent
        if let resolved = realpath(parent.path(percentEncoded: false), nil) {
            canonicalParent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        // Append the leaf separately: the resulting path must not carry a trailing
        // slash, or the base-path prefix trim in KnowledgeIndex will not match.
        let url = canonicalParent.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = tmpDir.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeStartedIndex() async -> KnowledgeIndex {
        let index = KnowledgeIndex(baseURL: tmpDir)
        await index.start()
        return index
    }

    /// Skips the caller when the vector path is unavailable, rather than
    /// failing on assertions that only hold when `search` reaches the
    /// embedding — see `KnowledgeIndexTests.requireEmbedding()`.
    private func requireEmbedding() throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else {
            throw XCTSkip("the English sentence embedding is not available on this machine")
        }
    }

    // MARK: - Scope filter

    /// Written straight to the manifest, the way `testKeywordFallbackMatchesOnAWhitespaceQuery`
    /// below does, rather than through `makeStartedIndex()` — the scope filter
    /// and the `topK` truncation both run before any vector math, and every
    /// agent here has fewer chunks than `topK`, so the assertion never actually
    /// needs a real embedding. Routing it through one anyway ties the result to
    /// whether `NLEmbedding` happens to be loaded on this run: unavailable, the
    /// keyword fallback would answer the same; available but still loading, a
    /// hand-written vector row of the wrong width scores 0 rather than crashing
    /// — either way every chunk stays in scope, but going through the real
    /// pipeline is what let this flip once between a red and a green reading of
    /// the same commit.
    func testOwnScopeReturnsOnlyThatAgentsChunks() async throws {
        let fixtures: [(path: String, agentID: String)] = [
            (Fixture.alphaDeploy, "alpha"),
            (Fixture.alphaCooking, "alpha"),
            (Fixture.betaSprint, "beta"),
            (Fixture.sharedOnboarding, "shared"),
        ]

        let indexDir = tmpDir.appending(path: ".index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        let entries = try fixtures.map { fixture -> KnowledgeIndex.ChunkEntry in
            let fileURL = tmpDir.appending(path: fixture.path)
            let mtime = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.modificationDate] as? Date)
            return KnowledgeIndex.ChunkEntry(
                filePath: fixture.path, agentID: fixture.agentID, chunkIndex: 0,
                text: "deployment notes", vectorOffset: 0, lastModified: mtime.addingTimeInterval(60))
        }
        try JSONEncoder().encode(entries).write(to: indexDir.appending(path: "manifest.json"))
        try [Double](repeating: 1.0, count: entries.count).withUnsafeBytes { Data($0) }
            .write(to: indexDir.appending(path: "embeddings.bin"))

        let index = KnowledgeIndex(baseURL: tmpDir)
        await index.start()

        let results = await index.search(query: "deployment", scope: .own(agentID: "alpha"), topK: 10)

        XCTAssertEqual(Set(results.map(\.agentID)), ["alpha"])
        XCTAssertEqual(Set(results.map(\.filePath)), [Fixture.alphaDeploy, Fixture.alphaCooking])
    }

    func testSharedScopeReturnsOnlySharedChunks() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "onboarding", scope: .shared, topK: 10)

        XCTAssertEqual(Set(results.map(\.agentID)), ["shared"])
        XCTAssertEqual(results.map(\.filePath), [Fixture.sharedOnboarding])
    }

    func testOwnAndSharedScopeIncludesSharedButExcludesOtherAgents() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "deployment", scope: .ownAndShared(agentID: "alpha"), topK: 10)

        XCTAssertEqual(Set(results.map(\.agentID)), ["alpha", "shared"])
        XCTAssertEqual(
            Set(results.map(\.filePath)),
            [Fixture.alphaDeploy, Fixture.alphaCooking, Fixture.sharedOnboarding]
        )
        XCTAssertFalse(results.contains { $0.filePath == Fixture.betaSprint })
    }

    func testSpecificScopeReturnsOnlyRequestedAgent() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "planning", scope: .specific(agentID: "beta"), topK: 10)

        XCTAssertEqual(results.map(\.agentID), ["beta"])
        XCTAssertEqual(results.map(\.filePath), [Fixture.betaSprint])
    }

    func testAllScopeReturnsEveryAgentAndShared() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "team", scope: .all, topK: 10)

        XCTAssertEqual(Set(results.map(\.agentID)), ["alpha", "beta", "shared"])
        XCTAssertEqual(results.count, 4)
    }

    func testScopeForUnknownAgentReturnsNoResults() async {
        let index = await makeStartedIndex()

        let results = await index.search(query: "deployment", scope: .own(agentID: "does-not-exist"), topK: 10)

        XCTAssertTrue(results.isEmpty)
    }

    func testSearchOnEmptyIndexReturnsNoResults() async throws {
        let emptyDir = try Self.makeCanonicalTempDir(prefix: "ki-empty")
        try FileManager.default.createDirectory(at: emptyDir.appending(path: "agents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let index = KnowledgeIndex(baseURL: emptyDir)
        await index.start()

        let results = await index.search(query: "anything", scope: .all, topK: 10)

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Ranking

    func testResultsAreOrderedByDescendingScore() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "how do we deploy to production", scope: .all, topK: 10)

        XCTAssertEqual(results.count, 4)
        let scores = results.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "results should be sorted by descending similarity")
    }

    func testTopKLimitsResultCount() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let limited = await index.search(query: "how do we deploy to production", scope: .all, topK: 2)
        let unlimited = await index.search(query: "how do we deploy to production", scope: .all, topK: 10)

        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(unlimited.count, 4)
        // The truncated set must be the highest-scoring prefix of the full ranking.
        XCTAssertEqual(limited.map(\.filePath), Array(unlimited.prefix(2).map(\.filePath)))
    }

    func testTopKGreaterThanIndexSizeReturnsAllChunks() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "deployment", scope: .all, topK: 100)

        XCTAssertEqual(results.count, 4)
    }

    func testSemanticallyClosestChunkRanksFirst() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let deployTop = await index.search(query: "how do we deploy to production", scope: .all, topK: 1)
        let bakingTop = await index.search(query: "baking bread at home", scope: .all, topK: 1)
        let sprintTop = await index.search(query: "sprint planning meeting", scope: .all, topK: 1)

        XCTAssertEqual(deployTop.first?.filePath, Fixture.alphaDeploy)
        XCTAssertEqual(bakingTop.first?.filePath, Fixture.alphaCooking)
        XCTAssertEqual(sprintTop.first?.filePath, Fixture.betaSprint)
    }

    func testScoresStayWithinCosineSimilarityRange() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "how do we deploy to production", scope: .all, topK: 10)

        XCTAssertFalse(results.isEmpty)
        for result in results {
            XCTAssertGreaterThanOrEqual(result.score, -1.0)
            XCTAssertLessThanOrEqual(result.score, 1.0)
        }
    }

    func testResultsCarryChunkTextAndSource() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        let results = await index.search(query: "how do we deploy to production", scope: .all, topK: 1)

        let top = try XCTUnwrap(results.first)
        XCTAssertTrue(top.chunkText.contains("ArgoCD"))
        XCTAssertEqual(top.source, .curated)
    }

    /// A byte that is not UTF-8 no longer drops the file from the index, and its
    /// `authorAgent:` marker still classifies it as agent-written.
    func testFileWithABadByteIsIndexedAndClassifiedAsAgentWritten() async throws {
        try requireEmbedding()
        let relativePath = "agents/alpha/knowledge/incidents.md"
        let url = tmpDir.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data("authorAgent: alpha\n\n# Incidents\n\nWhen the pager fires, acknowledge the alert ".utf8)
            + Data([0xFF])
            + Data(" and page the on-call engineer.\n".utf8)).write(to: url)
        let index = await makeStartedIndex()

        let results = await index.search(query: "who is paged during an incident", scope: .all, topK: 10)

        let match = try XCTUnwrap(results.first { $0.filePath == relativePath })
        XCTAssertEqual(match.source, .agentWritten)
    }

    // MARK: - Ranking after re-index

    func testRankingReflectsNewlyAddedFileAfterRebuild() async throws {
        try requireEmbedding()
        let index = await makeStartedIndex()

        try! write("agents/alpha/knowledge/incidents.md", """
        # Incidents

        When the pager fires, acknowledge the alert, open an incident channel and page the on-call engineer.
        """)
        await index.rebuildIndex()

        let results = await index.search(query: "who is paged during an incident", scope: .all, topK: 10)

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.first?.filePath, "agents/alpha/knowledge/incidents.md")
    }

    // MARK: - The keyword fallback
    //
    // Every other test in this file builds its index from live markdown, which
    // needs the embedding to chunk at all — so it cannot measure `search` on a
    // machine without one. This one writes straight to the manifest, the way
    // `KnowledgeIndexTests`' own keyword-fallback section does, and queries with
    // a newline: the one whitespace `split(separator: " ")` keeps as a keyword,
    // and the embedding has no vector for it. That reaches `keywordFallback`
    // regardless of whether this machine has the embedding at all.

    func testKeywordFallbackMatchesOnAWhitespaceQuery() async throws {
        let dir = try Self.makeCanonicalTempDir(prefix: "ki-keyword")
        defer { try? FileManager.default.removeItem(at: dir) }

        let relativePath = "agents/alpha/knowledge/notes.md"
        let fileURL = dir.appending(path: relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: fileURL)
        let mtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.modificationDate] as? Date)

        let indexDir = dir.appending(path: ".index")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        let entries = [
            KnowledgeIndex.ChunkEntry(filePath: relativePath, agentID: "alpha", chunkIndex: 0,
                                       text: "first\nchunk", vectorOffset: 0, lastModified: mtime.addingTimeInterval(60)),
            KnowledgeIndex.ChunkEntry(filePath: relativePath, agentID: "alpha", chunkIndex: 1,
                                       text: "second\nchunk", vectorOffset: 1, lastModified: mtime.addingTimeInterval(60)),
        ]
        try JSONEncoder().encode(entries).write(to: indexDir.appending(path: "manifest.json"))
        try [1.0, 0, 0, 0, 1, 0].withUnsafeBytes { Data($0) }.write(to: indexDir.appending(path: "embeddings.bin"))

        let index = KnowledgeIndex(baseURL: dir)
        await index.start()

        let results = await index.search(query: "\n", scope: .all, topK: 10)

        XCTAssertEqual(results.map(\.chunkText), ["first\nchunk", "second\nchunk"])
    }
}
