import Foundation
import NaturalLanguage

package actor KnowledgeIndex {
    package struct SearchResult: Sendable {
        package let filePath: String
        package let agentID: String
        package let chunkText: String
        package let score: Double
        package let source: Source

        package enum Source: String, Sendable {
            case curated
            case agentWritten
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(filePath: String, agentID: String, chunkText: String, score: Double, source: Source) {
            self.filePath = filePath
            self.agentID = agentID
            self.chunkText = chunkText
            self.score = score
            self.source = source
        }
    }

    package struct ChunkEntry: Codable {
        package let filePath: String
        package let agentID: String
        package let chunkIndex: Int
        package let text: String
        package let vectorOffset: Int
        package let lastModified: Date
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(filePath: String, agentID: String, chunkIndex: Int, text: String, vectorOffset: Int, lastModified: Date) {
            self.filePath = filePath
            self.agentID = agentID
            self.chunkIndex = chunkIndex
            self.text = text
            self.vectorOffset = vectorOffset
            self.lastModified = lastModified
        }
    }

    private let baseURL: URL
    private let indexURL: URL
    private var chunks: [ChunkEntry] = []
    private var vectors: [[Double]] = []
    private var embedding: NLEmbedding?
    private var isAvailable: Bool = false
    private var watcher: DirectoryWatcher?

    private static let chunkSeparator = "\n\n"
    private static let maxChunkLength = 1000

    package init(baseURL: URL) {
        self.baseURL = baseURL
        self.indexURL = baseURL.appending(path: ".index")
    }

    package func start() {
        if let emb = NLEmbedding.sentenceEmbedding(for: .english) {
            self.embedding = emb
            self.isAvailable = true
        } else {
            self.isAvailable = false
        }

        createIndexDirectoryIfNeeded()
        loadManifest()
        rebuildStaleEntries()
        startWatching()
    }

    package func search(query: String, scope: SearchScope, topK: Int = 5) -> [SearchResult] {
        guard isAvailable, let embedding else {
            return keywordFallback(query: query, scope: scope, topK: topK)
        }

        guard let queryVector = embedding.vector(for: query) else {
            return keywordFallback(query: query, scope: scope, topK: topK)
        }

        let queryArr = arrayFromVector(queryVector)
        let filtered = filteredIndices(for: scope)

        var scored: [(index: Int, score: Double)] = []
        for i in filtered {
            let sim = cosineSimilarity(queryArr, vectors[i])
            scored.append((i, sim))
        }

        scored.sort { $0.score > $1.score }
        let topResults = scored.prefix(topK)

        return topResults.map { item in
            let chunk = chunks[item.index]
            return SearchResult(
                filePath: chunk.filePath,
                agentID: chunk.agentID,
                chunkText: chunk.text,
                score: item.score,
                source: classifySource(chunk)
            )
        }
    }

    package func rebuildIndex() {
        chunks.removeAll()
        vectors.removeAll()
        indexAllFiles()
        saveManifest()
    }

    /// How many chunks and how many vectors the index is holding — the pair
    /// `search` indexes into, for tests to assert they line up.
    package func loadedCounts() -> (chunks: Int, vectors: Int) {
        (chunks.count, vectors.count)
    }

    // MARK: - Scope

    package enum SearchScope: Sendable {
        case own(agentID: String)
        case shared
        case ownAndShared(agentID: String)
        case specific(agentID: String)
        case all
    }

    // MARK: - Private

    private func filteredIndices(for scope: SearchScope) -> [Int] {
        switch scope {
        case .own(let agentID):
            return chunks.indices.filter { chunks[$0].agentID == agentID }
        case .shared:
            return chunks.indices.filter { chunks[$0].agentID == "shared" }
        case .ownAndShared(let agentID):
            return chunks.indices.filter { chunks[$0].agentID == agentID || chunks[$0].agentID == "shared" }
        case .specific(let agentID):
            return chunks.indices.filter { chunks[$0].agentID == agentID }
        case .all:
            return Array(chunks.indices)
        }
    }

    private func classifySource(_ chunk: ChunkEntry) -> SearchResult.Source {
        let url = baseURL.appending(path: chunk.filePath)
        guard let content = String(lenientContentsOf: url) else { return .curated }
        return content.contains("authorAgent:") ? .agentWritten : .curated
    }

    private func createIndexDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
    }

    private func startWatching() {
        let agentsDir = baseURL.appending(path: "agents")
        let sharedDir = baseURL.appending(path: "shared")
        var dirs = [agentsDir]
        if FileManager.default.fileExists(atPath: sharedDir.path(percentEncoded: false)) {
            dirs.append(sharedDir)
        }
        watcher = DirectoryWatcher(directories: dirs, debounceInterval: 2.0) { [weak self] in
            guard let self else { return }
            Task { await self.handleFileChange() }
        }
    }

    private nonisolated func handleFileChange() async {
        await rebuildStaleEntries()
    }

    private func rebuildStaleEntries() {
        let currentFiles = discoverMarkdownFiles()
        var needsRebuild = false

        for file in currentFiles {
            let relativePath = file.relativePath
            let mtime = file.modifiedDate

            if let existing = chunks.first(where: { $0.filePath == relativePath }) {
                if existing.lastModified < mtime {
                    needsRebuild = true
                    break
                }
            } else {
                needsRebuild = true
                break
            }
        }

        let existingPaths = Set(currentFiles.map(\.relativePath))
        if chunks.contains(where: { !existingPaths.contains($0.filePath) }) {
            needsRebuild = true
        }

        if needsRebuild {
            rebuildIndex()
        }
    }

    private func indexAllFiles() {
        guard let embedding else { return }

        let files = discoverMarkdownFiles()
        for file in files {
            guard let content = String(lenientContentsOf: file.url) else { continue }
            let body = stripFrontmatter(content)
            let fileChunks = chunkText(body)

            for (idx, chunk) in fileChunks.enumerated() {
                guard let vector = embedding.vector(for: chunk) else { continue }
                let entry = ChunkEntry(
                    filePath: file.relativePath,
                    agentID: file.agentID,
                    chunkIndex: idx,
                    text: chunk,
                    vectorOffset: vectors.count,
                    lastModified: file.modifiedDate
                )
                chunks.append(entry)
                vectors.append(arrayFromVector(vector))
            }
        }
    }

    private struct DiscoveredFile {
        let url: URL
        let relativePath: String
        let agentID: String
        let modifiedDate: Date
    }

    private func discoverMarkdownFiles() -> [DiscoveredFile] {
        var results: [DiscoveredFile] = []
        let fm = FileManager.default
        let basePath = baseURL.path(percentEncoded: false)

        let agentsDir = baseURL.appending(path: "agents")
        if let agentDirs = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for agentDir in agentDirs {
                let isDir = (try? agentDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { continue }
                let agentID = agentDir.lastPathComponent
                let knowledgeDir = agentDir.appending(path: "knowledge")
                let files = findMarkdownFiles(in: knowledgeDir)
                for file in files {
                    let rel = file.path(percentEncoded: false).replacingOccurrences(of: basePath + "/", with: "")
                    let mtime = (try? fm.attributesOfItem(atPath: file.path(percentEncoded: false))[.modificationDate] as? Date) ?? .distantPast
                    results.append(DiscoveredFile(url: file, relativePath: rel, agentID: agentID, modifiedDate: mtime))
                }
            }
        }

        let sharedDir = baseURL.appending(path: "shared")
        if fm.fileExists(atPath: sharedDir.path(percentEncoded: false)) {
            let files = findMarkdownFiles(in: sharedDir)
            for file in files {
                let rel = file.path(percentEncoded: false).replacingOccurrences(of: basePath + "/", with: "")
                let mtime = (try? fm.attributesOfItem(atPath: file.path(percentEncoded: false))[.modificationDate] as? Date) ?? .distantPast
                results.append(DiscoveredFile(url: file, relativePath: rel, agentID: "shared", modifiedDate: mtime))
            }
        }

        return results
    }

    private func findMarkdownFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files
    }

    private func chunkText(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: Self.chunkSeparator)
        var result: [String] = []
        var buffer = ""

        for para in paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if buffer.isEmpty {
                buffer = trimmed
            } else if buffer.count + trimmed.count + 2 <= Self.maxChunkLength {
                buffer += "\n\n" + trimmed
            } else {
                result.append(buffer)
                buffer = trimmed
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }

    private func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let parts = content.components(separatedBy: "\n---")
        guard parts.count >= 2 else { return content }
        return parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func arrayFromVector(_ vector: [Double]) -> [Double] {
        vector
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Keyword Fallback

    private func keywordFallback(query: String, scope: SearchScope, topK: Int) -> [SearchResult] {
        let keywords = query.lowercased().split(separator: " ").map(String.init)
        let filtered = filteredIndices(for: scope)

        var scored: [(index: Int, score: Double)] = []
        for i in filtered {
            let text = chunks[i].text.lowercased()
            let hits = keywords.filter { text.contains($0) }.count
            if hits > 0 {
                scored.append((i, Double(hits) / Double(keywords.count)))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(topK).map { item in
            let chunk = chunks[item.index]
            return SearchResult(
                filePath: chunk.filePath,
                agentID: chunk.agentID,
                chunkText: chunk.text,
                score: item.score,
                source: classifySource(chunk)
            )
        }
    }

    // MARK: - Manifest Persistence

    private var manifestURL: URL { indexURL.appending(path: "manifest.json") }
    private var vectorsURL: URL { indexURL.appending(path: "embeddings.bin") }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ChunkEntry].self, from: data) else {
            return
        }
        chunks = decoded
        loadVectors()
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(chunks) else { return }
        try? data.write(to: manifestURL, options: .atomic)
        saveVectors()
    }

    /// The row width `doubleCount` doubles imply for `chunkCount` chunks, or nil
    /// when the two do not describe the same index.
    ///
    /// `manifest.json` and `embeddings.bin` are two files and either can be lost,
    /// truncated or half-written on its own. `search` reads `vectors[i]` for every
    /// index taken from `chunks`, so a pair that disagrees is a trap on the next
    /// query rather than a bad answer — and one missing vector is enough. The
    /// only shape that can be served is a file that divides evenly into one row
    /// per chunk, each row of the same non-zero width; anything else, including a
    /// vector file for an empty manifest, is not an index and is discarded.
    package static func vectorRowDimension(doubleCount: Int, chunkCount: Int) -> Int? {
        guard chunkCount > 0, doubleCount > 0 else { return nil }
        guard doubleCount % chunkCount == 0 else { return nil }
        return doubleCount / chunkCount
    }

    private func loadVectors() {
        guard let data = try? Data(contentsOf: vectorsURL),
              data.count % MemoryLayout<Double>.size == 0 else {
            discardIndex()
            return
        }
        let doubleCount = data.count / MemoryLayout<Double>.size
        guard let dim = Self.vectorRowDimension(doubleCount: doubleCount, chunkCount: chunks.count) else {
            discardIndex()
            return
        }

        var loaded = [Double](repeating: 0, count: doubleCount)
        _ = loaded.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        vectors = stride(from: 0, to: doubleCount, by: dim).map { start in
            Array(loaded[start..<(start + dim)])
        }
    }

    /// Drop both halves together. `rebuildStaleEntries()` judges staleness by
    /// what `chunks` already covers, so a manifest left in place over a vector
    /// file that no longer matches it looks complete and is never rebuilt;
    /// emptying it is what makes the existing rebuild happen.
    private func discardIndex() {
        chunks = []
        vectors = []
    }

    private func saveVectors() {
        let flat = vectors.flatMap { $0 }
        let data = flat.withUnsafeBytes { Data($0) }
        try? data.write(to: vectorsURL, options: .atomic)
    }
}
