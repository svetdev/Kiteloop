import Foundation
import KiteloopCore
import CryptoKit

actor AgentCardService {
    private var cache: [CacheKey: AgentCard] = [:]
    private let knowledgeStore: AgentKnowledgeStore

    struct CacheKey: Hashable {
        let agentRef: AgentRef
        let fingerprint: String
    }

    var cacheCount: Int { cache.count }

    init(knowledgeStore: AgentKnowledgeStore) {
        self.knowledgeStore = knowledgeStore
    }

    func generateCard(for agentRef: AgentRef, template: AgentTemplate) -> AgentCard {
        let fingerprint = computeFingerprint(template: template, agentID: agentRef.id)

        let key = CacheKey(agentRef: agentRef, fingerprint: fingerprint)
        if let cached = cache[key] {
            return cached
        }

        let domains = knowledgeDomains(for: agentRef.id)
        let capabilities = extractCapabilities(template: template)

        let card = AgentCard(
            agentRef: agentRef,
            name: template.name,
            description: template.description,
            capabilities: capabilities,
            knowledgeDomains: domains,
            toolsUsed: template.tools,
            inputSchema: nil,
            outputEvents: template.subscriptions,
            model: template.model,
            sourceFingerprint: fingerprint
        )

        cache = cache.filter { !($0.key.agentRef == agentRef && $0.key.fingerprint != fingerprint) }
        cache[key] = card
        return card
    }

    func resolve(agentID: String, projectID: String?, templates: [AgentTemplate]) -> AgentCard? {
        if let projectID {
            let projectRef = AgentRef(id: agentID, scope: .project(id: projectID))
            if let cached = cache.first(where: { $0.key.agentRef == projectRef })?.value {
                return cached
            }
        }
        let globalRef = AgentRef(id: agentID, scope: .global)
        if let cached = cache.first(where: { $0.key.agentRef == globalRef })?.value {
            return cached
        }
        if let template = templates.first(where: { $0.id == agentID }) {
            let ref = AgentRef(id: agentID, scope: projectID.map { .project(id: $0) } ?? .global)
            return generateCard(for: ref, template: template)
        }
        return nil
    }

    func discover(query: String, caller: AgentRef, projectID: String?, limit: Int) -> [DiscoveredAgent] {
        let lowerQuery = query.lowercased()
        let allCards = Array(cache.values)

        let matched = allCards.filter { card in
            if case .project(let cardProject) = card.agentRef.scope {
                if let callerProject = projectID, cardProject != callerProject {
                    return false
                }
                if projectID == nil { return false }
            }
            if card.agentRef == caller { return false }

            let searchable = ([card.name, card.description] + card.capabilities + card.knowledgeDomains + card.toolsUsed)
                .joined(separator: " ").lowercased()
            return searchable.contains(lowerQuery)
        }

        return Array(matched.prefix(limit)).map { card in
            let matchedCaps = card.capabilities.filter { $0.lowercased().contains(lowerQuery) }
            return DiscoveredAgent(
                agentRef: card.agentRef,
                name: card.name,
                description: card.description,
                matchedCapabilities: matchedCaps,
                knowledgeDomains: card.knowledgeDomains,
                canMessage: true
            )
        }
    }

    func invalidate(agentRef: AgentRef) {
        cache = cache.filter { $0.key.agentRef != agentRef }
    }

    func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Private

    private func knowledgeDomains(for agentID: String) -> [String] {
        guard let agent = knowledgeStore.agents.first(where: { $0.id == agentID }) else {
            return []
        }
        return agent.knowledgeFiles.filter { $0.isDirectory }.map { $0.name }
    }

    private func extractCapabilities(template: AgentTemplate) -> [String] {
        var caps: [String] = []
        let descWords = template.description.lowercased()
        let keywords = ["review", "test", "deploy", "triage", "monitor", "build", "design", "research", "debug"]
        for kw in keywords where descWords.contains(kw) {
            caps.append(kw)
        }
        caps.append(contentsOf: template.skills)
        return Array(Set(caps)).sorted()
    }

    private func computeFingerprint(template: AgentTemplate, agentID: String) -> String {
        var input = ""
        input += template.id + template.name + template.model + template.description
        input += template.tools.sorted().joined()
        input += template.skills.sorted().joined()
        if let agent = knowledgeStore.agents.first(where: { $0.id == agentID }) {
            let fileNames = agent.knowledgeFiles.flatMap { flattenNames($0) }.sorted()
            input += fileNames.joined()
        }
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func flattenNames(_ file: TrainedAgent.KnowledgeFile) -> [String] {
        if file.isDirectory {
            return [file.name] + file.children.flatMap { flattenNames($0) }
        }
        return [file.name]
    }
}
