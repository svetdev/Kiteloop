import Foundation
import KiteloopCore

final class DefaultContextEngine: ContextEngine, Sendable {
    private let memoryManager: MemoryManager

    init(memoryManager: MemoryManager) {
        self.memoryManager = memoryManager
    }

    func composeSystemPrompt(for agent: Agent, skillRegistry: SkillRegistry?) async -> String {
        await memoryManager.composeSystemContext(agent: agent, skillRegistry: skillRegistry)
    }

    func resumeStrategy(for agent: Agent, currentSessionID: String?) -> ResumeStrategy {
        guard let sessionID = currentSessionID, !sessionID.isEmpty else {
            return .fresh
        }
        return .resume(sessionID: sessionID)
    }
}
