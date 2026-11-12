import XCTest
import KiteloopCore
@testable import Kiteloop

final class ClaudeCodeCLIRuntimeScopeTests: XCTestCase {

    // MARK: - Spawn environment

    /// An unattended session — an autopilot worker or reviewer, or a one-shot
    /// headless call — is spawned with Claude Code's own memory turned off, so
    /// the pair cannot compound beliefs through a directory Kiteloop never
    /// shows, curates or gates.
    func testUnattendedSessionDisablesClaudeCodeAutoMemory() {
        let env = ClaudeCodeCLIRuntime.sessionEnvironment(["PATH": "/usr/bin"], unattended: true)
        XCTAssertEqual(env[ClaudeCodeCLIRuntime.disableAutoMemoryVariable], "1")
        XCTAssertEqual(env["PATH"], "/usr/bin", "The rest of the environment is passed through")
    }

    /// A session a human is chatting with is handed the environment back
    /// untouched — not merely without the flag set to `1`, but with no trace of
    /// this decision in it at all.
    func testInteractiveSessionEnvironmentIsUnchanged() {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-test"]
        let env = ClaudeCodeCLIRuntime.sessionEnvironment(base, unattended: false)
        XCTAssertEqual(env, base, "A chat agent's environment must come back exactly as it went in")
        XCTAssertNil(env[ClaudeCodeCLIRuntime.disableAutoMemoryVariable])
    }

    /// The variable the CLI actually reads. Spelled out here because a typo
    /// would leave the flag set, the tests green, and auto-memory running.
    func testDisableAutoMemoryVariableName() {
        XCTAssertEqual(ClaudeCodeCLIRuntime.disableAutoMemoryVariable, "CLAUDE_CODE_DISABLE_AUTO_MEMORY")
    }

    // MARK: - Thinking

    private func thinkingAgent(enabled: Bool, budget: Int?) -> Agent {
        var agent = Agent(id: "thinker", name: "Thinker", model: "sonnet", systemPrompt: "",
                          tools: [], denied: [], permissionMode: "default", state: .idle)
        agent.thinkingEnabled = enabled
        agent.thinkingBudget = budget
        return agent
    }

