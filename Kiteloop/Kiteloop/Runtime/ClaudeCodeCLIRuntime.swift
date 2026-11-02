import Foundation
import KiteloopCore
import os.log

private let msgLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "message-agent")

final class ClaudeCodeCLIRuntime: AgentRuntime, @unchecked Sendable {
    private static let globalLock = NSLock()
    /// Every access is guarded by `globalLock` — the compiler can't see that,
    /// hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static var allInstances: [WeakRuntime] = []

    private struct WeakRuntime {
        weak var instance: ClaudeCodeCLIRuntime?
    }

    static var globalActiveProcessCount: Int {
        globalLock.withLock {
            allInstances.removeAll { $0.instance == nil }
            return allInstances.compactMap { $0.instance }.reduce(0) { $0 + $1.activeProcessCount }
        }
    }

    private let lock = NSLock()
    private var managedProcesses: [String: ManagedProcess] = [:]
    private var pendingSessions: [String: PendingSession] = [:]

    var activeProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return managedProcesses.count
    }


    private struct PendingSession {
        let agent: Agent
        let cwd: URL
        let strategy: ResumeStrategy
        let options: SessionOptions
    }

    private struct ManagedProcess {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let agent: Agent
        let cwd: URL
        let toolBridge: ToolBridge?
        /// The session-scoped config holding the globally configured MCP
        /// servers, when there were any to hand over. Removed with the rest.
        let globalMCPConfigPath: String?
    }

    private class ToolBridge {
        let responsePipePath: String
        let requestPipePath: String
        let mcpConfigPath: String
        private let pipeLock = NSLock()
        private var _responsePipeHandle: FileHandle?
        private var isClosed = false

        var responsePipeHandle: FileHandle? {
            get { pipeLock.lock(); defer { pipeLock.unlock() }; return _responsePipeHandle }
            set {
                pipeLock.lock()
                let closed = isClosed
                if !closed { _responsePipeHandle = newValue }
                pipeLock.unlock()
                // Opening the response FIFO parks until the bridge opens the read
                // end, so an open started before teardown can land after it.
                // Close that handle instead of stranding a descriptor on a pipe
                // nobody will ever read.
                if closed { newValue?.closeFile() }
            }
        }

        /// Marks the bridge dead and closes the response handle. Idempotent, and
        /// safe against a response-pipe open still in flight.
        func close() {
            pipeLock.lock()
            isClosed = true
            let handle = _responsePipeHandle
            _responsePipeHandle = nil
            pipeLock.unlock()
            handle?.closeFile()
        }

        init(responsePipePath: String, requestPipePath: String, mcpConfigPath: String) {
            self.responsePipePath = responsePipePath
            self.requestPipePath = requestPipePath
            self.mcpConfigPath = mcpConfigPath
        }
    }

    /// Closes and unlinks everything a session put on disk. Every teardown path —
    /// `stop`, `terminateAll`, the process termination handler and a failed spawn
    /// — funnels through here so no path can forget one of the files.
    private static func releaseBridge(tool: ToolBridge?, globalMCPConfigPath: String? = nil) {
        if let globalMCPConfigPath {
            SessionTempFiles.remove(at: globalMCPConfigPath)
        }
        guard let tool else { return }
        tool.close()
        SessionTempFiles.removeFIFO(at: tool.responsePipePath, role: .kiteloopWrites)
        SessionTempFiles.removeFIFO(at: tool.requestPipePath, role: .kiteloopReads)
        SessionTempFiles.remove(at: tool.mcpConfigPath)
    }

    private static func jsonEncodeString(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let arrayStr = String(data: data, encoding: .utf8),
              arrayStr.count > 2 else {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        // Strip the surrounding [ and ] to get just the quoted string
        let start = arrayStr.index(after: arrayStr.startIndex)
        let end = arrayStr.index(before: arrayStr.endIndex)
        return String(arrayStr[start..<end])
    }

    static func buildMultimodalMessage(text: String, attachments: [ChatAttachment]) -> String {
        var blocks: [[String: Any]] = []

        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }

        for attachment in attachments {
            if attachment.isImage {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": attachment.mimeType,
                        "data": attachment.data.base64EncodedString()
                    ]
                ])
            } else {
                let content = attachment.textContent ?? "[binary file: \(attachment.filename)]"
                blocks.append(["type": "text", "text": "--- \(attachment.filename) ---\n\(content)"])
            }
        }

        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": blocks
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            let encodedText = jsonEncodeString(text)
            return "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(encodedText)}}\n"
        }
        return jsonString + "\n"
    }

    private let claudePath: String
    private let nodePath: String
    /// The variables a session's `claude` runs with, for the directory it
    /// runs in — the app's composed `PATH` (`ExecutableSearchPath`) and the
    /// project's build exports (`BuildEnvironment`, a `CARGO_TARGET_DIR`
    /// shared across item worktrees), injected because this layer may not
    /// reach the services layer for them. Nil keeps the app's own
    /// environment, which is what a test runtime wants.
    private let environmentForSpawn: (@Sendable (URL) -> [String: String])?

    /// The MCP servers configured once for the whole app, in Settings — handed
    /// over rather than read from the config store, which lives in the services
    /// layer this one may not reach. Empty means no session gets an extra
    /// config file and the argument list is what it always was. Replaced when
    /// Settings changes; guarded by `globalMCPLock`, since the replacement
    /// arrives from the store while sessions spawn elsewhere.
    private var globalMCPServers: [String: ClaudeMCPServerEntry]
    private let globalMCPLock = NSLock()

    init(claudePath: String? = nil, nodePath: String? = nil,
         environmentForSpawn: (@Sendable (URL) -> [String: String])? = nil,
         globalMCPServers: [String: ClaudeMCPServerEntry] = [:]) {
        self.claudePath = claudePath ?? CLIResolver.claude ?? "/usr/local/bin/claude"
        self.nodePath = nodePath ?? CLIResolver.node ?? "/usr/local/bin/node"
        self.environmentForSpawn = environmentForSpawn
        self.globalMCPServers = globalMCPServers
        Self.globalLock.lock()
        Self.allInstances.append(WeakRuntime(instance: self))
        Self.globalLock.unlock()
    }

    /// A runtime dropped without an explicit `terminateAll` would otherwise
    /// leave its sessions' FIFOs and MCP configs on disk with nobody left
    /// holding a reference to their paths.
    deinit {
        // `terminateAll` takes `lock`, and `lock` is not recursive. Every reader
        // closure therefore holds one strong reference for as long as it is
        // inside a locked region, so the release that runs this deinit can never
        // happen between a `lock()` and its `unlock()` on the reader's own thread
        // — which, with the readers' old `self?.lock.lock()` … `self?.lock.unlock()`
        // spelling, was a deinit re-taking the lock its thread already held: the
        // app froze on 2026-09-09 with the main actor and three readers all
        // waiting on it.
        terminateAll()
    }

    private static let toolBridgeScript = """
    const readline = require('readline');
    const fs = require('fs');
    const rl = readline.createInterface({ input: process.stdin, terminal: false });
    const pipePath = process.env.KITELOOP_TOOL_PIPE;
    const requestPipePath = process.env.KITELOOP_TOOL_REQUEST_PIPE;
    const toolDefs = JSON.parse(process.env.KITELOOP_TOOL_DEFS || '[]');
    if (!pipePath) { process.stderr.write('KITELOOP_TOOL_PIPE not set\\n'); process.exit(1); }
    if (!requestPipePath) { process.stderr.write('KITELOOP_TOOL_REQUEST_PIPE not set\\n'); process.exit(1); }
    let reqFd = null;
    function openRequestPipe() {
      try { reqFd = fs.openSync(requestPipePath, fs.constants.O_WRONLY); } catch(e) { setTimeout(openRequestPipe, 50); }
    }
    openRequestPipe();
    let pending = new Map();
    let pipeBuffer = '';
    function openPipe() {
      try {
        const fd = fs.openSync(pipePath, fs.constants.O_RDONLY);
        const s = fs.createReadStream(null, { fd, encoding: 'utf8' });
        s.on('data', (chunk) => {
          pipeBuffer += chunk;
          const lines = pipeBuffer.split('\\n');
          pipeBuffer = lines.pop();
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const r = JSON.parse(line);
              const resolve = pending.get(r.request_id);
              if (resolve) { pending.delete(r.request_id); resolve(r.result || ''); }
            } catch(e) {}
          }
        });
        s.on('end', () => {});
        s.on('error', () => {});
      } catch(e) { setTimeout(openPipe, 50); }
    }
    openPipe();
    function send(msg) { process.stdout.write(JSON.stringify(msg) + '\\n'); }
    let counter = 0;
    rl.on('line', async (line) => {
      if (!line.trim()) return;
      let msg;
      try { msg = JSON.parse(line); } catch(e) { return; }
      if (msg.method === 'initialize') {
        send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: msg.params?.protocolVersion || '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'kiteloop-tools', version: '1.0.0' } } });
      } else if (msg.method === 'notifications/initialized') {
      } else if (msg.method === 'tools/list') {
        send({ jsonrpc: '2.0', id: msg.id, result: { tools: toolDefs } });
      } else if (msg.method === 'tools/call') {
        const toolName = msg.params?.name || '';
        const args = msg.params?.arguments || {};
        const reqId = `tool_${++counter}_${Date.now()}`;
        const payload = JSON.stringify({ type: 'tool_call', request_id: reqId, tool_name: toolName, input: args }) + '\\n';
        if (reqFd !== null) { fs.writeSync(reqFd, payload); } else { process.stderr.write(payload); }
        const result = await new Promise((resolve) => {
          pending.set(reqId, resolve);
          setTimeout(() => { if (pending.has(reqId)) { pending.delete(reqId); resolve('Error: tool execution timed out'); } }, 300000);
        });
        send({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result) }] } });
      } else if (msg.id !== undefined) {
        send({ jsonrpc: '2.0', id: msg.id, result: {} });
      }
    });
    rl.on('close', () => { if (reqFd !== null) try { fs.closeSync(reqFd); } catch(e) {} process.exit(0); });
    """

    private func toolBridgeScriptPath() -> String {
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiteloop-tool-bridge.js")
            .path(percentEncoded: false)

        FileManager.default.createFile(atPath: scriptPath, contents: Self.toolBridgeScript.data(using: .utf8))
        return scriptPath
    }

    private func setupToolBridge(sessionID: String, agent: Agent) -> ToolBridge? {
        let customTools = KiteloopToolSchemas.jsonToolDefinitions(for: agent)
        guard !customTools.isEmpty else { return nil }

        let scriptPath = toolBridgeScriptPath()

        let responsePipePath = SessionTempFiles.path(for: .toolResponsePipe, sessionID: sessionID)
        let requestPipePath = SessionTempFiles.path(for: .toolRequestPipe, sessionID: sessionID)

        mkfifo(responsePipePath, 0o600)
        mkfifo(requestPipePath, 0o600)

        guard let toolDefsData = try? JSONSerialization.data(withJSONObject: customTools),
              let toolDefsJSON = String(data: toolDefsData, encoding: .utf8) else {
            SessionTempFiles.remove(at: responsePipePath)
            SessionTempFiles.remove(at: requestPipePath)
            return nil
        }

        let mcpConfig: [String: Any] = [
            "mcpServers": [
                "kiteloop-tools": [
                    "command": nodePath,
                    "args": [scriptPath],
                    "env": [
                        "KITELOOP_TOOL_PIPE": responsePipePath,
                        "KITELOOP_TOOL_REQUEST_PIPE": requestPipePath,
                        "KITELOOP_TOOL_DEFS": toolDefsJSON
                    ]
                ]
            ]
        ]

        let mcpConfigPath = SessionTempFiles.path(for: .toolMCPConfig, sessionID: sessionID)

        guard let configData = try? JSONSerialization.data(withJSONObject: mcpConfig),
              FileManager.default.createFile(atPath: mcpConfigPath, contents: configData) else {
            SessionTempFiles.remove(at: responsePipePath)
            SessionTempFiles.remove(at: requestPipePath)
            return nil
        }

        return ToolBridge(
            responsePipePath: responsePipePath,
            requestPipePath: requestPipePath,
            mcpConfigPath: mcpConfigPath
        )
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
        let sessionID = UUID().uuidString
        lock.withLock {
            pendingSessions[sessionID] = PendingSession(agent: agent, cwd: cwd, strategy: strategy, options: options)
        }
        return AgentSession(id: sessionID, agentID: agent.id, startedAt: .now)
    }

    /// The env var that turns off Claude Code's own memory directory. Read by
    /// the CLI at startup; `1` disables.
    static let disableAutoMemoryVariable = "CLAUDE_CODE_DISABLE_AUTO_MEMORY"

    /// What an "Operator tools" grant hands a spawned CLI: the operator-scoped
    /// control-API token and the base URL it answers on. Computed once per
    /// spawn (`loadOperatorToolsGrant`) and threaded through as a value so
    /// `sessionEnvironment` — the part worth unit testing — stays a pure
    /// function over its inputs rather than a second place that touches disk.
    struct OperatorToolsGrant: Equatable {
        let token: String
        let controlURL: String
    }

    /// The env var carrying the operator-scoped control-API token. Set only
    /// when `agent.operatorToolsEnabled` is on.
    static let operatorTokenVariable = "KITELOOP_OPERATOR_TOKEN"
    /// The env var carrying the control API's base URL (`http://127.0.0.1:<port>/v1`).
    static let controlURLVariable = "KITELOOP_CONTROL_URL"

    /// How every session talks to Kiteloop: newline-delimited JSON both
    /// ways, every line the CLI has (`--verbose`), and a subagent's text and
    /// thinking forwarded with the `parent_tool_use_id` of the call that
    /// started it (`--forward-subagent-text`), so the chat can draw them under
    /// that call. Every consumer that sums `.assistantText` into an answer
    /// skips a line with a parent — see `StreamEvent.assistantText`.
    static let streamProtocolArguments = [
        "--print",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",
        "--forward-subagent-text",
    ]

    /// The `--max-turns` a session is spawned with: the budget set on its
    /// agent, or 50 when none is.
    static func maxTurnsArgument(for agent: Agent) -> String {
        String(agent.maxTurns ?? 50)
    }

    /// The env var the CLI reads a thinking budget from. It has no flag for
    /// one: `--thinking` takes a mode, not a token count.
    static let maxThinkingTokensVariable = "MAX_THINKING_TOKENS"

    /// The thinking arguments a session is spawned with: `--thinking enabled`
    /// when the agent has thinking on, nothing otherwise. The CLI declares
    /// `--thinking <mode>`, so a bare `--thinking` swallows the next argument
    /// as its mode and the CLI exits before the session starts.
    static func thinkingArguments(for agent: Agent) -> [String] {
        agent.thinkingEnabled ? ["--thinking", "enabled"] : []
    }

    /// The environment carrying the agent's thinking budget: set only when
    /// thinking is on and the budget is positive.
    static func thinkingEnvironment(for agent: Agent) -> [String: String] {
        guard agent.thinkingEnabled, let budget = agent.thinkingBudget, budget > 0 else { return [:] }
        return [maxThinkingTokensVariable: String(budget)]
    }

    /// The environment a spawned CLI runs with, given how the session will be
    /// driven and, for an agent with the operator-tools grant on, what
    /// credential it should carry.
    ///
    /// Claude Code's auto-memory is on by default and keyed to the **git repo
    /// root**, so an autopilot worker and its reviewer — same repo, by
    /// construction — would share one self-maintained memory directory under
    /// `~/.claude` that Kiteloop never shows, never curates and never gates. A
    /// worker's half-verified belief written there becomes the reviewer's prior
    /// on the next run, and the reviewer's independence is what the whole review
    /// model rests on. Unattended sessions therefore get no such memory: their
    /// only compounding channels are the audited ones — run outcomes distilled
    /// into the capped coordinator knowledge, and `propose_memory`, which a
    /// human answers.
    ///
    /// An interactive session is handed the environment back untouched: a human
    /// chatting with an agent is on the other side of that gate already, and
    /// changing their memory story is not this decision. The operator-tools
    /// grant is independent of `unattended` — it is granted per agent, not per
    /// session kind, so it applies exactly the same to a chat session and to an
    /// autopilot worker.
    static func sessionEnvironment(
        _ base: [String: String],
        unattended: Bool,
        operatorTools: OperatorToolsGrant? = nil
    ) -> [String: String] {
        var env = base
        if unattended {
            env[disableAutoMemoryVariable] = "1"
        }
        if let operatorTools {
            env[operatorTokenVariable] = operatorTools.token
            env[controlURLVariable] = operatorTools.controlURL
        }
        return env
    }

    /// The operator-tools grant for a spawn, or `nil` when the agent's toggle is
    /// off — in which case its environment carries neither variable at all.
    ///
    /// Reads `~/.kiteloop/global-config.json` fresh at every spawn via
    /// `SpawnTimeConfigRead`, same reasoning as `ClaudeAuthConfig.loadCurrent()`
    /// above it: a port changed in Settings must apply to the next session
    /// without an app restart. The token itself comes from
    /// `KiteloopControlServer.loadOrCreateToken`, the same minting path
    /// `~/.kiteloop/control-token` uses — the operator token is created the
    /// moment the app's `KiteloopControlServer` is built (at launch, whether or
    /// not the API is switched on), so this is ordinarily a read; it only mints
    /// if that file is somehow missing.
    private static func loadOperatorToolsGrant() -> OperatorToolsGrant {
        let port = SpawnTimeConfigRead.load()?.controlServerPort
        let token = KiteloopControlServer.loadOrCreateToken(at: KiteloopControlServer.defaultOperatorTokenURL)
        let resolvedPort = KiteloopControlServer.resolvedPort(port)
        return OperatorToolsGrant(token: token, controlURL: "http://127.0.0.1:\(resolvedPort)/v1")
    }

    /// The auth environment with the app's overlay for `cwd` laid on top —
    /// the composed search path and the project's build exports; a worktree's
    /// spawn reads the project above it — so the agent's shell finds the same
    /// tools, and the same build output, the verify gate does. Untouched when
    /// no provider was injected.
    private func spawnEnvironment(auth: ClaudeAuthConfig, cwd: URL) -> [String: String] {
        let environment = auth.processEnvironment()
        guard let environmentForSpawn else { return environment }
        return environment.merging(environmentForSpawn(cwd)) { _, overlay in overlay }
    }

    /// The child's full environment: auth and the spawn overlay, the session
    /// variables and operator-tools grant, then the agent's thinking settings.
    private func processEnvironment(agent: Agent, auth: ClaudeAuthConfig, cwd: URL, unattended: Bool) -> [String: String] {
        let operatorGrant = agent.operatorToolsEnabled ? Self.loadOperatorToolsGrant() : nil
        return Self.sessionEnvironment(spawnEnvironment(auth: auth, cwd: cwd),
                                       unattended: unattended,
                                       operatorTools: operatorGrant)
            .merging(Self.thinkingEnvironment(for: agent)) { _, thinking in thinking }
    }

    private func provision(sessionID: String, agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        // Re-read auth config at every spawn so backend/auth changes in Settings
        // apply to new sessions without an app restart.
        let auth = ClaudeAuthConfig.loadCurrent()
        process.environment = processEnvironment(agent: agent, auth: auth, cwd: cwd, unattended: options.unattended)

        var args = Self.launchArguments(agent: agent, auth: auth, unattended: options.unattended)

        let toolBridge = setupToolBridge(sessionID: sessionID, agent: agent)

        if toolBridge != nil {
            Self.allowTools(KiteloopToolSchemas.schemasForAgent(agent).map { "mcp__kiteloop-tools__\($0.name)" }, in: &args)
        }

        if let mcpPath = agent.mcpConfigPath {
            Self.allowTools(Self.mcpServerAllowances(forConfigAt: mcpPath, allowing: agent.mcpServers), in: &args)
        }

        let globalMCPConfigPath = appendMCPConfigArguments(
            sessionID: sessionID,
            agent: agent,
            toolBridgeConfigPath: toolBridge?.mcpConfigPath,
            to: &args)

        args += Self.resumeArguments(for: strategy)

        process.arguments = args
        process.currentDirectoryURL = cwd

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Read rather than discarded: nothing on it steers the session any more,
        // but it is where the CLI says why a spawn or an MCP server failed, and
        // an undrained pipe fills and blocks the child.
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            Self.releaseBridge(tool: toolBridge, globalMCPConfigPath: globalMCPConfigPath)
            throw RuntimeError.processSpawnFailed(error.localizedDescription)
        }

        register(ManagedProcess(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            agent: agent,
            cwd: cwd,
            toolBridge: toolBridge,
            globalMCPConfigPath: globalMCPConfigPath
        ), sessionID: sessionID, stderrPipe: stderrPipe)
    }

    /// Records a running session and starts draining its pipes.
    private func register(_ managed: ManagedProcess, sessionID: String, stderrPipe: Pipe) {
        // Covers the crash case: the CLI dying on its own still drops the
        // session's FIFOs and MCP configs. `stop` removes the entry first when it
        // wins the race, and has already done the same teardown.
        managed.process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let removed = self.managedProcesses.removeValue(forKey: sessionID)
            self.lock.unlock()
            guard let removed else { return }
            Self.releaseBridge(tool: removed.toolBridge, globalMCPConfigPath: removed.globalMCPConfigPath)
        }

        lock.lock()
        managedProcesses[sessionID] = managed
        lock.unlock()

        startStderrReader(sessionID: sessionID, stderrPipe: stderrPipe)
        if let toolBridge = managed.toolBridge {
            startToolRequestPipeReader(sessionID: sessionID, pipePath: toolBridge.requestPipePath)
            DispatchQueue.global(qos: .userInitiated).async {
                toolBridge.responsePipeHandle = FileHandle(forWritingAtPath: toolBridge.responsePipePath)
            }
        }

        startStdoutReader(sessionID: sessionID, stdoutPipe: managed.stdoutPipe)
    }

    /// The agent-derived CLI arguments: protocol, model, limits, permissions,
    /// tuning, tool scope, system prompt and workspace directory.
    private static func launchArguments(agent: Agent, auth: ClaudeAuthConfig, unattended: Bool) -> [String] {
        var args = streamProtocolArguments + [
            "--model", ModelCatalog.launchModel(for: agent.model, auth: auth),
            "--max-turns", maxTurnsArgument(for: agent),
        ]
        args += permissionArguments(agent: agent, unattended: unattended)
        args += tuningArguments(for: agent)
        args += ["--include-hook-events"]

        let profileScope = buildProfileScope(from: agent)
        let resolvedScope = ToolScopeResolver.resolve(profile: profileScope, layers: [])
        args += buildAllowedToolsArgs(from: resolvedScope)

        args += appendedSystemPromptArguments(for: agent)

        if let workspacePath = agent.workspacePath, !workspacePath.isEmpty {
            args += ["--add-dir", workspacePath]
        }
        return args
    }

    /// Effort, budget and thinking flags, each only when the agent sets it.
    private static func tuningArguments(for agent: Agent) -> [String] {
        var args: [String] = []
        if let effort = agent.effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if let budget = agent.maxBudgetUSD, budget > 0 {
            args += ["--max-budget-usd", String(format: "%.2f", budget)]
        }
        return args + thinkingArguments(for: agent)
    }

    /// The agent's system prompt, with the operator-tools note when granted.
    ///
    /// The operator-tools knowledge note ships with the grant itself rather
    /// than needing a knowledge package: an agent with no package at all —
    /// most chat agents — would otherwise get the credential and no idea
    /// what it is for.
    private static func appendedSystemPromptArguments(for agent: Agent) -> [String] {
        var appendedSystemPrompt = agent.systemPrompt
        if agent.operatorToolsEnabled {
            appendedSystemPrompt = appendedSystemPrompt.isEmpty
                ? OperatorToolsKnowledge.note
                : appendedSystemPrompt + "\n\n" + OperatorToolsKnowledge.note
        }
        guard !appendedSystemPrompt.isEmpty else { return [] }
        return ["--append-system-prompt", appendedSystemPrompt]
    }

    private static func resumeArguments(for strategy: ResumeStrategy) -> [String] {
        switch strategy {
        case .fresh:
            return []
        case .resume(let sid):
            return ["--resume", sid]
        case .fork(let sid):
            return ["--resume", sid, "--fork-session"]
        case .compact(let sid):
            return ["--resume", sid, "--compact"]
        }
    }

    private var stdoutContinuations: [String: AsyncStream<StreamEvent>.Continuation] = [:]
    private var stdoutGeneration: [String: UInt64] = [:]

    /// The first model call's usage of the leg currently in flight, per session —
    /// held only until that leg's `result` claims it.
    ///
    /// Kept here because it is the one fact the stream states once and never
    /// repeats: the opening prompt's size is on the first `assistant` line, and
    /// by the time `result` arrives the counters have been summed over every
    /// model call the leg made. Cleared as the `result` takes it, so the next
    /// prompt on the same session measures its own opening call rather than
    /// inheriting the last one's.
    private var openingUsage: [String: TokenUsage] = [:]

    /// Notices about background work that arrived between turns, per session,
    /// held for the next turn's sink.
    ///
    /// A turn's sink ends at its `result`, but a background shell or subagent
    /// outlives the turn that started it: the CLI says it finished, and that it
    /// left the background list, after the `result`, when nothing is listening.
    /// Dropped, the chat would say it was still running forever; held, the next
    /// turn opens by catching up on it.
    private var heldActivity: [String: [StreamEvent]] = [:]

    /// Per session: whether a turn the CLI started on its own is under way.
    /// See `UnpromptedTurnTracker`.
    private var unpromptedTurnTrackers: [String: UnpromptedTurnTracker] = [:]

    /// Per session: whoever takes the turns the CLI starts on its own, with a
    /// token so a replaced listener's teardown cannot remove its successor.
    private var unpromptedTurnListeners: [String: (token: UUID, continuation: AsyncStream<AsyncStream<StreamEvent>>.Continuation)] = [:]

    /// Per session: sends made while an unprompted turn was open, waiting for
    /// its `result`. See `registerOrDefer`.
    private var deferredSends: [String: [DeferredSend]] = [:]

    /// A send held back until the unprompted turn ends: the stream its turn
    /// will arrive on, and the stdin write that starts that turn.
    private struct DeferredSend {
        let continuation: AsyncStream<StreamEvent>.Continuation
        let write: @Sendable () -> Void
    }

    /// Internal rather than private so a test can start a reader on a pipe of
    /// its own and release the runtime under it.
    func startStdoutReader(sessionID: String, stdoutPipe: Pipe) {
        let fileHandle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = LineBuffer()
            msgLog.info("[stdout-reader] \(sessionID.prefix(8), privacy: .public): persistent reader started")
            while true {
                // The blocking read holds no reference: a runtime whose readers
                // retained it across `availableData` would live as long as its
                // child kept stdout open, and its `deinit` — the one thing that
                // ends that child — could never run.
                let chunk = fileHandle.availableData
                // One strong reference for the rest of this chunk. Every locked
                // region the chunk reaches sits inside it, so the release that
                // runs `deinit` cannot land between a `lock()` and its `unlock()`
                // on this thread; with `self?` per statement it could, and did.
                guard let self else {
                    msgLog.info("[stdout-reader] \(sessionID.prefix(8), privacy: .public): runtime gone — reader ending")
                    return
                }
                if self.consumeStdout(chunk: chunk, buffer: &buffer, sessionID: sessionID) { return }
            }
        }
    }

    /// One chunk of the CLI's stdout: its lines delivered, and at EOF the
    /// session's sink finished. True when the reader is done.
    private func consumeStdout(chunk: Data, buffer: inout LineBuffer, sessionID: String) -> Bool {
        let lines: [String]
        if chunk.isEmpty {
            // Deliver a final line the CLI never newline-terminated before
            // tearing the stream down.
            lines = buffer.flush().map { [$0] } ?? []
        } else {
            lines = buffer.append(chunk)
        }
        for line in lines {
            noteOpeningUsage(inLine: line, sessionID: sessionID)
            if let event = try? StreamEvent.parse(line) { deliver(event, sessionID: sessionID) }
        }
        guard chunk.isEmpty else { return false }
        finishStdout(sessionID: sessionID)
        return true
    }

    /// Before parsing: the opening call's own counters, which the leg's
    /// `result` will otherwise have summed away. First one wins — later
    /// assistant lines are further into the leg.
    private func noteOpeningUsage(inLine line: String, sessionID: String) {
        guard let usage = StreamEvent.assistantUsage(inLine: line) else { return }
        lock.lock()
        if openingUsage[sessionID] == nil { openingUsage[sessionID] = usage }
        lock.unlock()
    }

    /// Hands one parsed event to the session's sink. A `result` carries the
    /// opening call's usage with it and ends the sink.
    private func deliver(_ parsed: StreamEvent, sessionID: String) {
        var event = parsed
        if case .result(var payload) = event {
            lock.lock()
            payload.openingUsage = openingUsage.removeValue(forKey: sessionID)
            lock.unlock()
            event = .result(payload)
        }
        lock.lock()
        let cont = stdoutContinuations[sessionID]
        lock.unlock()
        guard let cont else {
            holdBetweenTurns(event, sessionID: sessionID)
            return
        }
        if case .terminated = cont.yield(event) {
            msgLog.warning("[stdout-reader] \(sessionID.prefix(8), privacy: .public): yield returned .terminated")
        }
        if case .result = event { endTurn(on: cont, sessionID: sessionID) }
    }

    /// A `result` ends the sink it went to. When that sink was a turn the CLI
    /// started by itself, the sends that waited for it go now.
    private func endTurn(on cont: AsyncStream<StreamEvent>.Continuation, sessionID: String) {
        cont.finish()
        let released: [DeferredSend] = lock.withLock {
            stdoutContinuations.removeValue(forKey: sessionID)
            guard unpromptedTurnTrackers[sessionID]?.resultDelivered() == true else { return [] }
            return deferredSends.removeValue(forKey: sessionID) ?? []
        }
        release(released, sessionID: sessionID)
    }

    /// An event with no turn to go to, routed by `UnpromptedTurnTracker`: a
    /// notice about background work is kept for the next turn, the opening
    /// line of a turn the CLI started by itself opens a stream for it, the
    /// `result` of one nobody heard lets the sends waiting on it go, and
    /// anything else is dropped.
    private func holdBetweenTurns(_ event: StreamEvent, sessionID: String) {
        let action: UnpromptedTurnTracker.Action = lock.withLock {
            unpromptedTurnTrackers[sessionID, default: UnpromptedTurnTracker()]
                .route(event.betweenTurnsLine, canDeliver: unpromptedTurnListeners[sessionID] != nil)
        }
        switch action {
        case .hold:
            lock.withLock { heldActivity[sessionID, default: []].append(event) }
        case .open:
            openUnpromptedTurn(with: event, sessionID: sessionID)
        case .close:
            release(lock.withLock { deferredSends.removeValue(forKey: sessionID) ?? [] }, sessionID: sessionID)
        case .drop:
            msgLog.warning("[stdout-reader] \(sessionID.prefix(8), privacy: .public): event DROPPED — no continuation")
        }
    }

    /// How many notices are waiting for `sessionID`'s next turn. Internal so a
    /// test can wait for the reader to have held one before a turn starts.
    func heldActivityCount(for sessionID: String) -> Int {
        lock.withLock { heldActivity[sessionID]?.count ?? 0 }
    }

    /// EOF: the session's sink is finished and its per-session state dropped.
    private func finishStdout(sessionID: String) {
        msgLog.info("[stdout-reader] \(sessionID.prefix(8), privacy: .public): EOF — finishing")
        lock.lock()
        let cont = stdoutContinuations.removeValue(forKey: sessionID)
        stdoutGeneration.removeValue(forKey: sessionID)
        // A leg that died before its `result` leaves its opening call here;
        // the session is gone, so nothing will ever claim it.
        openingUsage.removeValue(forKey: sessionID)
        heldActivity.removeValue(forKey: sessionID)
        unpromptedTurnTrackers.removeValue(forKey: sessionID)
        let listener = unpromptedTurnListeners.removeValue(forKey: sessionID)
        // A send still waiting on a turn that will now never end gets an
        // ended stream rather than one nothing will ever finish.
        let stranded = deferredSends.removeValue(forKey: sessionID) ?? []
        lock.unlock()
        cont?.finish()
        listener?.continuation.finish()
        stranded.forEach { $0.continuation.finish() }
    }

    /// Parses one line of the newline-delimited JSON the tool bridge writes to
    /// the request FIFO. Unlike the stderr protocol, this pipe carries nothing
    /// but tool calls, so both `request_id` and `tool_name` are required and a
    /// line missing either is dropped. The tool's arguments are re-encoded as a
    /// JSON object string for `MCPToolCallPayload.input`.
    static func parseToolRequestLine(_ line: String) -> StreamEvent.MCPToolCallPayload? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = json["request_id"] as? String,
              let toolName = json["tool_name"] as? String else { return nil }

        let input = json["input"] as? [String: Any] ?? [:]
        let inputJSON: String
        if let inputData = try? JSONSerialization.data(withJSONObject: input),
           let inputStr = String(data: inputData, encoding: .utf8) {
            inputJSON = inputStr
        } else {
            inputJSON = "{}"
        }

        return StreamEvent.MCPToolCallPayload(
            requestID: requestID,
            toolName: toolName,
            input: inputJSON
        )
    }

    /// Builds the result line Kiteloop writes back to the tool bridge's response
    /// FIFO. The bridge matches it to the pending call by `request_id` and hands
    /// `result` to Claude Code as the tool's text content.
    static func mcpToolResultJSON(requestID: String, result: String) -> String {
        "{\"request_id\":\(jsonEncodeString(requestID)),\"result\":\(jsonEncodeString(result))}\n"
    }

    /// Drains the CLI's stderr, logging what it says.
    ///
    /// Nothing here steers the session: what a tool is allowed to do is settled
    /// by the flags the spawn carries. This exists because the CLI's own
    /// diagnostics — a backend that would not authenticate, an MCP server that
    /// would not start — arrive on stderr and nowhere else, and because a pipe
    /// nobody reads fills and then blocks the child writing to it.
    private func startStderrReader(sessionID: String, stderrPipe: Pipe) {
        let fileHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = LineBuffer()
            while true {
                let chunk = fileHandle.availableData
                let lines = chunk.isEmpty ? buffer.flush().map { [$0] } ?? [] : buffer.append(chunk)

                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    msgLog.info("[stderr] \(sessionID.prefix(8), privacy: .public): \(line)")
                }

                if chunk.isEmpty { return }
            }
        }
    }

    private func startToolRequestPipeReader(sessionID: String, pipePath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = open(pipePath, O_RDONLY)
            guard fd >= 0 else {
                msgLog.error("[tool-pipe-reader] \(sessionID.prefix(8), privacy: .public): failed to open request pipe")
                kiteloopLog("[tool-pipe-reader] \(sessionID.prefix(8)): failed to open request pipe", category: "runtime", level: .error)
                return
            }
            msgLog.info("[tool-pipe-reader] \(sessionID.prefix(8), privacy: .public): opened request pipe, listening")
            kiteloopLog("[tool-pipe-reader] \(sessionID.prefix(8)): opened request pipe, listening", category: "runtime")
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var buffer = LineBuffer()
            while true {
                let chunk = handle.availableData
                // One strong reference per chunk, never across the blocking
                // read — see `startStdoutReader` for why both halves matter.
                guard let self else { return }
                let lines = chunk.isEmpty ? buffer.flush().map { [$0] } ?? [] : buffer.append(chunk)

                for line in lines { self.injectToolRequest(line, sessionID: sessionID) }

                if chunk.isEmpty {
                    msgLog.info("[tool-pipe-reader] \(sessionID.prefix(8), privacy: .public): EOF on request pipe")
                    return
                }
            }
        }
    }

    /// One line off the request pipe, injected into the session's sink as a
    /// tool call; a line that is not a request, or a session with no sink,
    /// is logged and dropped.
    private func injectToolRequest(_ line: String, sessionID: String) {
        guard let payload = Self.parseToolRequestLine(line) else { return }
        let requestID = payload.requestID
        let toolName = payload.toolName
        lock.lock()
        let continuation = stdoutContinuations[sessionID]
        lock.unlock()
        guard let continuation else {
            msgLog.warning("[tool-pipe-reader] \(sessionID.prefix(8), privacy: .public): \(toolName, privacy: .public) DROPPED — no continuation")
            kiteloopLog("[tool-pipe-reader] \(sessionID.prefix(8)): \(toolName) DROPPED — no continuation", category: "runtime", level: .error)
            return
        }
        msgLog.info("[tool-pipe-reader] \(sessionID.prefix(8), privacy: .public): injecting \(toolName, privacy: .public) (reqID=\(requestID.prefix(12), privacy: .public))")
        kiteloopLog("[tool-pipe-reader] \(sessionID.prefix(8)): injecting \(toolName) (reqID=\(requestID.prefix(12)))", category: "runtime")
        continuation.yield(StreamEvent.mcpToolCall(payload))
    }

    // MARK: - Writing to a child that may already be gone

    /// Writes `data` through `handle`'s descriptor, and answers whether every
    /// byte of it landed.
    ///
    /// Every write Kiteloop makes into a session's child goes through here.
    /// Foundation's non-throwing `FileHandle.write(_:)` raises an Objective-C
    /// `NSFileHandleOperationException` when the OS refuses the write — a
    /// broken pipe once the CLI has exited, a handle `cleanup(_:)` closed from
    /// another thread while the send was still in flight — and no Swift
    /// `catch` can take an Objective-C exception, so the process aborts. A
    /// crash report from this repo's own test host on 2026-09-09 is precisely
    /// that stack: a background block writing into a session's stdin, then
    /// `objc_exception_throw`, then `terminate`. `write(2)` on the descriptor
    /// reports those same refusals as a return value, so the caller learns the
    /// bytes did not land instead of losing the app.
    static func writeToChild(_ data: Data, through handle: FileHandle) -> Bool {
        guard let descriptor = descriptorIfOpen(handle) else { return false }
        // Per descriptor, not per process: writing to a pipe whose reader is
        // gone is answered by SIGPIPE first, and its default disposition kills
        // Kiteloop before `write` can return `EPIPE` for us to report. This
        // says so for this one descriptor and leaves every other one alone.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { Self.writeEveryByte(of: $0, to: descriptor) }
    }

    /// The descriptor `handle` is open on, or nil once it has been closed.
    ///
    /// `FileHandle.fileDescriptor` raises on a closed handle — the very case
    /// this helper exists for — so it cannot simply be asked. A zero-byte
    /// write through the throwing API asks the same question and *answers*
    /// it: it reports a closed handle as a Swift error, and on an open one it
    /// moves no bytes and touches nothing the payload write goes on to use.
    /// A handle closed in the moment between the two calls is the
    /// close-against-write race this fix deliberately leaves alone.
    private static func descriptorIfOpen(_ handle: FileHandle) -> Int32? {
        do {
            try handle.write(contentsOf: Data())
        } catch {
            return nil
        }
        return handle.fileDescriptor
    }

    /// `write(2)` until the whole buffer is gone. A payload larger than the
    /// pipe's buffer leaves in bites, so a short write is progress and not an
    /// answer; a signal delivered mid-call interrupts the write rather than
    /// failing it, and is retried. Anything else — `EPIPE` from a CLI that has
    /// exited, `EBADF` from a descriptor already closed — is a refusal, and
    /// what is left of the payload did not land.
    private static func writeEveryByte(of buffer: UnsafeRawBufferPointer, to descriptor: Int32) -> Bool {
        guard var next = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let written = Darwin.write(descriptor, next, remaining)
            if written > 0 {
                next += written
                remaining -= written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Writes to a child and says what happened on `msgLog`, where each call
    /// site already logged its success: `detail` is that success line, and a
    /// refusal is logged against the same session id rather than passing in
    /// silence.
    private static func writeToChild(
        _ data: Data,
        through handle: FileHandle,
        label: String,
        sessionID: String,
        detail: String
    ) {
        guard writeToChild(data, through: handle) else {
            msgLog.error("[\(label, privacy: .public)] \(sessionID, privacy: .public): write refused — \(data.count) bytes did not land (\(detail, privacy: .public))")
            return
        }
        msgLog.info("[\(label, privacy: .public)] \(sessionID, privacy: .public): \(detail, privacy: .public)")
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        lock.lock()
        let pending = pendingSessions.removeValue(forKey: session.id)
        lock.unlock()

        if let pending {
            do {
                try provision(sessionID: session.id, agent: pending.agent, cwd: pending.cwd,
                              strategy: pending.strategy, options: pending.options)
            } catch {
                return AsyncStream { continuation in
                    continuation.yield(.system(subtype: "error", payload: ["message": "Failed to provision agent: \(error.localizedDescription)"]))
                    continuation.finish()
                }
            }
        }

        lock.lock()
        guard let managed = managedProcesses[session.id] else {
            lock.unlock()
            return AsyncStream { $0.finish() }
        }
        lock.unlock()

        guard managed.process.isRunning else {
            return AsyncStream { $0.finish() }
        }

        let jsonMessage: String
        if attachments.isEmpty {
            let encodedMessage = Self.jsonEncodeString(message)
            jsonMessage = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(encodedMessage)}}\n"
        } else {
            jsonMessage = Self.buildMultimodalMessage(text: message, attachments: attachments)
        }

        guard let data = jsonMessage.data(using: .utf8) else {
            return AsyncStream { $0.finish() }
        }

        let stdinHandle = managed.stdinPipe.fileHandleForWriting
        let sessionID = session.id
        let agentName = managed.agent.name

        return AsyncStream(bufferingPolicy: .unbounded) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.registerOrDefer(continuation, sessionID: sessionID) {
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.writeToChild(data, through: stdinHandle, label: "send", sessionID: sessionID,
                                      detail: "agent=\(agentName): wrote \(data.count) bytes to stdin")
                }
            }
        }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {
        lock.lock()
        guard let managed = managedProcesses[session.id] else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard managed.process.isRunning else { return }
        guard let toolBridge = managed.toolBridge else { return }

        let json = Self.mcpToolResultJSON(requestID: requestID, result: result)
        guard let data = json.data(using: .utf8) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            if toolBridge.responsePipeHandle == nil {
                kiteloopLog("[sendMCPToolResult] \(session.id.prefix(8)): opening response pipe (lazy)", category: "runtime")
                toolBridge.responsePipeHandle = FileHandle(forWritingAtPath: toolBridge.responsePipePath)
            }
            guard let fh = toolBridge.responsePipeHandle else {
                msgLog.error("[sendMCPToolResult] failed to open response pipe for session \(session.id.prefix(8), privacy: .public)")
                kiteloopLog("[sendMCPToolResult] \(session.id.prefix(8)): FAILED to open response pipe", category: "runtime", level: .error)
                return
            }
            kiteloopLog("[sendMCPToolResult] \(session.id.prefix(8)): writing \(data.count) bytes (reqID=\(requestID.prefix(12)))", category: "runtime")
            Self.writeToChild(data, through: fh, label: "sendMCPToolResult", sessionID: session.id,
                              detail: "wrote \(data.count) bytes to the response pipe (reqID=\(requestID.prefix(12)))")
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        lock.lock()
        guard let managed = managedProcesses[session.id] else {
            lock.unlock()
            return AsyncStream { $0.finish() }
        }
        lock.unlock()

        guard managed.process.isRunning else {
            return AsyncStream { $0.finish() }
        }

        let encodedContent = Self.jsonEncodeString(content)
        let jsonMessage = "{\"type\":\"tool_result\",\"tool_use_id\":\(Self.jsonEncodeString(toolCallID)),\"content\":\(encodedContent)}\n"

        guard let data = jsonMessage.data(using: .utf8) else {
            return AsyncStream { $0.finish() }
        }

        let stdinHandle = managed.stdinPipe.fileHandleForWriting
        let sessionID = session.id

        return AsyncStream(bufferingPolicy: .unbounded) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let gen = self.registerContinuation(continuation, sessionID: sessionID)
            msgLog.info("[sendToolResult] \(sessionID, privacy: .public): registered stdout continuation gen=\(gen)")

            DispatchQueue.global(qos: .userInitiated).async {
                Self.writeToChild(data, through: stdinHandle, label: "sendToolResult", sessionID: sessionID,
                                  detail: "wrote tool_result for \(toolCallID)")
            }
        }
    }

    /// Makes `continuation` the live event sink for a session — the CLI's
    /// stdout and the tool bridge's requests both land on it — retiring any
    /// previous one, and returns its generation number.
    ///
    /// Two ordering rules are load-bearing here, both learned the hard way:
    /// the retired continuations are finished only *after* the lock is
    /// released (their onTermination handlers take the same lock), and
    /// onTermination only clears state if the generation still matches, so a
    /// late teardown can't evict a newer continuation.
    /// Internal rather than private so a test can open a turn on a reader it
    /// started itself.
    func registerContinuation(
        _ continuation: AsyncStream<StreamEvent>.Continuation,
        sessionID: String
    ) -> UInt64 {
        let (gen, oldStdout) = lock.withLock { installContinuationLocked(continuation, sessionID: sessionID) }
        return finishRegistering(continuation, generation: gen, replacing: oldStdout, sessionID: sessionID)
    }

    /// The locked half of `registerContinuation`: `continuation` becomes the
    /// session's sink, with whatever was held for it, and the sink it replaces
    /// comes back to be finished once the lock is released.
    private func installContinuationLocked(
        _ continuation: AsyncStream<StreamEvent>.Continuation,
        sessionID: String
    ) -> (UInt64, AsyncStream<StreamEvent>.Continuation?) {
        let oldStdout = stdoutContinuations[sessionID]
        let generation = (stdoutGeneration[sessionID] ?? 0) &+ 1
        stdoutContinuations[sessionID] = continuation
        stdoutGeneration[sessionID] = generation
        // Under the lock, so nothing the reader delivers next overtakes
        // what arrived while no turn was listening.
        heldActivity.removeValue(forKey: sessionID)?.forEach { continuation.yield($0) }
        return (generation, oldStdout)
    }

    /// The unlocked half: the replaced sink finished, and this one set to
    /// clear itself when its consumer lets go.
    private func finishRegistering(
        _ continuation: AsyncStream<StreamEvent>.Continuation,
        generation gen: UInt64,
        replacing oldStdout: AsyncStream<StreamEvent>.Continuation?,
        sessionID: String
    ) -> UInt64 {
        oldStdout?.finish()

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if self.stdoutGeneration[sessionID] == gen {
                    self.stdoutContinuations.removeValue(forKey: sessionID)
                    self.stdoutGeneration.removeValue(forKey: sessionID)
                }
            }
        }

        return gen
    }

    func interrupt(session: AgentSession) {
        lock.lock()
        if pendingSessions[session.id] != nil {
            lock.unlock()
            return
        }
        guard let managed = managedProcesses[session.id] else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard managed.process.isRunning else { return }

        // Send a stream-json control_request instead of SIGINT so the CLI
        // cancels the current turn without tearing down stdio pipes.
        let requestID = "req_\(UUID().uuidString)"
        let json = "{\"type\":\"control_request\",\"request_id\":\(Self.jsonEncodeString(requestID)),\"request\":{\"subtype\":\"interrupt\"}}\n"
        guard let data = json.data(using: .utf8) else { return }

        let stdinHandle = managed.stdinPipe.fileHandleForWriting
        let sessionID = session.id
        DispatchQueue.global(qos: .userInitiated).async {
            Self.writeToChild(data, through: stdinHandle, label: "interrupt", sessionID: sessionID,
                              detail: "sent control_request interrupt")
        }
    }

    func stop(session: AgentSession) {
        lock.lock()
        let listener = unpromptedTurnListeners.removeValue(forKey: session.id)
        if pendingSessions.removeValue(forKey: session.id) != nil {
            lock.unlock()
            listener?.continuation.finish()
            return
        }
        let managed = managedProcesses.removeValue(forKey: session.id)
        lock.unlock()
        listener?.continuation.finish()

        guard let managed else { return }
        cleanup(managed)
    }

    /// Terminates a process — and everything it forked, e.g. the node bridges
    /// the CLI spawned or a `Bash` child still running — and removes its
    /// pipes/FIFOs from disk.
    private func cleanup(_ managed: ManagedProcess) {
        managed.stdinPipe.fileHandleForWriting.closeFile()
        ProcessTree.terminateAll([managed.process])
        Self.releaseBridge(tool: managed.toolBridge, globalMCPConfigPath: managed.globalMCPConfigPath)
    }

    /// Terminates every managed CLI process owned by this runtime instance —
    /// and everything each one forked. The roots are handed to
    /// `ProcessTree.terminateAll` together so quitting with many sessions open
    /// pays one grace period, not one per session; the FIFO/bridge release
    /// still loops per session since that part is cheap and per-session state.
    func terminateAll() {
        lock.lock()
        let sessions = managedProcesses
        managedProcesses.removeAll()
        pendingSessions.removeAll()
        lock.unlock()

        for managed in sessions.values {
            managed.stdinPipe.fileHandleForWriting.closeFile()
        }
        ProcessTree.terminateAll(sessions.values.map { $0.process })
        for managed in sessions.values {
            Self.releaseBridge(tool: managed.toolBridge, globalMCPConfigPath: managed.globalMCPConfigPath)
        }
    }

    /// Terminates every managed CLI process across all runtime instances.
    /// Called at app quit so no orphaned `claude` processes outlive the app.
    static func terminateAllProcesses() {
        globalLock.lock()
        let instances = allInstances.compactMap { $0.instance }
        globalLock.unlock()

        for instance in instances {
            instance.terminateAll()
        }
    }

    /// Hands the app-wide MCP servers as they are in Settings now to every
    /// live runtime. Sessions already running keep the config they spawned
    /// with; the next one each runtime spawns uses these.
    static func broadcastGlobalMCPServers(_ servers: [String: ClaudeMCPServerEntry]) {
        let instances = globalLock.withLock { allInstances.compactMap { $0.instance } }
        for instance in instances {
            instance.replaceGlobalMCPServers(servers)
        }
    }

    /// Replaces the app-wide MCP servers this runtime hands to the sessions it
    /// spawns from now on.
    func replaceGlobalMCPServers(_ servers: [String: ClaudeMCPServerEntry]) {
        globalMCPLock.withLock { globalMCPServers = servers }
    }

}

