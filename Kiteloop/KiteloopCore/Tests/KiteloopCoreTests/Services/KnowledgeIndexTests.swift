import NaturalLanguage
import XCTest
@testable import KiteloopCore

/// The knowledge index keeps its chunks in `manifest.json` and their vectors in
/// `embeddings.bin` — two files, either of which can go missing or be left half
/// written on its own. `search` reads `vectors[i]` for every index it takes from
/// `chunks`, so a pair that no longer agrees is not a bad answer but a trap, and
/// the app going down mid-run is what strands an autopilot item.
final class KnowledgeIndexTests: XCTestCase {

    private var baseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseURL = try Self.makeCanonicalTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseURL)
        baseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Reconciliation arithmetic
    //
    // Asserted directly, because whether `search` reaches the vectors at all
    // depends on `NLEmbedding.sentenceEmbedding(for:)`, which a test machine may
    // not have.

    func testWholeRowsGiveTheRowWidth() {
        XCTAssertEqual(KnowledgeIndex.vectorRowDimension(doubleCount: 12, chunkCount: 3), 4)
        XCTAssertEqual(KnowledgeIndex.vectorRowDimension(doubleCount: 512, chunkCount: 1), 512)
    }

    func testAShortFileDoesNotLineUp() {
        // Two chunks' worth of manifest over one and a half rows of vectors.
        XCTAssertNil(KnowledgeIndex.vectorRowDimension(doubleCount: 6, chunkCount: 4))
        // Fewer doubles than chunks — the case that used to divide down to a
        // stride of zero.
        XCTAssertNil(KnowledgeIndex.vectorRowDimension(doubleCount: 2, chunkCount: 5))
    }

    func testAZeroLengthFileDoesNotLineUp() {
        XCTAssertNil(KnowledgeIndex.vectorRowDimension(doubleCount: 0, chunkCount: 3))
    }

    func testAnEmptyChunkListDoesNotLineUp() {
        XCTAssertNil(KnowledgeIndex.vectorRowDimension(doubleCount: 12, chunkCount: 0))
        XCTAssertNil(KnowledgeIndex.vectorRowDimension(doubleCount: 0, chunkCount: 0))
    }

    // MARK: - Loading a manifest whose vectors are gone

    func testAManifestWithNoVectorFileLeavesNoChunkWithoutItsVector() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 1)
        // No embeddings.bin at all.

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let counts = await index.loadedCounts()
        XCTAssertEqual(counts.chunks, counts.vectors)

        // Reaches the vectors rather than trapping, and answers from whatever
        // was rebuilt — not from the manifest that outlived its vectors.
        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    func testAManifestOverATruncatedVectorFileLeavesNoChunkWithoutItsVector() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 2)
        // Two chunks, but only one and a half rows of a three-wide vector.
        try writeVectors([1, 0, 0, 0, 1])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let counts = await index.loadedCounts()
        XCTAssertEqual(counts.chunks, counts.vectors)

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    /// A vector file whose byte length is not a whole number of doubles is the
    /// same corruption one step finer than a missing row.
    func testAManifestOverAPartialDoubleLeavesNoChunkWithoutItsVector() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 1)
        try Data([0x01, 0x02, 0x03]).write(to: vectorsURL)

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let counts = await index.loadedCounts()
        XCTAssertEqual(counts.chunks, counts.vectors)
    }

    // MARK: - Loading an index that does agree

    func testAMatchingManifestAndVectorFileAreKeptAsTheyAre() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 2)
        try writeVectors([1, 0, 0, 0, 1, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let counts = await index.loadedCounts()
        XCTAssertEqual(counts.chunks, 2)
        XCTAssertEqual(counts.vectors, 2)

        // The manifest's own text, which the file on disk does not contain: a
        // healthy index answers from what it loaded rather than being rebuilt.
        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertTrue(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    // MARK: - Fixtures

    private static let sentinel = "sentinel"
    private static let agentID = "alice"

    /// `KnowledgeIndex` derives a chunk's relative path by trimming its base path
    /// off the enumerated one, and `FileManager.temporaryDirectory` reports
    /// `/var/…` where an enumerator yields the canonical `/private/var/…`. The
    /// leaf is appended separately so the result carries no trailing slash, which
    /// that prefix trim would also miss.
    private static func makeCanonicalTempDir() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
        var canonicalParent = parent
        if let resolved = realpath(parent.path(percentEncoded: false), nil) {
            canonicalParent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        let url = canonicalParent.appending(path: "knowledge-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var indexURL: URL { baseURL.appending(path: ".index") }
    private var manifestURL: URL { indexURL.appending(path: "manifest.json") }
    private var vectorsURL: URL { indexURL.appending(path: "embeddings.bin") }

    private var knowledgeFileURL: URL {
        baseURL
            .appending(path: "agents")
            .appending(path: Self.agentID)
            .appending(path: "knowledge")
            .appending(path: "notes.md")
    }

    private func writeKnowledgeFile(text: String) throws {
        try FileManager.default.createDirectory(
            at: knowledgeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: knowledgeFileURL)
    }

    /// A manifest that covers the file on disk and is newer than it, so nothing
    /// about the *files* is stale — only the vectors beside it can be wrong.
    private func writeManifest(chunkCount: Int) throws {
        let mtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: knowledgeFileURL.path(percentEncoded: false))[.modificationDate] as? Date)
        let entries = (0..<chunkCount).map { idx in
            KnowledgeIndex.ChunkEntry(
                filePath: "agents/\(Self.agentID)/knowledge/notes.md",
                agentID: Self.agentID,
                chunkIndex: idx,
                text: "\(Self.sentinel) chunk \(idx) from the stored manifest",
                vectorOffset: idx,
                lastModified: mtime.addingTimeInterval(60)
            )
        }
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: manifestURL)
    }

    private func writeVectors(_ doubles: [Double]) throws {
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try doubles.withUnsafeBytes { Data($0) }.write(to: vectorsURL)
    }

    // MARK: - Which chunks a scope admits
    //
    // Three agents' worth of chunks, each scope asked which it lets through.
    // The manifest is what puts chunks under `alice`, `bob` and `shared` without
    // depending on the embedding: every file on disk has an entry newer than
    // itself, so nothing is rebuilt, and the query is a word every chunk holds
    // so the keyword fallback answers the same as the vector path.

    func testOwnScopeAdmitsOnlyThatAgentsChunks() async throws {
        try writeThreeAgentsWorthOfChunks()
        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .own(agentID: "alice"), topK: 10)
        XCTAssertEqual(Set(results.map(\.agentID)), ["alice"])
    }

    func testSharedScopeAdmitsOnlySharedChunks() async throws {
        try writeThreeAgentsWorthOfChunks()
        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .shared, topK: 10)
        XCTAssertEqual(Set(results.map(\.agentID)), ["shared"])
    }

    func testOwnAndSharedScopeAdmitsThatAgentAndSharedAndNothingElse() async throws {
        try writeThreeAgentsWorthOfChunks()
        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .ownAndShared(agentID: "alice"), topK: 10)
        XCTAssertEqual(Set(results.map(\.agentID)), ["alice", "shared"])
    }

    func testSpecificScopeAdmitsOnlyTheNamedAgentsChunks() async throws {
        try writeThreeAgentsWorthOfChunks()
        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .specific(agentID: "bob"), topK: 10)
        XCTAssertEqual(Set(results.map(\.agentID)), ["bob"])
    }

    // MARK: - Starting on a base directory that does not exist yet

    func testStartCreatesTheIndexDirectoryUnderABaseThatDoesNotExistYet() async throws {
        let base = baseURL.appending(path: "not-yet").appending(path: "knowledge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path(percentEncoded: false)))

        let index = KnowledgeIndex(baseURL: base)
        await index.start()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: base.appending(path: ".index").path(percentEncoded: false), isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue)
    }

    // MARK: - What makes a stored index stale
    //
    // Whether a rebuild happened is read off the sentinel: a manifest's own text
    // is not in any file on disk, so a rebuild — with the embedding, from the
    // files; without it, to nothing — always loses it.

    func testAFileNoNewerThanItsEntryKeepsTheStoredIndex() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        // A whole second, so the stamp survives the manifest's JSON round trip
        // exactly and the comparison is between equal dates.
        let stamp = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: knowledgeFileURL.path(percentEncoded: false))
        try writeManifest([entry(path: Self.agentNotesPath, agentID: Self.agentID, lastModified: stamp)])
        try writeVectors([1, 0, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertTrue(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    func testAFileNewerThanItsEntryIsReindexed() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let mtime = try modificationDate(of: knowledgeFileURL)
        try writeManifest([entry(path: Self.agentNotesPath, agentID: Self.agentID, lastModified: mtime.addingTimeInterval(-60))])
        try writeVectors([1, 0, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    func testAFileWithNoEntryIsReindexed() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 1)
        try writeVectors([1, 0, 0])
        // A second file beside it that the manifest knows nothing about.
        try Data("A sailor mends the net on the quay.".utf8).write(
            to: knowledgeFileURL.deletingLastPathComponent().appending(path: "extra.md"))

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    func testAnEntryForAFileThatIsGoneIsReindexed() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let mtime = try modificationDate(of: knowledgeFileURL)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, lastModified: mtime.addingTimeInterval(60)),
            entry(path: "agents/\(Self.agentID)/knowledge/gone.md", agentID: Self.agentID, index: 1,
                  lastModified: mtime.addingTimeInterval(60)),
        ])
        try writeVectors([1, 0, 0, 0, 1, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    // MARK: - A base directory with a space in its name
    //
    // Paths are compared as strings, and a space is where the percent-encoded
    // and the plain spelling of one path part ways.

    func testABaseDirectoryWithASpaceStillMatchesItsManifest() async throws {
        try useBaseDirectoryWithASpace()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeSharedFile(text: "A sailor mends the net on the quay.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, lastModified: later),
            entry(path: Self.sharedNotesPath, agentID: "shared", index: 1, lastModified: later),
        ])
        try writeVectors([1, 0, 0, 0, 1, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertEqual(Set(results.filter { $0.chunkText.contains(Self.sentinel) }.map(\.agentID)),
                       [Self.agentID, "shared"])
    }

    func testAnAgentFileNewerThanItsEntryIsReindexedUnderABaseDirectoryWithASpace() async throws {
        try useBaseDirectoryWithASpace()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let mtime = try modificationDate(of: knowledgeFileURL)
        try writeManifest([entry(path: Self.agentNotesPath, agentID: Self.agentID, lastModified: mtime.addingTimeInterval(-60))])
        try writeVectors([1, 0, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    func testASharedFileNewerThanItsEntryIsReindexedUnderABaseDirectoryWithASpace() async throws {
        try useBaseDirectoryWithASpace()
        try writeSharedFile(text: "A sailor mends the net on the quay.")
        let mtime = try modificationDate(of: sharedFileURL)
        try writeManifest([entry(path: Self.sharedNotesPath, agentID: "shared", lastModified: mtime.addingTimeInterval(-60))])
        try writeVectors([1, 0, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: Self.sentinel, scope: .all, topK: 5)
        XCTAssertFalse(results.contains { $0.chunkText.contains(Self.sentinel) })
    }

    // MARK: - The keyword fallback
    //
    // The embedding has no vector for whitespace, so a whitespace query is the
    // one that reaches the keyword path on a machine that has the embedding, and
    // the only path on one that does not.

    func testAnEmptyQueryFindsNothing() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        try writeManifest(chunkCount: 2)
        try writeVectors([1, 0, 0, 0, 1, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: "", scope: .all, topK: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testKeywordTiesKeepChunkOrder() async throws {
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        // A newline is the one whitespace `split(separator: " ")` keeps as a
        // keyword, and both chunks carry one: an exact tie.
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 0, text: "first\nchunk", lastModified: later),
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 1, text: "second\nchunk", lastModified: later),
        ])
        try writeVectors([1, 0, 0, 0, 1, 0])

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: "\n", scope: .all, topK: 5)
        XCTAssertEqual(results.map(\.chunkText), ["first\nchunk", "second\nchunk"])
    }

    // MARK: - The vector path
    //
    // These need the sentence embedding, which a test machine may not have, and
    // use its real vectors so the scores mean something.

    func testAQueryThatSharesNoWordWithAnyChunkIsStillAnswered() async throws {
        let embedding = try requireEmbedding()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 0, text: Self.kiteSentence, lastModified: later),
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 1, text: Self.sailorSentence, lastModified: later),
        ])
        try writeVectors(try vector(embedding, for: Self.kiteSentence) + vector(embedding, for: Self.sailorSentence))

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        // "zebra" is in neither chunk, so a keyword match would find nothing.
        let results = await index.search(query: "zebra", scope: .all, topK: 5)
        XCTAssertEqual(results.count, 2)
    }

    func testTheCloserChunkRanksFirstWithAPositiveScore() async throws {
        let embedding = try requireEmbedding()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 0, text: Self.kiteSentence, lastModified: later),
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 1, text: Self.sailorSentence, lastModified: later),
        ])
        try writeVectors(try vector(embedding, for: Self.kiteSentence) + vector(embedding, for: Self.sailorSentence))

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: "the sailor repairs his fishing net", scope: .all, topK: 5)
        XCTAssertEqual(results.first?.chunkText, Self.sailorSentence)
        XCTAssertGreaterThan(results.first?.score ?? 0, 0)
    }

    func testSimilarityTiesKeepChunkOrder() async throws {
        let embedding = try requireEmbedding()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 0, text: "first copy", lastModified: later),
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 1, text: "second copy", lastModified: later),
        ])
        // One vector stored twice: the two chunks score identically.
        let shared = try vector(embedding, for: Self.kiteSentence)
        try writeVectors(shared + shared)

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: "zebra", scope: .all, topK: 5)
        XCTAssertEqual(results.map(\.chunkText), ["first copy", "second copy"])
    }

    func testAChunkWithAZeroVectorScoresZeroNotNaN() async throws {
        let embedding = try requireEmbedding()
        try writeKnowledgeFile(text: "The kite loops over the harbour at dawn.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 0, text: Self.kiteSentence, lastModified: later),
            entry(path: Self.agentNotesPath, agentID: Self.agentID, index: 1, text: "zeroed", lastModified: later),
        ])
        let real = try vector(embedding, for: Self.kiteSentence)
        try writeVectors(real + [Double](repeating: 0, count: real.count))

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let results = await index.search(query: "zebra", scope: .all, topK: 5)
        let zeroed = try XCTUnwrap(results.first { $0.chunkText == "zeroed" })
        XCTAssertFalse(zeroed.score.isNaN)
        XCTAssertEqual(zeroed.score, 0)
    }

    // MARK: - How a file is cut into chunks
    //
    // Read off the manifest a fresh start writes, which is what the next start
    // loads. Chunking runs only when the embedding is there to vector each chunk.

    func testParagraphsAreJoinedAndBlankOnesDropped() async throws {
        try requireEmbedding()
        try writeKnowledgeFile(text: "Alpha.\n\n\n\nBeta.")

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        XCTAssertEqual(try storedChunkTexts(), ["Alpha.\n\nBeta."])
    }

    func testTwoParagraphsThatExactlyFillAChunkShareIt() async throws {
        try requireEmbedding()
        let first = String(repeating: "kite ", count: 99) + "kit"     // 498
        let second = String(repeating: "sail ", count: 99) + "sails"  // 500
        XCTAssertEqual(first.count + 2 + second.count, 1000)
        try writeKnowledgeFile(text: first + "\n\n" + second)

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        XCTAssertEqual(try storedChunkTexts(), [first + "\n\n" + second])
    }

    func testOneCharacterOverAChunkStartsTheNext() async throws {
        try requireEmbedding()
        let first = String(repeating: "kite ", count: 99) + "kit"      // 498
        let second = String(repeating: "sail ", count: 99) + "sails!"  // 501
        try writeKnowledgeFile(text: first + "\n\n" + second)

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        XCTAssertEqual(try storedChunkTexts(), [first, second])
    }

    func testTheLastParagraphIsKeptWhenAChunkOverflows() async throws {
        try requireEmbedding()
        let first = String(repeating: "kite ", count: 120)  // 600, trimmed to 599
        let second = String(repeating: "sail ", count: 120)
        try writeKnowledgeFile(text: first + "\n\n" + second)

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        let texts = try storedChunkTexts()
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.last, second.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testFrontmatterClosedOnceIsStripped() async throws {
        try requireEmbedding()
        try writeKnowledgeFile(text: "---\ntitle: Harbour notes\n---\nBody paragraph.")

        let index = KnowledgeIndex(baseURL: baseURL)
        await index.start()

        XCTAssertEqual(try storedChunkTexts(), ["Body paragraph."])
    }

    // MARK: - Fixtures for the above

    private static let kiteSentence = "The kite loops over the harbour at dawn."
    private static let sailorSentence = "A sailor mends the net on the quay."
    private static let agentNotesPath = "agents/\(agentID)/knowledge/notes.md"
    private static let sharedNotesPath = "shared/notes.md"

    private var sharedFileURL: URL {
        baseURL.appending(path: "shared").appending(path: "notes.md")
    }

    @discardableResult
    private func requireEmbedding() throws -> NLEmbedding {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw XCTSkip("the English sentence embedding is not available on this machine")
        }
        return embedding
    }

    private func vector(_ embedding: NLEmbedding, for text: String) throws -> [Double] {
        try XCTUnwrap(embedding.vector(for: text))
    }

    /// Swaps the set-up base for one whose name has a space, which `tearDown`
    /// removes as it would the other.
    private func useBaseDirectoryWithASpace() throws {
        try FileManager.default.removeItem(at: baseURL)
        let parent = baseURL.deletingLastPathComponent()
        baseURL = parent.appending(path: "knowledge index \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
    }

    private func writeSharedFile(text: String) throws {
        try FileManager.default.createDirectory(
            at: sharedFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sharedFileURL)
    }

    private func writeAgentFile(agentID: String, text: String) throws {
        let url = baseURL.appending(path: "agents").appending(path: agentID)
            .appending(path: "knowledge").appending(path: "notes.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func entry(path: String, agentID: String, index: Int = 0, text: String? = nil,
                       lastModified: Date) -> KnowledgeIndex.ChunkEntry {
        KnowledgeIndex.ChunkEntry(
            filePath: path,
            agentID: agentID,
            chunkIndex: index,
            text: text ?? "\(Self.sentinel) chunk \(index) from the stored manifest",
            vectorOffset: index,
            lastModified: lastModified
        )
    }

    private func writeManifest(_ entries: [KnowledgeIndex.ChunkEntry]) throws {
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: manifestURL)
    }

    /// Files for `alice`, `bob` and `shared`, each covered by a manifest entry
    /// newer than itself, with one three-wide vector per chunk.
    private func writeThreeAgentsWorthOfChunks() throws {
        try writeAgentFile(agentID: "alice", text: Self.kiteSentence)
        try writeAgentFile(agentID: "bob", text: Self.sailorSentence)
        try writeSharedFile(text: "Tide tables for the week.")
        let later = try modificationDate(of: knowledgeFileURL).addingTimeInterval(60)
        try writeManifest([
            entry(path: "agents/alice/knowledge/notes.md", agentID: "alice", index: 0, lastModified: later),
            entry(path: "agents/bob/knowledge/notes.md", agentID: "bob", index: 1, lastModified: later),
            entry(path: Self.sharedNotesPath, agentID: "shared", index: 2, lastModified: later),
        ])
        try writeVectors([1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    /// The chunk texts in the manifest on disk, in chunk order.
    private func storedChunkTexts() throws -> [String] {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([KnowledgeIndex.ChunkEntry].self, from: data).map(\.text)
    }
}
