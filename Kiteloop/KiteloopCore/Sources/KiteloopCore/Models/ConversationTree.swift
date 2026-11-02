import Foundation

package struct ConversationBranch: Identifiable, Codable {
    package let id: UUID
    package var name: String
    package let parentMessageID: UUID
    package let createdAt: Date
    package var messages: [Message]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: UUID, name: String, parentMessageID: UUID, createdAt: Date, messages: [Message]) {
        self.id = id
        self.name = name
        self.parentMessageID = parentMessageID
        self.createdAt = createdAt
        self.messages = messages
    }
}

@Observable
package class ConversationTree {
    package private(set) var branches: [ConversationBranch] = []
    package private(set) var activeBranchID: UUID?
    package private(set) var mainMessages: [Message] = []

    package var activeBranch: ConversationBranch? {
        branches.first { $0.id == activeBranchID }
    }

    package func createBranch(name: String, from messageID: UUID, messages: [Message]) -> UUID {
        let branch = ConversationBranch(
            id: UUID(),
            name: name,
            parentMessageID: messageID,
            createdAt: Date(),
            messages: messages
        )
        branches.append(branch)
        return branch.id
    }

    /// Saves `current` — the transcript being left — back into whichever line
    /// was active (a branch via `updateBranchMessages`, or `mainMessages`),
    /// then switches to `branchID` and hands back its stored transcript.
    package func switchToBranch(_ branchID: UUID, leaving current: [Message]) -> [Message]? {
        guard branches.contains(where: { $0.id == branchID }) else { return nil }
        saveOutgoing(current)
        activeBranchID = branchID
        // Read after saving: switching to the active branch just stored `current` into it.
        return branches.first(where: { $0.id == branchID })?.messages
    }

    /// Saves `current` back into whichever line was active, then switches to
    /// main and hands back its stored transcript.
    package func switchToMain(leaving current: [Message]) -> [Message] {
        saveOutgoing(current)
        activeBranchID = nil
        return mainMessages
    }

    /// Removes the branch. If it was the one being stood on, switches back to
    /// main and hands back main's stored transcript; otherwise `nil`.
    @discardableResult
    package func removeBranch(_ branchID: UUID) -> [Message]? {
        let wasActive = activeBranchID == branchID
        branches.removeAll { $0.id == branchID }
        guard wasActive else { return nil }
        activeBranchID = nil
        return mainMessages
    }

    /// The branch called `name` in any letter case, as the main line is found.
    package func branch(named name: String) -> ConversationBranch? {
        branches.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Renames the branch to `newName`, trimmed. Refuses — leaving the tree
    /// as it was — a blank name, a name another branch already has in any
    /// letter case, "main" in any case (the conversation's main line is called
    /// that), and an id that names no branch. A new casing of the branch's own
    /// name is accepted.
    @discardableResult
    package func renameBranch(_ branchID: UUID, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "main",
              let idx = branches.firstIndex(where: { $0.id == branchID }),
              branch(named: name).map({ $0.id == branchID }) ?? true else { return false }
        branches[idx].name = name
        return true
    }

    private func saveOutgoing(_ messages: [Message]) {
        if let activeBranchID {
            updateBranchMessages(activeBranchID, messages: messages)
        } else {
            mainMessages = messages
        }
    }

    package func updateBranchMessages(_ branchID: UUID, messages: [Message]) {
        guard let idx = branches.firstIndex(where: { $0.id == branchID }) else { return }
        branches[idx].messages = messages
    }

    package var branchCount: Int { branches.count }

    package func branchesFrom(messageID: UUID) -> [ConversationBranch] {
        branches.filter { $0.parentMessageID == messageID }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(branches: [ConversationBranch] = [], activeBranchID: UUID? = nil, mainMessages: [Message] = []) {
        self.branches = branches
        self.activeBranchID = activeBranchID
        self.mainMessages = mainMessages
    }
}