// MARK: - Turns the session starts on its own

extension ClaudeCodeCLIRuntime {
    func unpromptedTurns(of session: AgentSession) -> AsyncStream<AsyncStream<StreamEvent>> {
        let (turns, continuation) = AsyncStream<AsyncStream<StreamEvent>>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        let sessionID = session.id
        let replaced = lock.withLock {
            let old = unpromptedTurnListeners[sessionID]
            unpromptedTurnListeners[sessionID] = (token, continuation)
            return old
        }
        replaced?.continuation.finish()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if self.unpromptedTurnListeners[sessionID]?.token == token {
                    self.unpromptedTurnListeners.removeValue(forKey: sessionID)
                }
            }
        }
        return turns
    }

    /// A turn the CLI started by itself: a stream of its own, opened with
    /// what was held for it and then `event`, becomes the session's sink until
    /// its `result`, and goes to the listener.
    private func openUnpromptedTurn(with event: StreamEvent, sessionID: String) {
        let (turn, continuation) = AsyncStream<StreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let generation = registerContinuation(continuation, sessionID: sessionID)
        continuation.yield(event)
        let listener = lock.withLock { unpromptedTurnListeners[sessionID]?.continuation }
        msgLog.info("[stdout-reader] \(sessionID.prefix(8), privacy: .public): the CLI started a turn by itself gen=\(generation)")
        guard let listener, case .enqueued = listener.yield(turn) else {
            // Nobody took it after all: the turn runs unheard to its result.
            continuation.finish()
            return
        }
    }

    /// Makes `continuation` the session's sink and runs `write`, which sends
    /// the prompt its turn answers — unless a turn the CLI started by itself
    /// is still open, in which case both wait for that turn's `result`.
    ///
    /// The check and the registration are one locked step: an unprompted
    /// turn opening in between would otherwise be handed to this send's
    /// stream, and its `result` would end the send's turn before the reply.
    func registerOrDefer(
        _ continuation: AsyncStream<StreamEvent>.Continuation,
        sessionID: String,
        write: @escaping @Sendable () -> Void
    ) {
        let installed: (UInt64, AsyncStream<StreamEvent>.Continuation?)? = lock.withLock {
            guard unpromptedTurnTrackers[sessionID]?.isOpen == true else {
                return installContinuationLocked(continuation, sessionID: sessionID)
            }
            deferredSends[sessionID, default: []].append(DeferredSend(continuation: continuation, write: write))
            return nil
        }
        guard let installed else {
            msgLog.info("[send] \(sessionID, privacy: .public): waiting for the turn the CLI started by itself")
            return
        }
        let (generation, replaced) = installed
        let gen = finishRegistering(continuation, generation: generation, replacing: replaced, sessionID: sessionID)
        msgLog.info("[send] \(sessionID, privacy: .public): registered stdout continuation gen=\(gen)")
        write()
    }

    /// The sends that waited for an unprompted turn, sent in the order they
    /// were made.
    private func release(_ sends: [DeferredSend], sessionID: String) {
        for send in sends {
            registerOrDefer(send.continuation, sessionID: sessionID, write: send.write)
        }
    }

    /// Whether a turn the CLI started by itself is open on `sessionID`.
    /// Internal so a test can wait for the reader to have opened one.
    func hasOpenUnpromptedTurn(for sessionID: String) -> Bool {
        lock.withLock { unpromptedTurnTrackers[sessionID]?.isOpen == true }
    }
}

