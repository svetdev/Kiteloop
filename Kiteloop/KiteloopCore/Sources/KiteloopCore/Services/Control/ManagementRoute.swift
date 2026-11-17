import Foundation

/// The endpoints that set a project's team and settings up, as against the
/// ones that run and steer it: starting and stopping sessions, chats, project
/// settings, backlog edits, memory, knowledge and the app's own settings.
/// One case of `ControlRoute` carries them all, so the families that switch
/// over every route gain one arm, not thirty.
package enum ManagementRoute: Equatable, Sendable {
    // An agent's session and its chats
    case startAgent
    case stopAgent
    case restartAgent
    case listAgentChats
    case newAgentChat
    case openAgentChat
    case deleteAgentChat

    // Projects
    case closeProject
    case getProjectSettings
    case setProjectSettings
    case exportProjectSetup

    // Backlog items
    case updateBacklogItem
    case deleteBacklogItem

    // Kiteloop's own per-agent memory, and the project's shared context
    case getAgentMemory
    case addMemoryFact
    case rewriteMemoryFact
    case archiveMemoryFact
    case getSharedMemory
    case setSharedMemory

    // The notes the Claude CLI keeps for the project
    case listClaudeMemory
    case putClaudeMemoryNote
    case deleteClaudeMemoryNote

    // Knowledge packages
    case listKnowledge
    case getKnowledgeFile
    case putKnowledgeFile

    // The app
    case listMCPServers
    case putMCPServer(name: String)
    case deleteMCPServer(name: String)
    case getSettings
    case setSettings

    /// The scope a scoped token needs: reads are `read`, a session's start,
    /// stop and chats are `operate`, and every edit is `configure`.
    package var scope: ControlScope {
        switch self {
        case .listAgentChats, .getProjectSettings, .exportProjectSetup, .getAgentMemory, .getSharedMemory,
             .listClaudeMemory, .listKnowledge, .getKnowledgeFile, .listMCPServers, .getSettings:
            return .read
        case .startAgent, .stopAgent, .restartAgent, .newAgentChat, .openAgentChat:
            return .operate
        case .deleteAgentChat, .closeProject, .setProjectSettings, .updateBacklogItem, .deleteBacklogItem,
             .addMemoryFact, .rewriteMemoryFact, .archiveMemoryFact, .setSharedMemory,
             .putClaudeMemoryNote, .deleteClaudeMemoryNote, .putKnowledgeFile,
             .putMCPServer, .deleteMCPServer, .setSettings:
            return .configure
        }
    }

    /// Whether the call changes what agents are allowed to do or what Kiteloop
    /// does unattended (`ControlRoute.changesConfiguration`): a project's
    /// settings, an MCP server, the app's settings. A backlog item, memory,
    /// knowledge, a chat and closing a project are everyday work. Exhaustive
    /// with no `default:`.
    package var changesConfiguration: Bool {
        switch self {
        case .setProjectSettings, .putMCPServer, .deleteMCPServer, .setSettings:
            return true
        case .listAgentChats, .getProjectSettings, .exportProjectSetup, .getAgentMemory, .getSharedMemory,
             .listClaudeMemory, .listKnowledge, .getKnowledgeFile, .listMCPServers, .getSettings,
             .startAgent, .stopAgent, .restartAgent, .newAgentChat, .openAgentChat,
             .deleteAgentChat, .closeProject, .updateBacklogItem, .deleteBacklogItem,
             .addMemoryFact, .rewriteMemoryFact, .archiveMemoryFact, .setSharedMemory,
             .putClaudeMemoryNote, .deleteClaudeMemoryNote, .putKnowledgeFile:
            return false
        }
    }
}

