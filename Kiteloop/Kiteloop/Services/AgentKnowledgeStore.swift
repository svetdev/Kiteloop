import Foundation
import KiteloopCore
import Observation

@Observable
final class AgentKnowledgeStore: @unchecked Sendable, KnowledgeProviding {
    private(set) var agents: [TrainedAgent] = []
    let baseURL: URL
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    /// How the `O_EVTONLY` descriptor is released — `close(2)` in the app. A test
    /// substitutes a counting closer, which is the only way to assert the fd is
    /// released exactly once rather than by reading the code.
    private let closeDescriptor: @Sendable (Int32) -> Void

    static let defaultBaseURL: URL = {
        let home = KiteloopHome.url
        return home.appending(path: ".kiteloop/knowledge")
    }()

    init(
        baseURL: URL = AgentKnowledgeStore.defaultBaseURL,
        closeDescriptor: @escaping @Sendable (Int32) -> Void = { close($0) }
    ) {
        self.baseURL = baseURL
        self.closeDescriptor = closeDescriptor
        reload()
        startWatching()
    }

    deinit {
        stop()
    }

    /// Releases the watcher on `knowledge/agents`. Cancelling the source is the
    /// whole of it: its cancel handler owns the descriptor and closes it exactly
    /// once, whenever it happens to run. A resumed source is also not deallocated
    /// until it is cancelled, so without this both the fd and the kevent
    /// registration outlive the store — one of each per project open. Idempotent:
    /// `directoryWatcher` is dropped here, so a second `stop()`, or the one
    /// `deinit` makes, cancels nothing.
    func stop() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    func reload() {
        let agentsDir = baseURL.appending(path: "agents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            agents = []
            return
        }
        agents = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { loadAgent(at: $0) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func saveFile(at url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    func knowledgeContent(for agentID: String) -> String? {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return nil }
        let files = flattenFiles(agent.knowledgeFiles)
        guard !files.isEmpty else { return nil }
        var sections: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sections.append("## \(file.name)\n\n\(content)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n---\n\n")
    }

    private func flattenFiles(_ files: [TrainedAgent.KnowledgeFile]) -> [TrainedAgent.KnowledgeFile] {
        files.flatMap { file in
            file.isDirectory ? flattenFiles(file.children) : [file]
        }
    }

    // MARK: - Private

    private func loadAgent(at url: URL) -> TrainedAgent? {
        let profileURL = url.appending(path: "profile.md")
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        let content = String(decoding: data, as: UTF8.self)
        let parsed = parseFrontmatter(content)
        let knowledgeDir = url.appending(path: "knowledge")
        let tree = buildTree(at: knowledgeDir, relativeTo: knowledgeDir)
        return TrainedAgent(
            id: url.lastPathComponent,
            name: parsed.meta["name"] ?? url.lastPathComponent,
            model: parsed.meta["model"] ?? "sonnet",
            avatar: parsed.meta["avatar"] ?? "🤖",
            description: parsed.meta["description"] ?? "",
            group: parsed.meta["group"],
            systemPrompt: parsed.body,
            knowledgeFiles: tree,
            basePath: url
        )
    }

    private func buildTree(at url: URL, relativeTo base: URL) -> [TrainedAgent.KnowledgeFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let rel = entry.path().replacingOccurrences(of: base.path(), with: "")
                return TrainedAgent.KnowledgeFile(
                    id: rel,
                    name: entry.lastPathComponent,
                    relativePath: rel,
                    url: entry,
                    isDirectory: isDir,
                    children: isDir ? buildTree(at: entry, relativeTo: base) : []
                )
            }
    }

    private func parseFrontmatter(_ content: String) -> (meta: [String: String], body: String) {
        guard content.hasPrefix("---") else { return ([:], content) }
        let parts = content.components(separatedBy: "\n---")
        guard parts.count >= 2 else { return ([:], content) }
        let frontmatter = parts[0].replacingOccurrences(of: "---", with: "")
        let body = parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)
        var meta: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            var value = kv[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            meta[kv[0].trimmingCharacters(in: .whitespaces)] = value
        }
        return (meta, body)
    }

    // MARK: - Directory Watching

    private func startWatching() {
        let agentsDir = baseURL.appending(path: "agents")
        let path = agentsDir.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
        }

        // The fd and the closer are captured by value, not through `self`: a
        // cancel scheduled by `deinit` runs after the store is gone, and a
        // handler that reached for `self` would find nil and leak the descriptor.
        source.setCancelHandler { [weak self, closeDescriptor, fd] in
            closeDescriptor(fd)
            if let self, self.watchedFD == fd { self.watchedFD = -1 }
        }

        source.resume()
        directoryWatcher = source
    }
}