// MARK: - Between turns

extension StreamEvent {
    /// What this event is to a session with no turn listening — see
    /// `UnpromptedTurnTracker`. Anything the assistant produced opens a turn,
    /// as its `assistant` line would.
    var betweenTurnsLine: BetweenTurnsLine {
        switch self {
        case .system(let subtype, _):
            return .of(type: "system", subtype: subtype)
        case .thinking, .assistantText, .toolUse, .image:
            return .of(type: "assistant", subtype: nil)
        case .result:
            return .result
        default:
            return .other
        }
    }
}

// MARK: - Tool Scope Integration

extension ClaudeCodeCLIRuntime {
    static let baseCLITools: Set<String> = [
        "Bash", "Edit", "Write", "Read", "Glob", "Grep",
        "Monitor", "LSP", "Agent", "WebSearch", "WebFetch",
        "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
        "NotebookEdit", "Workflow"
    ]

    /// An agent's `tools` list *bounds* its scope — it is not a set of additions.
    /// A profile that declares four tools gets four, not four plus everything in
    /// `baseCLITools`. Only an agent that declares nothing falls back to the base
    /// set, so "unconfigured" still means "a usable default" rather than "no tools".
    static func buildProfileScope(from agent: Agent) -> ProfileToolScope {
        let allowed = agent.tools.isEmpty ? baseCLITools : Set(agent.tools)
        return ProfileToolScope(
            allowed: allowed,
            denied: Set(agent.denied),
            policyVersion: "v1"
        )
    }