/// What each `ManagementRoute` accepts and returns. One function per route,
/// reached through its area, as the rest of the spec is.
extension ControlAPISpec {
    static func managementDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .startAgent, .stopAgent, .restartAgent,
             .listAgentChats, .newAgentChat, .openAgentChat, .deleteAgentChat:
            return agentSessionDetail(for: route)
        case .closeProject, .getProjectSettings, .setProjectSettings, .exportProjectSetup,
             .updateBacklogItem, .deleteBacklogItem:
            return projectSetupDetail(for: route)
        case .getAgentMemory, .addMemoryFact, .rewriteMemoryFact, .archiveMemoryFact,
             .getSharedMemory, .setSharedMemory:
            return agentMemoryDetail(for: route)
        case .listClaudeMemory, .putClaudeMemoryNote, .deleteClaudeMemoryNote,
             .listKnowledge, .getKnowledgeFile, .putKnowledgeFile:
            return notesDetail(for: route)
        case .listMCPServers, .putMCPServer, .deleteMCPServer, .getSettings, .setSettings:
            return appDetail(for: route)
        }
    }

    // MARK: - Shared pieces

    private static var notOpen: Status { errorStatus(409, "Project not open in Kiteloop.") }
    private static var noAgent: Status { errorStatus(404, "No such agent in this project.") }

    private static func agentQuery() -> [QueryParameter] {
        [projectQuery(required: true),
         QueryParameter(name: "agent", required: true, schema: string, description: "Agent id or name.")]
    }

    private static func ok(_ description: String, _ properties: [String: Any], required: [String]) -> Status {
        Status(code: 200, description: description, schema: object(properties, required: required))
    }

    private static var chat: [String: Any] {
        object([
            "id": string, "title": string,
            "messages": described(integer, "How many messages the chat holds."),
            "lastMessageAt": described(string, "ISO 8601."),
            "current": described(bool, "The chat the agent's session is in now.")
        ], required: ["id", "title", "messages", "lastMessageAt", "current"])
    }

    // MARK: - An agent's session and chats

    private static func agentSessionDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .startAgent: return startAgentDetail()
        case .stopAgent: return stopAgentDetail()
        case .restartAgent: return restartAgentDetail()
        case .listAgentChats: return listAgentChatsDetail()
        case .newAgentChat: return newAgentChatDetail()
        case .openAgentChat: return openAgentChatDetail()
        default: return deleteAgentChatDetail()
        }
    }

    private static func startAgentDetail() -> Detail {
        Detail(
            id: "startAgent",
            summary: "Start an agent's session",
            description: "An agent has no session until something starts one; a message does it too. A running agent is left alone.",
            requestBody: agentTargetBody([:], required: []),
            responses: [
                ok("Running.", ["agent": string, "running": bool,
                                "started": described(bool, "False when it was running already.")],
                   required: ["agent", "running", "started"]),
                errorStatus(400, "Missing \"project\" or \"agent\"."), noAgent, notOpen,
                errorStatus(500, "The session could not be started; the error says why.")
            ]
        )
    }

    private static func stopAgentDetail() -> Detail {
        Detail(
            id: "stopAgent",
            summary: "Stop an agent's session",
            description: """
            What Stop Agent does in the sidebar: the process ends, a turn in flight with it, \
            and the chat stays. Refused while an autopilot run is using the agent.
            """,
            requestBody: agentTargetBody([:], required: []),
            responses: [
                ok("Stopped.", ["agent": string, "running": bool,
                                "stopped": described(bool, "False when nothing was running.")],
                   required: ["agent", "running", "stopped"]),
                errorStatus(400, "Missing \"project\" or \"agent\"."), noAgent,
                errorStatus(409, "Project not open in Kiteloop, or an autopilot run is using the agent.")
            ]
        )
    }

    private static func restartAgentDetail() -> Detail {
        Detail(
            id: "restartAgent",
            summary: "Stop an agent's session and start it again",
            description: """
            So values read when the process starts take effect. Refused mid-turn — \
            stop the turn first — and while an autopilot run is using the agent.
            """,
            requestBody: agentTargetBody([:], required: []),
            responses: [
                ok("Running again.", ["agent": string, "running": bool], required: ["agent", "running"]),
                errorStatus(400, "Missing \"project\" or \"agent\"."), noAgent,
                errorStatus(409, "Project not open, the agent is mid-turn, or an autopilot run is using it."),
                errorStatus(500, "The session could not be started; the error says why.")
            ]
        )
    }

    private static func listAgentChatsDetail() -> Detail {
        Detail(
            id: "listAgentChats",
            summary: "An agent's chats, newest first",
            query: agentQuery(),
            responses: [
                ok("The agent's chats.", ["agent": string, "chats": array(of: chat)], required: ["agent", "chats"]),
                errorStatus(400, "Missing ?project= or ?agent=."), noAgent, notOpen
            ]
        )
    }

    private static func newAgentChatDetail() -> Detail {
        Detail(
            id: "newAgentChat",
            summary: "Start a new chat with an agent",
            description: "What New Chat does: the open chat is saved and the agent starts a fresh conversation. Refused mid-turn.",
            requestBody: agentTargetBody([:], required: []),
            responses: [
                Status(code: 201, description: "The new chat, now the agent's current one.",
                       schema: object(["agent": string, "chat": chat], required: ["agent", "chat"])),
                errorStatus(400, "Missing \"project\" or \"agent\"."), noAgent,
                errorStatus(409, "Project not open in Kiteloop, or the agent is mid-turn.")
            ]
        )
    }

    private static func openAgentChatDetail() -> Detail {
        Detail(
            id: "openAgentChat",
            summary: "Switch an agent to one of its earlier chats",
            description: "The agent's next message continues that conversation. Refused mid-turn.",
            requestBody: agentTargetBody(["chat": described(string, "The chat's id.")], required: ["chat"]),
            responses: [
                ok("That chat is the agent's current one.", ["agent": string, "chat": chat], required: ["agent", "chat"]),
                errorStatus(400, "A missing field."),
                errorStatus(404, "No such agent, or no such chat of this agent's."),
                errorStatus(409, "Project not open in Kiteloop, or the agent is mid-turn.")
            ]
        )
    }

    private static func deleteAgentChatDetail() -> Detail {
        Detail(
            id: "deleteAgentChat",
            summary: "Delete one of an agent's chats and its messages",
            description: "Deleting the current chat opens the next one, or a fresh chat when none is left — refused mid-turn.",
            query: agentQuery() + [QueryParameter(name: "chat", required: true, schema: string, description: "The chat's id.")],
            responses: [
                ok("Deleted.", ["agent": string, "deleted": string], required: ["agent", "deleted"]),
                errorStatus(400, "A missing query parameter."),
                errorStatus(404, "No such agent, or no such chat of this agent's."),
                errorStatus(409, "Project not open in Kiteloop, or it is the current chat and the agent is mid-turn.")
            ]
        )
    }

    // MARK: - Projects and backlog items

    private static func projectSetupDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .closeProject: return closeProjectDetail()
        case .getProjectSettings: return getProjectSettingsDetail()
        case .setProjectSettings: return setProjectSettingsDetail()
        case .exportProjectSetup: return exportProjectSetupDetail()
        case .updateBacklogItem: return updateBacklogItemDetail()
        default: return deleteBacklogItemDetail()
        }
    }

    private static var companion: [String: Any] {
        object(["name": string, "path": string, "base": described(string, "Base branch; the repository's current one when absent.")],
               required: ["name", "path"])
    }

    private static var projectSettings: [String: Any] {
        [
            "model": described(nullable(string), "The model new agents here start with; null follows the app's."),
            "permissionMode": described(string, "The mode new agents here start in."),
            "effort": described(nullable(string), "low, medium, high, xhigh or max; null follows the app's."),
            "maxBudgetUSD": described(nullable(number), "What one agent session may spend; null for no ceiling."),
            "budget": described(nullable(ownedBudget("every source in the project")), "The project's own ceiling for a day or a month, over chat, routines, autopilot and the Planner alike. At the ceiling, routine and trigger firings and autonomous autopilot runs in the project are refused. Beside the autopilot's daily budgetUSD (PUT /v1/autopilot), not instead of it: both apply. null for none."),
            "goal": described(nullable(string), "The project's stated goal, shown to the Planner."),
            "space": described(nullable(enumOf(ProjectSpace.names)), "The space the project is labelled as belonging to; null for unassigned. A label only — it isolates nothing."),
            "companions": described(array(of: companion), "The other repositories an item may change with this one.")
        ]
    }

    private static func closeProjectDetail() -> Detail {
        Detail(
            id: "closeProject",
            summary: "Close an open project",
            description: "What closing its tab does: its agents stop and it leaves the window. Refused while its autopilot has a run in flight.",
            requestBody: object(["project": described(string, "Project identifier.")], required: ["project"]),
            responses: [
                ok("Closed.", ["closed": described(string, "The project's id.")], required: ["closed"]),
                errorStatus(400, "Missing \"project\"."),
                errorStatus(409, "Project not open in Kiteloop, or its autopilot has a run in flight."),
                errorStatus(503, "The app window isn't running.")
            ]
        )
    }

    private static func getProjectSettingsDetail() -> Detail {
        Detail(
            id: "getProjectSettings",
            summary: "Read a project's settings",
            query: [projectQuery(required: true)],
            responses: [
                ok("The project's settings.", projectSettings, required: ["permissionMode", "companions"]),
                errorStatus(400, "Missing ?project=."), notOpen
            ]
        )
    }

    private static func setProjectSettingsDetail() -> Detail {
        var body = projectSettings
        body["project"] = described(string, "Project identifier.")
        return Detail(
            id: "setProjectSettings",
            summary: "Change a project's settings",
            description: "The fields named are replaced, the rest stay; null clears one that can be empty. Agents already hired keep their own values.",
            requestBody: object(body, required: ["project"]),
            responses: [
                ok("The settings as they now stand.", projectSettings, required: ["permissionMode", "companions"]),
                errorStatus(400, "A missing or mistyped field, an unknown mode, effort or space, or nothing to change."), notOpen,
                errorStatus(500, "The project's settings file could not be written.")
            ]
        )
    }

    private static func exportProjectSetupDetail() -> Detail {
        Detail(
            id: "exportProjectSetup",
            summary: "Export a project's whole setup as one file",
            description: "Its team as package refs, its routines (every one disarmed), its settings, its pinned document and the names of the connectors its agents need. No secret is in it: no Bedrock, telemetry, build environment or connector configuration.",
            query: [projectQuery(required: true)],
            responses: [
                ok("The setup file.", [
                    "format": described(integer, "The file's version; 1."),
                    "team": described(nullable(object(["agents": array(of: object([:], required: []))], required: ["agents"])),
                                      "The team as package refs; null when there is none in that shape."),
                    "teamShape": described(string, "\"templates\" when the team is stored as templates, which the file does not carry."),
                    "routines": described(array(of: object([:], required: [])), "The project's routines, each with armed false."),
                    "settings": object([
                        "model": nullable(string), "permissionMode": string, "effort": nullable(string),
                        "maxBudgetUSD": nullable(number), "goal": nullable(string), "companions": array(of: object([:], required: []))
                    ], required: ["permissionMode", "companions"]),
                    "pinnedDocument": nullable(string),
                    "connectors": described(array(of: string), "The MCP servers the agents name, sorted, by name only.")
                ], required: ["format", "team", "routines", "settings", "pinnedDocument", "connectors"]),
                errorStatus(400, "Missing ?project=."), notOpen
            ]
        )
    }

    private static func updateBacklogItemDetail() -> Detail {
        Detail(
            id: "updateBacklogItem",
            summary: "Change a backlog item",
            description: "Its title, its `verify:`, its size, and the text of its detail file. Refused while a run is working on it.",
            requestBody: object([
                "project": described(string, "Project identifier."),
                "item": described(string, "The item's id."),
                "title": string,
                "verify": string,
                "size": described(string, "XS, S, M, L or XL."),
                "detail": described(string, "The whole detail file, as Markdown.")
            ], required: ["project", "item"]),
            responses: [
                ok("Changed.", ["item": string, "title": string, "changed": described(array(of: string), "The fields that were written.")],
                   required: ["item", "title", "changed"]),
                errorStatus(400, "A missing or mistyped field, an empty title or verify, an unknown size, or nothing to change."),
                errorStatus(404, "No such item."),
                errorStatus(409, "Project not open in Kiteloop, or a run is working on the item.")
            ]
        )
    }

    private static func deleteBacklogItemDetail() -> Detail {
        Detail(
            id: "deleteBacklogItem",
            summary: "Remove a backlog item",
            description: "Its line leaves the backlog; its detail file and run history stay on disk. Refused while a run is working on it.",
            query: [projectQuery(required: true),
                    QueryParameter(name: "item", required: true, schema: string, description: "The item's id.")],
            responses: [
                ok("Removed.", ["removed": string], required: ["removed"]),
                errorStatus(400, "Missing ?project= or ?item=."),
                errorStatus(404, "No such item."),
                errorStatus(409, "Project not open in Kiteloop, or a run is working on the item.")
            ]
        )
    }

    // MARK: - Kiteloop's per-agent memory

    private static func agentMemoryDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .getAgentMemory: return getAgentMemoryDetail()
        case .addMemoryFact: return addMemoryFactDetail()
        case .rewriteMemoryFact: return rewriteMemoryFactDetail()
        case .archiveMemoryFact: return archiveMemoryFactDetail()
        case .getSharedMemory: return getSharedMemoryDetail()
        default: return setSharedMemoryDetail()
        }
    }

    private static var fact: [String: Any] {
        object(["topic": string, "body": string], required: ["topic", "body"])
    }

    private static var memoryRefused: Status { errorStatus(500, "The write did not land; the error says why — the index is capped.") }

    private static func getAgentMemoryDetail() -> Detail {
        Detail(
            id: "getAgentMemory",
            summary: "What Kiteloop remembers for an agent",
            description: "The index the agent is shown every session, the facts behind it and the archived ones.",
            query: agentQuery(),
            responses: [
                ok("The agent's memory.", ["agent": string, "index": string, "facts": array(of: fact), "archived": array(of: fact)],
                   required: ["agent", "index", "facts", "archived"]),
                errorStatus(400, "Missing ?project= or ?agent=."), noAgent, notOpen
            ]
        )
    }

    private static func addMemoryFactDetail() -> Detail {
        Detail(
            id: "addMemoryFact",
            summary: "Add a fact to an agent's memory",
            description: "Written at once, as Add does on the Memory tab — no proposal to approve.",
            requestBody: agentTargetBody(["content": described(string, "The fact. Not blank.")], required: ["content"]),
            responses: [
                Status(code: 201, description: "Remembered.",
                       schema: object(["agent": string, "facts": array(of: fact)], required: ["agent", "facts"])),
                errorStatus(400, "A missing field or blank content."), noAgent, notOpen, memoryRefused
            ]
        )
    }

    private static func rewriteMemoryFactDetail() -> Detail {
        Detail(
            id: "rewriteMemoryFact",
            summary: "Replace one fact's text",
            requestBody: agentTargetBody([
                "topic": described(string, "The fact's topic, as the read lists it."),
                "content": described(string, "The new text. Not blank.")
            ], required: ["topic", "content"]),
            responses: [
                ok("Rewritten.", ["agent": string, "topic": string], required: ["agent", "topic"]),
                errorStatus(400, "A missing field or blank content."),
                errorStatus(404, "No such agent, or no such fact."), notOpen, memoryRefused
            ]
        )
    }

    private static func archiveMemoryFactDetail() -> Detail {
        Detail(
            id: "archiveMemoryFact",
            summary: "Archive one fact",
            description: "It leaves the index the agent is shown and stays on disk, restorable on the Memory tab.",
            query: agentQuery() + [QueryParameter(name: "topic", required: true, schema: string, description: "The fact's topic.")],
            responses: [
                ok("Archived.", ["agent": string, "archived": string], required: ["agent", "archived"]),
                errorStatus(400, "A missing query parameter."),
                errorStatus(404, "No such agent, or no such fact."), notOpen, memoryRefused
            ]
        )
    }

    private static func getSharedMemoryDetail() -> Detail {
        Detail(
            id: "getSharedMemory",
            summary: "The project's shared context",
            description: "The text every agent in the project is shown — Project Context on the Memory tab.",
            query: [projectQuery(required: true)],
            responses: [
                ok("The shared context.", ["content": string], required: ["content"]),
                errorStatus(400, "Missing ?project=."), notOpen
            ]
        )
    }

    private static func setSharedMemoryDetail() -> Detail {
        Detail(
            id: "setSharedMemory",
            summary: "Replace the project's shared context",
            requestBody: object(["project": described(string, "Project identifier."), "content": string],
                                required: ["project", "content"]),
            responses: [
                ok("Written.", ["content": string], required: ["content"]),
                errorStatus(400, "A missing field."), notOpen,
                errorStatus(500, "The file could not be written.")
            ]
        )
    }

    // MARK: - Claude's notes and knowledge packages

    private static func notesDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .listClaudeMemory: return listClaudeMemoryDetail()
        case .putClaudeMemoryNote: return putClaudeMemoryNoteDetail()
        case .deleteClaudeMemoryNote: return deleteClaudeMemoryNoteDetail()
        case .listKnowledge: return listKnowledgeDetail()
        case .getKnowledgeFile: return getKnowledgeFileDetail()
        default: return putKnowledgeFileDetail()
        }
    }

    private static var claudeNote: [String: Any] {
        object([
            "id": described(string, "The file's name without .md; MEMORY is the index."),
            "name": string,
            "summary": string,
            "kind": described(string, "user, feedback, project or reference, when the note says."),
            "text": described(string, "The whole file, front matter included.")
        ], required: ["id", "name", "text"])
    }

    private static func listClaudeMemoryDetail() -> Detail {
        Detail(
            id: "listClaudeMemory",
            summary: "The notes the Claude CLI keeps for a project",
            description: "What chat agents wrote when told to remember something: the index first, then each note.",
            query: [projectQuery(required: true)],
            responses: [
                ok("The notes.", ["directory": string, "notes": array(of: claudeNote)], required: ["directory", "notes"]),
                errorStatus(400, "Missing ?project=."), notOpen
            ]
        )
    }

    private static func putClaudeMemoryNoteDetail() -> Detail {
        Detail(
            id: "putClaudeMemoryNote",
            summary: "Write one of Claude's notes",
            description: "Replaces the note's file, or makes it. A new note is not added to the index: write MEMORY too.",
            requestBody: object([
                "project": described(string, "Project identifier."),
                "note": described(string, "The note's id: letters, digits, - and _."),
                "text": described(string, "The whole file.")
            ], required: ["project", "note", "text"]),
            responses: [
                ok("Written.", ["note": string], required: ["note"]),
                errorStatus(400, "A missing field, or a note id that is not a plain file name."), notOpen,
                errorStatus(500, "The file could not be written.")
            ]
        )
    }

    private static func deleteClaudeMemoryNoteDetail() -> Detail {
        Detail(
            id: "deleteClaudeMemoryNote",
            summary: "Delete one of Claude's notes",
            description: "The file goes, and the index lines that point at it. The index itself is not deleted.",
            query: [projectQuery(required: true),
                    QueryParameter(name: "note", required: true, schema: string, description: "The note's id.")],
            responses: [
                ok("Deleted.", ["deleted": string], required: ["deleted"]),
                errorStatus(400, "A missing query parameter, or the index."),
                errorStatus(404, "No such note."), notOpen
            ]
        )
    }

    private static func listKnowledgeDetail() -> Detail {
        let package = object([
            "id": string, "name": string, "description": string,
            "files": described(array(of: string), "Each file's path inside the package.")
        ], required: ["id", "name", "files"])
        return Detail(
            id: "listKnowledge",
            summary: "The project's knowledge packages",
            description: "Each trained agent under the project's knowledge folder, and the files it carries.",
            query: [projectQuery(required: true)],
            responses: [
                ok("The packages.", ["packages": array(of: package)], required: ["packages"]),
                errorStatus(400, "Missing ?project=."), notOpen
            ]
        )
    }

    private static func knowledgeQuery() -> [QueryParameter] {
        [projectQuery(required: true),
         QueryParameter(name: "package", required: true, schema: string, description: "The package's id."),
         QueryParameter(name: "path", required: true, schema: string, description: "The file's path inside the package.")]
    }

    private static func getKnowledgeFileDetail() -> Detail {
        Detail(
            id: "getKnowledgeFile",
            summary: "Read one file of a knowledge package",
            query: knowledgeQuery(),
            responses: [
                ok("The file.", ["package": string, "path": string, "content": string], required: ["package", "path", "content"]),
                errorStatus(400, "A missing query parameter, or a path that leaves the package."),
                errorStatus(404, "No such package or file."), notOpen
            ]
        )
    }

    private static func putKnowledgeFileDetail() -> Detail {
        Detail(
            id: "putKnowledgeFile",
            summary: "Write one file of a knowledge package",
            description: "Replaces the file, or makes it — folders on the way included. The package itself must exist.",
            requestBody: object([
                "project": described(string, "Project identifier."),
                "package": described(string, "The package's id."),
                "path": described(string, "The file's path inside the package."),
                "content": string
            ], required: ["project", "package", "path", "content"]),
            responses: [
                ok("Written.", ["package": string, "path": string], required: ["package", "path"]),
                errorStatus(400, "A missing field, or a path that leaves the package."),
                errorStatus(404, "No such package."), notOpen,
                errorStatus(500, "The file could not be written.")
            ]
        )
    }

    // MARK: - The app

    private static func appDetail(for route: ManagementRoute) -> Detail {
        switch route {
        case .listMCPServers: return listMCPServersDetail()
        case .putMCPServer: return putMCPServerDetail()
        case .deleteMCPServer: return deleteMCPServerDetail()
        case .getSettings: return getSettingsDetail()
        default: return setSettingsDetail()
        }
    }

    private static var noSettings: Status { errorStatus(503, "This Kiteloop has no settings store attached.") }

    private static var mcpServer: [String: Any] {
        object([
            "name": string,
            "summary": described(string, "Its command line, or its transport and endpoint."),
            "command": string,
            "args": array(of: string),
            "env": described(array(of: string), "The names of the variables it is given — never their values.")
        ], required: ["name", "summary", "env"])
    }

    private static func listMCPServersDetail() -> Detail {
        Detail(
            id: "listMCPServers",
            summary: "The MCP servers the app has configured",
            description: "What an agent's `mcpServers` names. Environment values are not returned: they hold credentials.",
            responses: [ok("The servers, by name.", ["servers": array(of: mcpServer)], required: ["servers"]), noSettings]
        )
    }

    private static func putMCPServerDetail() -> Detail {
        Detail(
            id: "putMCPServer",
            summary: "Add an MCP server, or replace the one with this name",
            description: """
            The body is the server's entry as Claude Code's own MCP configuration spells it: \
            `command`, `args` and `env` for one run as a process, or `type` and `url` for a remote one. \
            Running sessions are told at once.
            """,
            requestBody: object([
                "command": string, "args": array(of: string),
                "env": described(object([:], required: []), "Variable names to values."),
                "type": string, "url": string
            ], required: []),
            responses: [
                ok("Configured.", ["server": mcpServer], required: ["server"]),
                errorStatus(400, "A body that is not an object, is empty, or has a mistyped field."), noSettings
            ]
        )
    }

    private static func deleteMCPServerDetail() -> Detail {
        Detail(
            id: "deleteMCPServer",
            summary: "Remove an MCP server",
            description: "Agents that name it keep the name and are given nothing for it.",
            responses: [
                ok("Removed.", ["removed": string], required: ["removed"]),
                errorStatus(404, "No server with this name."), noSettings
            ]
        )
    }

    private static var appSettings: [String: Any] {
        [
            "defaultModel": described(nullable(string), "The model new agents start with when their project names none."),
            "defaultEffort": described(nullable(string), "low, medium, high, xhigh or max."),
            "soundTheme": described(string, "soft (Kiteloop's own sounds), system or silent."),
            "automaticUpdateChecks": described(bool, "Whether the app looks for a new version by itself.")
        ]
    }

    private static func getSettingsDetail() -> Detail {
        Detail(
            id: "getSettings",
            summary: "Read the app's settings",
            responses: [ok("The settings.", appSettings, required: ["soundTheme", "automaticUpdateChecks"]), noSettings]
        )
    }

    private static func setSettingsDetail() -> Detail {
        Detail(
            id: "setSettings",
            summary: "Change the app's settings",
            description: "The fields named are replaced, the rest stay; null clears a default.",
            requestBody: object(appSettings, required: []),
            responses: [
                ok("The settings as they now stand.", appSettings, required: ["soundTheme", "automaticUpdateChecks"]),
                errorStatus(400, "A mistyped field, an unknown effort or sound theme, or nothing to change."), noSettings
            ]
        )
    }
}
