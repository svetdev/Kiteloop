import Foundation
import KiteloopCore

actor KnowledgeRecallService {
    private let knowledgeStore: AgentKnowledgeStore

    init(knowledgeStore: AgentKnowledgeStore) {
        self.knowledgeStore = knowledgeStore
    }

    func identityTier(for agentID: String) -> String {
        guard let agent = knowledgeStore.agents.first(where: { $0.id == agentID }) else {
            return ""
        }
        let domains = knowledgeDomains(for: agent)
        var parts: [String] = []
        parts.append("You are \(agent.name). \(agent.description).")
        if !domains.isEmpty {
            parts.append("Knowledge domains: \(domains.joined(separator: ", "))")
        }
        parts.append("Use recall_knowledge(\"topic\") to access detailed information.")
        return parts.joined(separator: "\n")
    }

    func indexTier(for agentID: String) -> String {
        guard let agent = knowledgeStore.agents.first(where: { $0.id == agentID }) else {
            return ""
        }
        return generateManifest(for: agent)
    }

    /// How many knowledge sections one recall hands back.
    ///
    /// The same cap, for the same reason, as ``MemoryManager/maxRecalledTopics``
    /// on the memory half of the same tool call: a tool result is context too,
    /// and a package is one section per knowledge file with no bound on how many
    /// files an agent has. Without a cap a query matching every section — which
    /// the single-word fallback makes easy, one common word is enough — answers
    /// with the whole package, which is the unbounded always-injected knowledge
    /// the identity/index/recall tiers exist to prevent, arriving through a tool
    /// result instead of the system prompt.
    static let maxRecalledSections = 5

    /// Knowledge sections matching `query`, at most ``maxRecalledSections`` of them.
    ///
    /// Every word has to match, and only if nothing does is a single-word match
    /// good enough — so a section answering the whole query is never squeezed out
    /// of the cap by one answering a word of it, and within a group today's file
    /// order stands. A section that matched and was withheld is said rather than
    /// dropped, in the wording the memory half uses; a section that is shown is
    /// shown whole.
    ///
    /// Both sides are matched through ``AgentMemoryIndex/normalize(_:)``, the
    /// same normalisation ``MemoryManager/recallMemory(agentID:query:)`` uses on
    /// the memory half of the same `recall_knowledge` call. Matching raw text
    /// made the trailing `?` in "worktree isolation?" part of the word being
    /// looked for, so a query written the way anyone writes one dropped to the
    /// single-word fallback — or, at one word, answered "No knowledge found
    /// matching" for a section that plainly matched. The normalised copy is only
    /// what is searched: what is handed back is the section verbatim.
    func recall(query: String, agentID: String) -> String {
        guard let content = knowledgeStore.knowledgeContent(for: agentID) else {
            return "No knowledge found for query: \(query)"
        }
        let sections = content.components(separatedBy: "\n\n---\n\n")
        let queryWords = AgentMemoryIndex.normalize(query).split(separator: " ").map(String.init)
        guard !queryWords.isEmpty else { return "No knowledge found matching: \(query)" }

        let haystack = sections.map { ($0, AgentMemoryIndex.normalize($0)) }
        var hits = haystack.filter { _, text in queryWords.allSatisfy { text.contains($0) } }
        if hits.isEmpty {
            hits = haystack.filter { _, text in queryWords.contains { text.contains($0) } }
        }
        guard !hits.isEmpty else { return "No knowledge found matching: \(query)" }

        let shown = hits.prefix(Self.maxRecalledSections)
        var out = shown.map { $0.0 }.joined(separator: "\n\n---\n\n")
        let withheld = hits.count - shown.count
        if withheld > 0 {
            let said = withheld == 1 ? "section matched and is" : "sections matched and are"
            out += "\n\n(\(withheld) further \(said) not shown here — recall again with a narrower query.)"
        }
        return out
    }

    // MARK: - Private

    private func knowledgeDomains(for agent: TrainedAgent) -> [String] {
        agent.knowledgeFiles
            .filter { $0.isDirectory }
            .map { $0.name }
    }

    private func generateManifest(for agent: TrainedAgent) -> String {
        let domains = agent.knowledgeFiles.filter { $0.isDirectory }
        guard !domains.isEmpty else { return "" }

        var lines: [String] = ["# Knowledge Manifest", ""]
        for domain in domains {
            let files = domain.children.filter { !$0.isDirectory }
            let fileNames = files.map { $0.name }
            let summary = extractSummary(from: files, domain: domain.name)
            lines.append("- **\(domain.name)**: \(fileNames.joined(separator: ", "))")
            if !summary.isEmpty {
                lines.append("  \(summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func extractSummary(from files: [TrainedAgent.KnowledgeFile], domain: String) -> String {
        guard let firstFile = files.first,
              let data = try? Data(contentsOf: firstFile.url) else {
            return ""
        }
        let content = String(decoding: data, as: UTF8.self)
        if content.hasPrefix("---") {
            let parts = content.components(separatedBy: "\n---")
            if parts.count >= 2 {
                let frontmatter = parts[0].replacingOccurrences(of: "---", with: "")
                for line in frontmatter.components(separatedBy: "\n") {
                    let kv = line.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "description" {
                        let desc = kv[1].trimmingCharacters(in: .whitespaces)
                        return String(desc.prefix(100))
                    }
                }
            }
        }
        let firstPara = content.components(separatedBy: "\n\n").first ?? ""
        let cleaned = firstPara.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(100))
    }
}