    /// The permission mode and the denied tools a session is spawned with.
    ///
    /// These flags are the whole of it: the CLI decides every tool call from
    /// the mode and the denied list it was spawned with, and Kiteloop is not
    /// asked. An attended session runs in the agent's configured mode. An
    /// unattended one — an autopilot run's worker or reviewer, or a one-shot
    /// helper — runs in `auto` mode, where Claude Code's classifier decides each
    /// call. Every session carries `--permission-prompts none`: a `--print`
    /// session has nobody to answer a prompt, so whatever would ask is refused.
    /// The agent's own `denied` tools are refused in every mode. What bounds a
    /// run beyond that is the worktree, the gate and a person.
    static func permissionArguments(agent: Agent, unattended: Bool) -> [String] {
        var args = ["--permission-mode", unattended ? "auto" : agent.permissionMode,
                    "--permission-prompts", "none"]
        if !agent.denied.isEmpty {
            args += ["--disallowedTools", agent.denied.joined(separator: ",")]
        }
        return args
    }

    static func buildAllowedToolsArgs(from scope: ResolvedToolScope) -> [String] {
        guard !scope.effective.isEmpty else { return [] }
        return ["--allowedTools", scope.effective.sorted().joined(separator: ",")]
    }

    /// Appends a session's `--mcp-config` flags: the tool bridge's, then the
    /// globally configured servers', then the agent's own — last wins in the
    /// CLI, so a project entry still overrides a global one of the same name.
    /// The global servers are written to a session-scoped file named through
    /// `SessionTempFiles`, and their tools allowed through under the agent's own
    /// `mcpServers` filter; its path comes back so teardown removes it with the
    /// session's other scratch files. Nil when there is no global server to hand
    /// over, in which case the arguments are exactly what they were before.
    func appendMCPConfigArguments(
        sessionID: String,
        agent: Agent,
        toolBridgeConfigPath: String?,
        to args: inout [String]
    ) -> String? {
        var mcpConfigs: [String] = []
        if let toolBridgeConfigPath { mcpConfigs.append(toolBridgeConfigPath) }
        let globalPath = writeGlobalMCPConfig(sessionID: sessionID)
        if let globalPath {
            Self.allowTools(Self.mcpServerAllowances(forConfigAt: globalPath, allowing: agent.mcpServers), in: &args)
            mcpConfigs.append(globalPath)
        }
        if let mcpPath = agent.mcpConfigPath { mcpConfigs.append(mcpPath) }
        for configPath in mcpConfigs {
            args += ["--mcp-config", configPath]
        }
        return globalPath
    }

