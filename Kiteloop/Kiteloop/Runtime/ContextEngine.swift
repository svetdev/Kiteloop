import Foundation
import KiteloopCore

protocol ContextEngine: Sendable {
    func composeSystemPrompt(for agent: Agent, skillRegistry: SkillRegistry?) async -> String
    func resumeStrategy(for agent: Agent, currentSessionID: String?) -> ResumeStrategy
}