    /// Thinking off: no `--thinking` argument and no budget variable.
    func testThinkingOffAddsNoArgumentAndNoBudget() {
        let agent = thinkingAgent(enabled: false, budget: 8000)
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingArguments(for: agent), [])
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingEnvironment(for: agent), [:])
    }

    /// Thinking on: `--thinking` is followed by its mode, `enabled` — a bare
    /// flag makes the CLI take the next argument as the mode and exit.
    func testThinkingOnPassesTheEnabledMode() {
        let args = ClaudeCodeCLIRuntime.thinkingArguments(for: thinkingAgent(enabled: true, budget: nil))
        XCTAssertEqual(args, ["--thinking", "enabled"])
        XCTAssertFalse(args.contains("--thinking-budget"))
    }

    /// A budget travels in `MAX_THINKING_TOKENS`, never as `--thinking-budget`,
    /// which the CLI does not accept.
    func testThinkingBudgetGoesInTheEnvironment() {
        let agent = thinkingAgent(enabled: true, budget: 8000)
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingArguments(for: agent), ["--thinking", "enabled"])
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingEnvironment(for: agent), ["MAX_THINKING_TOKENS": "8000"])
    }

    /// A nil or zero budget leaves the variable unset.
    func testNilOrZeroThinkingBudgetLeavesTheVariableUnset() {
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingEnvironment(for: thinkingAgent(enabled: true, budget: nil)), [:])
        XCTAssertEqual(ClaudeCodeCLIRuntime.thinkingEnvironment(for: thinkingAgent(enabled: true, budget: 0)), [:])
    }

    // MARK: - Operator tools grant

    /// An agent without the "Operator tools" grant — the default — gets no
    /// trace of the credential in its environment.
    func testNoOperatorGrantMeansNeitherVariableIsSet() {
        let env = ClaudeCodeCLIRuntime.sessionEnvironment(["PATH": "/usr/bin"], unattended: false)
        XCTAssertNil(env[ClaudeCodeCLIRuntime.operatorTokenVariable])
        XCTAssertNil(env[ClaudeCodeCLIRuntime.controlURLVariable])
    }

    /// With the grant, both variables carry exactly what the grant says — and
    /// the rest of the environment, including the unattended flag, is
    /// unaffected: the grant is independent of session kind.
    func testOperatorGrantSetsBothVariables() {
        let grant = ClaudeCodeCLIRuntime.OperatorToolsGrant(
            token: "op-token-123",
            controlURL: "http://127.0.0.1:4517/v1"
        )
        let env = ClaudeCodeCLIRuntime.sessionEnvironment(["PATH": "/usr/bin"], unattended: true, operatorTools: grant)

        XCTAssertEqual(env[ClaudeCodeCLIRuntime.operatorTokenVariable], "op-token-123")
        XCTAssertEqual(env[ClaudeCodeCLIRuntime.controlURLVariable], "http://127.0.0.1:4517/v1")
        XCTAssertEqual(env[ClaudeCodeCLIRuntime.disableAutoMemoryVariable], "1")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    /// A chat session (not unattended) with the grant on still carries the
    /// operator variables — the grant is per agent, not per session kind.
    func testOperatorGrantAppliesToInteractiveSessionsToo() {
        let grant = ClaudeCodeCLIRuntime.OperatorToolsGrant(token: "t", controlURL: "http://127.0.0.1:4517/v1")
        let env = ClaudeCodeCLIRuntime.sessionEnvironment(["PATH": "/usr/bin"], unattended: false, operatorTools: grant)

        XCTAssertEqual(env[ClaudeCodeCLIRuntime.operatorTokenVariable], "t")
        XCTAssertNil(env[ClaudeCodeCLIRuntime.disableAutoMemoryVariable], "interactive sessions still keep their own memory")
    }

    /// The variable names a bundled agent is told to read — spelled out here
    /// because a typo would leave the knowledge note pointing at a variable
    /// nothing ever sets.
    func testOperatorVariableNames() {
        XCTAssertEqual(ClaudeCodeCLIRuntime.operatorTokenVariable, "KITELOOP_OPERATOR_TOKEN")
        XCTAssertEqual(ClaudeCodeCLIRuntime.controlURLVariable, "KITELOOP_CONTROL_URL")
    }

    // MARK: - Tool scope

    // MARK: - Permission arguments

    /// An unattended spawn — an autopilot run's worker or reviewer, or a
    /// one-shot helper — runs in Claude Code's auto mode whatever the agent's
    /// own mode, refuses anything that would prompt, and carries only the
    /// agent's own denials: the classifier decides the rest.
    func testAnUnattendedSpawnRunsInAutoModeWithOnlyTheAgentsDenials() {
        let agent = Agent(id: "worker", name: "Worker", model: "sonnet", systemPrompt: "",
                          tools: [], denied: ["WebSearch"],
                          permissionMode: "acceptEdits", state: .idle)

        XCTAssertEqual(ClaudeCodeCLIRuntime.permissionArguments(agent: agent, unattended: true),
                       ["--permission-mode", "auto", "--permission-prompts", "none",
                        "--disallowedTools", "WebSearch"])
        var undenied = agent
        undenied.denied = []
        XCTAssertEqual(ClaudeCodeCLIRuntime.permissionArguments(agent: undenied, unattended: true),
                       ["--permission-mode", "auto", "--permission-prompts", "none"],
                       "no deny list of the app's own is added")
    }

    /// A chat agent is spawned with its configured mode and its own denials,
    /// and asks Kiteloop — over its own stdin and stdout — whatever a
    /// terminal would ask its person.
    func testAnAttendedSpawnKeepsTheAgentsModeAndDenialsAndAsksItsHost() {
        let agent = Agent(id: "chat", name: "Chat", model: "sonnet", systemPrompt: "",
                          tools: [], denied: [],
                          permissionMode: "default", state: .idle)

        XCTAssertEqual(ClaudeCodeCLIRuntime.permissionArguments(agent: agent, unattended: false),
                       ["--permission-mode", "default", "--permission-prompts", "host",
                        "--permission-prompt-tool", "stdio"])
        var withDenials = agent
        withDenials.denied = ["WebSearch"]
        XCTAssertEqual(ClaudeCodeCLIRuntime.permissionArguments(agent: withDenials, unattended: false),
                       ["--permission-mode", "default", "--permission-prompts", "host",
                        "--permission-prompt-tool", "stdio", "--disallowedTools", "WebSearch"])
    }

    func testBuildProfileScopeFromAgent() {
        let agent = Agent(
            name: "tester",
            model: "sonnet",
            systemPrompt: "",
            tools: ["Bash", "Edit", "Write", "Read"],
            denied: ["Read"],
            permissionMode: "default"
        )
        let profile = ClaudeCodeCLIRuntime.buildProfileScope(from: agent)
        XCTAssertEqual(profile.allowed, ["Bash", "Edit", "Write", "Read"])
        XCTAssertEqual(profile.denied, ["Read"])
        XCTAssertEqual(profile.policyVersion, "v1")
    }

    func testBuildProfileScopeIncludesBaseTools() {
        let agent = Agent(
            name: "minimal",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default"
        )
        let profile = ClaudeCodeCLIRuntime.buildProfileScope(from: agent)
        XCTAssertTrue(profile.allowed.contains("Bash"))
        XCTAssertTrue(profile.allowed.contains("Edit"))
        XCTAssertTrue(profile.allowed.contains("Write"))
    }

    func testNarrowToolsListExcludesNetworkAndSpawningTools() {
        let agent = Agent(
            name: "narrow",
            model: "sonnet",
            systemPrompt: "",
            tools: ["Read", "Glob", "Grep"],
            denied: [],
            permissionMode: "default"
        )
        let profile = ClaudeCodeCLIRuntime.buildProfileScope(from: agent)
        for tool in ["WebFetch", "WebSearch", "Agent", "Workflow", "NotebookEdit",
                     "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
                     "Bash", "Edit", "Write", "Monitor", "LSP"] {
            XCTAssertFalse(profile.allowed.contains(tool), "\(tool) leaked into a narrowed scope")
        }
        XCTAssertEqual(profile.allowed, ["Read", "Glob", "Grep"])
    }

    func testResolvedScopeAppliedToAllowedToolsArg() {
        let scope = ResolvedToolScope(
            effective: ["Bash", "Edit"],
            base: ["Bash", "Edit", "Write"],
            denied: ["Write"],
            contributions: []
        )
        let args = ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope)
        XCTAssertEqual(args, ["--allowedTools", "Bash,Edit"])
    }

    /// A session that asks approves none of the agent's built-in tools ahead
    /// of time — the CLI asks about them as its mode says — and still
    /// approves an MCP server's tools and a rule the agent spells out.
    func testAnAskingSessionApprovesNoBareBuiltInTool() {
        let scope = ResolvedToolScope(
            effective: ["Bash", "Edit", "Read", "Bash(git status)", "mcp__docs__*"],
            base: [], denied: [], contributions: [])

        XCTAssertEqual(ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope, asking: true),
                       ["--allowedTools", "Bash(git status),mcp__docs__*"])
        XCTAssertEqual(ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope, asking: false),
                       ["--allowedTools", "Bash,Bash(git status),Edit,Read,mcp__docs__*"])
    }

    /// With nothing but built-in tools there is no flag at all, and the
    /// bridge's own tools still get one written for them.
    func testAnAskingSessionOfBuiltInToolsWritesNoFlagUntilTheBridgeDoes() {
        let scope = ResolvedToolScope(effective: ["Bash", "Edit"], base: [], denied: [], contributions: [])

        var args = ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope, asking: true)
        XCTAssertEqual(args, [])
        ClaudeCodeCLIRuntime.allowTools(["mcp__kiteloop-tools__message_agent"], in: &args)
        XCTAssertEqual(args, ["--allowedTools", "mcp__kiteloop-tools__message_agent"])
    }

    func testMCPBridgeToolsReachAllowedToolsForNarrowedAgent() {
        let agent = Agent(
            name: "narrow",
            model: "sonnet",
            systemPrompt: "",
            tools: ["Read", "Bash"],
            denied: [],
            permissionMode: "default"
        )
        let scope = ToolScopeResolver.resolve(
            profile: ClaudeCodeCLIRuntime.buildProfileScope(from: agent),
            layers: []
        )
        var args = ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope)
        ClaudeCodeCLIRuntime.allowTools(["mcp__kiteloop-tools__message_agent"], in: &args)

        let allowed = Set(args[1].components(separatedBy: ","))
        XCTAssertTrue(allowed.contains("mcp__kiteloop-tools__message_agent"))
        XCTAssertTrue(allowed.contains("Read"))
        XCTAssertFalse(allowed.contains("WebFetch"))
    }

    /// A tools list that its deny list cancels out leaves no `--allowedTools` arg at all;
    /// the bridge names must still get one written for them.
    func testMCPBridgeToolsWriteAllowedToolsWhenScopeIsEmpty() {
        var args: [String] = ["--print"]
        ClaudeCodeCLIRuntime.allowTools(["mcp__kiteloop-tools__message_agent"], in: &args)
        XCTAssertEqual(args, ["--print", "--allowedTools", "mcp__kiteloop-tools__message_agent"])
    }

    /// The whole of a spawn's permission story, composed the way `provision`
    /// composes it: the mode, the agent's scope and its denials, as flags the
    /// CLI enforces on its own. Nothing names a permission server — there is no
    /// bridge left to allow-list, to point an `--mcp-config` at, or to route a
    /// `--permission-prompt-tool` to.
    func testSpawnFlagsCarryModeAndScopeAndNameNoPermissionServer() throws {
        let agent = Agent(id: "chat", name: "Chat", model: "sonnet", systemPrompt: "",
                          tools: ["Read", "Bash"], denied: ["WebSearch"],
                          permissionMode: "acceptEdits", state: .idle)

        var args = ClaudeCodeCLIRuntime.permissionArguments(agent: agent, unattended: false)
        let scope = ToolScopeResolver.resolve(
            profile: ClaudeCodeCLIRuntime.buildProfileScope(from: agent), layers: [])
        args += ClaudeCodeCLIRuntime.buildAllowedToolsArgs(from: scope)
        ClaudeCodeCLIRuntime.allowTools(["mcp__kiteloop-tools__message_agent"], in: &args)

        let mode = try XCTUnwrap(args.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(args[mode + 1], "acceptEdits")
        let prompts = try XCTUnwrap(args.firstIndex(of: "--permission-prompts"))
        XCTAssertEqual(args[prompts + 1], "host", "an attended session's prompts are Kiteloop's to answer")
        let tool = try XCTUnwrap(args.firstIndex(of: "--permission-prompt-tool"))
        XCTAssertEqual(args[tool + 1], "stdio", "and they travel on the session's own pipes")
        let allowed = try XCTUnwrap(args.firstIndex(of: "--allowedTools"))
        XCTAssertTrue(args[allowed + 1].contains("Read"))
        let denied = try XCTUnwrap(args.firstIndex(of: "--disallowedTools"))
        XCTAssertEqual(args[denied + 1], "WebSearch")

        XCTAssertFalse(args.contains { $0.contains("kiteloop-permission") },
                       "no allow-list entry and no --mcp-config names a permission server")
    }

    /// Every session asks the CLI for its subagents' text and thinking, tagged
    /// with the call that started them — without the flag the chat has only a
    /// subagent's tool calls to draw under its `Agent` row.
    func testEverySpawnForwardsSubagentText() {
        let args = ClaudeCodeCLIRuntime.streamProtocolArguments
        XCTAssertTrue(args.contains("--forward-subagent-text"))
        XCTAssertTrue(args.contains("--print"), "the flag only works with --print")
        let format = args.firstIndex(of: "--output-format").map { args[$0 + 1] }
        XCTAssertEqual(format, "stream-json", "and with stream-json output")
    }

    // MARK: - Agent MCP config allowances

    /// Every server in the agent's config gets its `mcp__<name>__*` allowance,
    /// including one Kiteloop cannot model as a stdio command — an entry like
    /// that used to make the whole file read as absent, so *no* server in it
    /// reached the CLI's allow list.
    func testAgentMCPServersAllReachAllowedTools() throws {
        let dir = try makeTemporaryDirectory(prefix: "cli-mcp-allowances")
        let path = dir.appendingPathComponent("mcp.json").path
        try Data("""
        {
          "mcpServers": {
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        var args: [String] = ["--print"]
        ClaudeCodeCLIRuntime.allowTools(ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: path), in: &args)

        let allowed = Set(args[2].components(separatedBy: ","))
        XCTAssertEqual(allowed, ["mcp__remote__*", "mcp__local__*"])
    }

    /// An agent whose `mcpServers` names one server gets only that server's
    /// allowance — the allowlist the sidebar shows now has teeth.
    func testAgentMCPServersNamedSubsetReachesOnlyThatServer() throws {
        let dir = try makeTemporaryDirectory(prefix: "cli-mcp-allowances-subset")
        let path = dir.appendingPathComponent("mcp.json").path
        try Data("""
        {
          "mcpServers": {
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        let allowances = ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: path, allowing: ["local"])
        XCTAssertEqual(allowances, ["mcp__local__*"])
    }

    /// An empty `mcpServers` list keeps today's behaviour: every server in the
    /// agent's own config reaches the allow list.
    func testAgentMCPServersEmptyListReachesEverySever() throws {
        let dir = try makeTemporaryDirectory(prefix: "cli-mcp-allowances-empty")
        let path = dir.appendingPathComponent("mcp.json").path
        try Data("""
        {
          "mcpServers": {
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        let allowances = ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: path, allowing: [])
        XCTAssertEqual(Set(allowances), ["mcp__remote__*", "mcp__local__*"])
    }

    /// A `*` entry in `mcpServers` means "every server", same as an empty list.
    func testAgentMCPServersWildcardReachesEverySever() throws {
        let dir = try makeTemporaryDirectory(prefix: "cli-mcp-allowances-wildcard")
        let path = dir.appendingPathComponent("mcp.json").path
        try Data("""
        {
          "mcpServers": {
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        let allowances = ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: path, allowing: ["*"])
        XCTAssertEqual(Set(allowances), ["mcp__remote__*", "mcp__local__*"])
    }

    /// A name in `mcpServers` that matches no key in the config yields nothing
    /// for that name — no invented pattern for a server that isn't there.
    func testAgentMCPServersUnknownNameYieldsNoAllowance() throws {
        let dir = try makeTemporaryDirectory(prefix: "cli-mcp-allowances-unknown")
        let path = dir.appendingPathComponent("mcp.json").path
        try Data("""
        {
          "mcpServers": {
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        let allowances = ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: path, allowing: ["ghost"])
        XCTAssertEqual(allowances, [])
    }

    /// No config at that path is not an error — it writes no allowances, and so
    /// no stray `--allowedTools` flag either.
    func testMissingAgentMCPConfigWritesNoAllowances() {
        var args: [String] = ["--print"]
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString)/mcp.json").path
        ClaudeCodeCLIRuntime.allowTools(ClaudeCodeCLIRuntime.mcpServerAllowances(forConfigAt: missing), in: &args)
        XCTAssertEqual(args, ["--print"])
    }

    // MARK: - Global MCP servers

    private func agentForGlobalMCP(mcpServers: [String] = [], mcpConfigPath: String? = nil) -> Agent {
        Agent(id: "chat", name: "Chat", model: "sonnet", systemPrompt: "",
              tools: [], denied: [], permissionMode: "default",
              mcpServers: mcpServers, mcpConfigPath: mcpConfigPath, state: .idle)
    }

    /// A server configured once in Settings reaches the session: its own
    /// `--mcp-config` sits between the tool bridge's and the agent's, so a
    /// project entry of the same name is still the last word.
    func testGlobalMCPServerReachesTheArgumentList() throws {
        let runtime = ClaudeCodeCLIRuntime(
            globalMCPServers: ["docs": ClaudeMCPServerEntry(command: "npx", args: ["-y", "docs-server"])])
        var args: [String] = ["--print"]
        let sessionID = UUID().uuidString

        let globalPath = try XCTUnwrap(runtime.appendMCPConfigArguments(
            sessionID: sessionID,
            agent: agentForGlobalMCP(mcpConfigPath: "/tmp/agent-mcp.json"),
            toolBridgeConfigPath: "/tmp/tools-mcp.json",
            to: &args))
        defer { try? FileManager.default.removeItem(atPath: globalPath) }

        XCTAssertEqual(args, ["--print",
                              "--allowedTools", "mcp__docs__*",
                              "--mcp-config", "/tmp/tools-mcp.json",
                              "--mcp-config", globalPath,
                              "--mcp-config", "/tmp/agent-mcp.json"])

        let written = try XCTUnwrap(ClaudeMCPConfig.load(from: globalPath))
        XCTAssertEqual(written.mcpServers["docs"]?.command, "npx")

        // Named through SessionTempFiles, so the reaper knows it and teardown
        // removes it with the session's other scratch files.
        XCTAssertEqual(globalPath,
                       SessionTempFiles.path(for: .globalMCPConfig, sessionID: sessionID))
        XCTAssertTrue(URL(fileURLWithPath: globalPath).lastPathComponent
            .hasPrefix("\(SessionTempFiles.prefix)\(getpid())-"))
    }

    /// A server changed in Settings reaches the next session a live runtime
    /// spawns: the replaced list is what the config file holds and allows.
    func testReplacedGlobalMCPServersReachTheNextSession() throws {
        let runtime = ClaudeCodeCLIRuntime(
            globalMCPServers: ["docs": ClaudeMCPServerEntry(command: "npx", args: ["-y", "docs-server"])])
        runtime.replaceGlobalMCPServers(
            ["tickets": ClaudeMCPServerEntry(command: "npx", args: ["-y", "tickets-server"])])
        var args: [String] = []

        let globalPath = try XCTUnwrap(runtime.appendMCPConfigArguments(
            sessionID: UUID().uuidString, agent: agentForGlobalMCP(),
            toolBridgeConfigPath: nil, to: &args))
        defer { try? FileManager.default.removeItem(atPath: globalPath) }

        let written = try XCTUnwrap(ClaudeMCPConfig.load(from: globalPath))
        XCTAssertEqual(Array(written.mcpServers.keys), ["tickets"])
        XCTAssertEqual(args, ["--allowedTools", "mcp__tickets__*", "--mcp-config", globalPath])
    }

    /// Every server removed in Settings: the next session gets no global
    /// config file and no argument for one.
    func testGlobalMCPServersReplacedWithNoneAddNoConfig() {
        let runtime = ClaudeCodeCLIRuntime(
            globalMCPServers: ["docs": ClaudeMCPServerEntry(command: "npx", args: ["-y", "docs-server"])])
        runtime.replaceGlobalMCPServers([:])
        var args: [String] = []

        XCTAssertNil(runtime.appendMCPConfigArguments(
            sessionID: UUID().uuidString, agent: agentForGlobalMCP(),
            toolBridgeConfigPath: nil, to: &args))
        XCTAssertEqual(args, [])
    }

    /// The agent's own `mcpServers` filters the global servers exactly as it
    /// filters the project config's: a named subset gets only those, and an
    /// empty list or `*` gets them all.
    func testGlobalMCPServersAreFilteredByTheAgentsOwnList() throws {
        let runtime = ClaudeCodeCLIRuntime(globalMCPServers: [
            "docs": ClaudeMCPServerEntry(command: "npx", args: ["-y", "docs-server"]),
            "tickets": ClaudeMCPServerEntry(extras: ["url": .string("https://example.com/mcp")])
        ])

        for (declared, expected) in [(["docs"], ["mcp__docs__*"]),
                                     ([], ["mcp__docs__*", "mcp__tickets__*"]),
                                     (["*"], ["mcp__docs__*", "mcp__tickets__*"])] {
            var args: [String] = ["--print"]
            let path = try XCTUnwrap(runtime.appendMCPConfigArguments(
                sessionID: UUID().uuidString,
                agent: agentForGlobalMCP(mcpServers: declared),
                toolBridgeConfigPath: nil,
                to: &args))
            defer { try? FileManager.default.removeItem(atPath: path) }

            let idx = try XCTUnwrap(args.firstIndex(of: "--allowedTools"))
            XCTAssertEqual(args[idx + 1].components(separatedBy: ",").sorted(), expected.sorted(),
                           "mcpServers: \(declared)")
        }
    }

    /// With no global server configured the argument list is what it has always
    /// been, flag for flag, and no extra file is written.
    func testNoGlobalMCPServersLeavesTheArgumentListUnchanged() {
        let runtime = ClaudeCodeCLIRuntime()
        var args: [String] = ["--print"]
        let sessionID = UUID().uuidString

        let globalPath = runtime.appendMCPConfigArguments(
            sessionID: sessionID,
            agent: agentForGlobalMCP(mcpConfigPath: "/tmp/agent-mcp.json"),
            toolBridgeConfigPath: "/tmp/tools-mcp.json",
            to: &args)

        XCTAssertNil(globalPath)
        XCTAssertEqual(args, ["--print",
                              "--mcp-config", "/tmp/tools-mcp.json",
                              "--mcp-config", "/tmp/agent-mcp.json"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SessionTempFiles.path(for: .globalMCPConfig, sessionID: sessionID)))
    }
}