    /// Writes the app-wide MCP servers to this session's own config file.
    /// Nil when there are none, or when the file could not be written — the
    /// session then spawns without them rather than not at all.
    private func writeGlobalMCPConfig(sessionID: String) -> String? {
        let servers = globalMCPLock.withLock { globalMCPServers }
        guard !servers.isEmpty else { return nil }
        let path = SessionTempFiles.path(for: .globalMCPConfig, sessionID: sessionID)
        guard let data = try? JSONEncoder().encode(ClaudeMCPConfig(mcpServers: servers)),
              FileManager.default.createFile(atPath: path, contents: data) else { return nil }
        return path
    }

    /// The `mcp__<name>__*` allowance for every server in an agent's MCP config
    /// — including one Kiteloop cannot model as a stdio command, whose tools the
    /// CLI still exposes. Empty when there is no readable config at that path.
    /// `allowing` is the agent's declared `mcpServers`: empty or containing `*`
    /// keeps every server, otherwise only the servers it names.
    static func mcpServerAllowances(forConfigAt path: String, allowing: [String] = []) -> [String] {
        guard let config = ClaudeMCPConfig.load(from: path) else { return [] }
        let names = allowing.isEmpty || allowing.contains("*")
            ? Array(config.mcpServers.keys)
            : allowing.filter { config.mcpServers[$0] != nil }
        return names.map { "mcp__\($0)__*" }
    }

    /// Adds bridge/MCP tool names to `--allowedTools`, writing the flag if it is absent.
    /// A narrow `tools` list can resolve to an empty scope and so to no flag at all;
    /// the bridges still have to reach the CLI.
    static func allowTools(_ names: [String], in args: inout [String]) {
        guard !names.isEmpty else { return }
        if let idx = args.firstIndex(of: "--allowedTools"), idx + 1 < args.count {
            var tools = Set(args[idx + 1].components(separatedBy: ","))
            for name in names { tools.insert(name) }
            args[idx + 1] = tools.sorted().joined(separator: ",")
        } else {
            args += ["--allowedTools", names.sorted().joined(separator: ",")]
        }
    }
}
