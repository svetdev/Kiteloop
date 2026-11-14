import Foundation
import KiteloopCore
import os.log

private let sessionLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "project-session")

/// App-level dependencies a project session needs to build and run its agents.
/// Owned by KiteloopApp, passed through MainWindow.
struct ProjectSessionContext {
    let runtimeFactory: () -> any AgentRuntime
    let agentCatalogStore: AgentCatalogStore
    let packageResolver: PackageResolver?
    let globalConfigStore: GlobalConfigStore
    let orgManifestLoader: OrgManifestLoader
    let repoCloneService: RepoCloneService
    /// Where the session records approve/reopen transitions (success metric
    /// #3b). Defaulted so a caller that doesn't measure — tests, embedded use —
    /// builds a context unchanged.
    var metricStore: TaskMetricStore?
    /// The pre-run ledger the backlog's queue reading takes its recorded
    /// refusals from. Defaulted for the same reason as `metricStore`: without it
    /// the queue still says how much of it is groomed, only not what the
    /// grounding check and the retry ceiling last refused.
    var groomingLedger: GroomingLedger?
}

/// Everything one open project owns: its orchestrator, per-agent chat view
/// models, stores, and feature view models. MainWindow keeps one of these per
/// open project and stays a thin view layer.
@MainActor
@Observable
final class ProjectSession {
    let project: KiteloopProject
    let projectURL: URL
    let orchestrator: Orchestrator
    let sessionStore: SessionStore
    let knowledgeStore: AgentKnowledgeStore
    let knowledgeIndex: KnowledgeIndex
    let memoryViewModel: MemoryViewModel
    let backlogViewModel: BacklogViewModel
    let traceViewModel: TraceViewModel?
    let activityFeed: ActivityFeedViewModel

    private(set) var chatViewModels: [String: ChatViewModel] = [:]
    var selectedAgentID: String?
    var allSkills: [Skill] = []

    /// Reports user-facing failures (agent start, team save) to the window's alert.
    var onError: ((String) -> Void)?

    private let context: ProjectSessionContext
    private var teamConfigWatcher: TeamConfigWatcher?

    /// Settings → Default Model, for a caller that creates an agent the
    /// project names no model for.
    var appDefaultModel: String? { context.globalConfigStore.config.defaultModel }

    /// Designated initializer. Normally reached through `bootstrap`, which also
    /// resolves the team and starts the agents; kept internal so tests can build
    /// a session without spawning any.
    init(
        project: KiteloopProject,
        projectURL: URL,
        orchestrator: Orchestrator,
        sessionStore: SessionStore,
        knowledgeStore: AgentKnowledgeStore,
        knowledgeIndex: KnowledgeIndex,
        context: ProjectSessionContext
    ) {
        self.project = project
        self.projectURL = projectURL
        self.orchestrator = orchestrator
        self.sessionStore = sessionStore
        self.knowledgeStore = knowledgeStore
        self.knowledgeIndex = knowledgeIndex
        self.context = context

        self.memoryViewModel = MemoryViewModel(memoryManager: orchestrator.memoryManager)
        let backlogVM = BacklogViewModel(globalConfigStore: context.globalConfigStore, notifications: orchestrator.notificationStore)
        // Before the load: the first queue reading is taken during it, and one
        // taken without the ledger would report items a gate has refused as
        // startable until the next reload.
        backlogVM.groomingLedger = context.groomingLedger
        backlogVM.configureWorkflow(configURL: project.backlogWorkflowConfigURL)
        backlogVM.loadForProject(repoPath: projectURL.path(percentEncoded: false))
        if let metricStore = context.metricStore {
            let projectPath = project.rootURL.path(percentEncoded: false)
            let projectName = project.rootURL.lastPathComponent
            backlogVM.configureEscapedDefectTracking(
                store: metricStore,
                projectPath: projectPath,
                projectName: projectName
            )
            backlogVM.configureMergeOutcomeRecording(
                store: metricStore,
                projectPath: projectPath,
                projectName: projectName
            )
        }
        self.backlogViewModel = backlogVM
        self.traceViewModel = orchestrator.traceStore.map { TraceViewModel(store: $0, agentName: Self.traceAgentName(orchestrator), chatTitle: Self.traceChatTitle(sessionStore)) }
        self.activityFeed = ActivityFeedViewModel(eventBus: orchestrator.eventBus, agentName: Self.traceAgentName(orchestrator))

        memoryViewModel.configureLibrarian(
            MemoryLibrarianPass(
                project: project,
                memoryManager: orchestrator.memoryManager,
                runtimeFactory: context.runtimeFactory,
                globalConfigStore: context.globalConfigStore
            ),
            // Read at each pass rather than captured now: a librarian run an hour
            // into a session should see the agents hired during it.
            agents: { [weak orchestrator] in orchestrator?.teamAgents ?? [] }
        )
    }

    // MARK: - Bootstrap

    /// Builds a fully started session for a project: resolves the team, starts
    /// every agent, and wires the feature view models. This is the code that
    /// previously lived inline in MainWindow.openProjectAt.
    static func bootstrap(
        project: KiteloopProject,
        url: URL,
        context: ProjectSessionContext,
        selectedPermissionMode: String?,
        repoStatusStore: RepoStatusStore?,
        onError: ((String) -> Void)? = nil
    ) async -> ProjectSession {
        let knowledgeBaseURL = context.packageResolver?.scanPaths.first(where: { $0.source == .shared })?.url ?? project.knowledgeURL
        let knowledgeStore = AgentKnowledgeStore(baseURL: knowledgeBaseURL)
        let index = KnowledgeIndex(baseURL: knowledgeBaseURL)
        await index.start()

        let orch = makeOrchestrator(project: project, url: url, context: context, knowledgeStore: knowledgeStore)

        let config = project.loadConfig()
        ProjectContextSeeder(project: project).seedIfNeeded()
        sweepWorktrees(for: project)

        let bootSessionID = UUID().uuidString
        WorkspaceGenerator.sweep(workspacesURL: project.workspacesURL, keeping: bootSessionID)

        let team = resolveBootTeam(
            project: project,
            context: context,
            bootSessionID: bootSessionID,
            repoStatusStore: repoStatusStore,
            onError: onError
        )

        let session = ProjectSession(
            project: project,
            projectURL: url,
            orchestrator: orch,
            sessionStore: SessionStore(projectDir: url),
            knowledgeStore: knowledgeStore,
            knowledgeIndex: index,
            context: context
        )
        session.onError = onError

        let agentsToStart = addTeamAgents(
            team, to: orch, config: config,
            appDefaultEffort: context.globalConfigStore.config.defaultEffort,
            selectedPermissionMode: selectedPermissionMode
        )
        let agentCwd = agentWorkingDirectory(project: project, url: url, context: context)
        await session.startAgents(agentsToStart, cwd: agentCwd)

        if let firstAgent = orch.agents.first {
            session.selectedAgentID = firstAgent.id
        }

        await orch.skillRegistry.reload()
        await orch.skillRegistry.startWatching()
        session.allSkills = await orch.skillRegistry.allSkills()

        orch.setupSubscriptions()
        orch.startSubscriptions()
        orch.scanForIncompleteWorkflows()

        session.teamConfigWatcher = makeTeamConfigWatcher(project: project, url: url, resolver: context.packageResolver)

        return session
    }

    /// The team boot starts: the templates, and for package-resolved agents the
    /// workspace and `mcp.json` each template id runs with.
    struct BootTeam {
        var templates: [AgentTemplate]
        var workspacePaths: [String: String] = [:]
        var mcpConfigPaths: [String: String] = [:]
    }

    /// Builds the project's orchestrator over its own event bus, memory and
    /// skills, and points its hooks, checkpoints, traces, transcripts and
    /// notifications at the project's directories.
    private static func makeOrchestrator(
        project: KiteloopProject,
        url: URL,
        context: ProjectSessionContext,
        knowledgeStore: AgentKnowledgeStore
    ) -> Orchestrator {
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let memoryManager = MemoryManager(project: project, knowledgeProvider: knowledgeStore)
        let skillScanPaths = UITestingSupport.isUITesting ? [] : SkillRegistry.defaultScanPaths(projectSkillsURL: project.skillsURL)
        let commandPaths = UITestingSupport.isUITesting ? [] : SkillRegistry.defaultCommandPaths(projectURL: url)
        let skillRegistry = SkillRegistry(scanPaths: skillScanPaths, commandPaths: commandPaths)
        let orch = Orchestrator(
            runtime: context.runtimeFactory(),
            eventBus: eventBus,
            subscriptionEngine: subscriptionEngine,
            memoryManager: memoryManager,
            skillRegistry: skillRegistry
        )
        orch.configureWorkflowCheckpointing(
            baseURL: project.workflowCheckpointsURL,
            projectName: project.rootURL.lastPathComponent
        )
        orch.configureTracing(tracesURL: project.tracesURL)
        orch.configureRunTranscripts(baseURL: project.runTranscriptsURL)
        orch.configureNotifications(notificationsURL: project.notificationsURL)
        // A store that cannot read or write its file is nobody's project in
        // particular — the settings store is app-wide — so its reports go to the
        // inbox most recently opened, the same one the toolbar bell is showing.
        StoreProblemReporter.shared.configure(notifications: orch.notificationStore)
        #if DEBUG
        KiteloopFileLogger.shared.configure(projectURL: url)
        #endif
        return orch
    }

    /// Reads the project's team file and turns it into the team boot starts,
    /// falling back to the predefined agents when there is no team to read.
    private static func resolveBootTeam(
        project: KiteloopProject,
        context: ProjectSessionContext,
        bootSessionID: String,
        repoStatusStore: RepoStatusStore?,
        onError: ((String) -> Void)?
    ) -> BootTeam {
        sessionLog.info("packageResolver: \(context.packageResolver != nil, privacy: .public), teamConfigURL: \(project.teamConfigURL.path(percentEncoded: false), privacy: .public)")

        switch loadTeamConfig(from: project.teamConfigURL) {
        case .templates(let inlineTemplates):
            // A self-contained team saved at runtime (agents added/edited via the
            // UI or the control API). Full definitions live in the file, so use
            // them directly — no package resolution needed.
            sessionLog.info("using \(inlineTemplates.count, privacy: .public) inline team templates")
            return BootTeam(templates: inlineTemplates)

        case .packages(let teamConfig):
            guard let resolver = context.packageResolver else {
                sessionLog.info("no resolver; fallback to predefined")
                return BootTeam(templates: AgentTemplate.predefined)
            }
            return packageBootTeam(
                config: teamConfig,
                resolver: resolver,
                project: project,
                bootSessionID: bootSessionID,
                repoStatusStore: repoStatusStore
            )

        case .absent:
            let templates = AgentTemplate.predefined
            sessionLog.info("no team config; fallback to predefined: \(templates.count, privacy: .public) templates")
            return BootTeam(templates: templates)

        case .unreadable(let reason):
            // The predefined agents still stand in, but quietly this time looks
            // identical to a project that never had a team — so say which file
            // is broken, both in the log and to the human.
            let templates = AgentTemplate.predefined
            let path = project.teamConfigURL.path(percentEncoded: false)
            sessionLog.error("team config at \(path, privacy: .public) could not be read (\(reason, privacy: .public)); fallback to predefined: \(templates.count, privacy: .public) templates")
            onError?("Couldn't read the team config at \(path): \(reason). Using the predefined agents instead.")
            return BootTeam(templates: templates)
        }
    }

    /// Resolves a package-ref team file against the packages on disk: generates
    /// each agent's workspace, finds its `mcp.json`, and registers its repos.
    static func packageBootTeam(
        config: PackageTeamConfig,
        resolver: PackageResolver,
        project: KiteloopProject,
        bootSessionID: String,
        repoStatusStore: RepoStatusStore?
    ) -> BootTeam {
        let resolved = resolveTeamTemplates(
            config: config,
            resolver: resolver,
            localAgentsURL: project.localAgentsURL
        )
        sessionLog.info("resolved \(resolved.count, privacy: .public) agents from packages")
        let generator = WorkspaceGenerator(project: project, sharedImportsURL: resolver.sharedImportsURL())
        var team = BootTeam(templates: [])
        for (agent, template) in resolved {
            if let wsURL = try? generator.generate(agent: agent, sessionID: bootSessionID) {
                team.workspacePaths[template.id] = wsURL.path(percentEncoded: false)
            }
            let mcpFile = agent.packageURL.appending(path: "mcp.json")
            if FileManager.default.fileExists(atPath: mcpFile.path(percentEncoded: false)) {
                team.mcpConfigPaths[template.id] = mcpFile.path(percentEncoded: false)
            }
            team.templates.append(template)
        }
        if team.templates.isEmpty {
            team.templates = AgentTemplate.predefined
        }
        sessionLog.info("using \(team.templates.count, privacy: .public) package-resolved templates")

        for (agent, _) in resolved {
            if let repos = agent.package.repos, !repos.isEmpty {
                repoStatusStore?.register(agentID: agent.refID, repos: repos)
            }
        }
        return team
    }

    /// Adds an agent to the orchestrator for every template in the team, and
    /// returns each beside the session it resumes.
    private static func addTeamAgents(
        _ team: BootTeam,
        to orch: Orchestrator,
        config: ProjectConfig,
        appDefaultEffort: String?,
        selectedPermissionMode: String?
    ) -> [(Agent, String?)] {
        let tuning = startingTuning(config: config, appDefaultEffort: appDefaultEffort)
        return team.templates.map { template in
            var agent = template.instantiateAgentWithFixedID()
            if takesWelcomeMode(template) {
                agent.permissionMode = selectedPermissionMode ?? Agent.initialPermissionMode(projectConfig: config)
            }
            agent.effort = tuning.effort
            agent.maxBudgetUSD = tuning.maxBudgetUSD
            agent.workspacePath = team.workspacePaths[agent.id]
            agent.mcpConfigPath = team.mcpConfigPaths[agent.id]
            orch.addAgent(agent)
            return (agent, config.agentSessionIDs?[agent.name])
        }
    }

    /// The reasoning effort and per-turn budget an agent starts with: the
    /// project's effort if set, else the app's default, else none — the rule
    /// Project Settings' Effort picker labels its Default entry with — and the
    /// project's budget.
    nonisolated static func startingTuning(
        config: ProjectConfig,
        appDefaultEffort: String?
    ) -> (effort: String?, maxBudgetUSD: Double?) {
        let effort = SettingInheritance.resolve(
            builtIn: "",
            app: SettingInheritance.present(appDefaultEffort),
            project: SettingInheritance.present(config.effort))
        return (SettingInheritance.present(effort.value), config.maxBudgetUSD)
    }

    /// Where the team's agents run: the org's workspaces directory for the home
    /// workspace, which it creates if missing, and the project itself otherwise.
    private static func agentWorkingDirectory(
        project: KiteloopProject,
        url: URL,
        context: ProjectSessionContext
    ) -> URL {
        guard project.isHomeWorkspace else { return url }
        let orgName = context.globalConfigStore.config.githubOrg
        KiteloopProject.ensureWorkspacesDir(orgName: orgName)
        return KiteloopProject.workspacesDir(orgName: orgName)
    }

    /// Spawn every agent concurrently, then build each view model here on the
    /// main actor as its agent comes up. Awaiting each task individually means
    /// one agent failing to start doesn't abandon the others.
    private func startAgents(_ agentsToStart: [(Agent, String?)], cwd agentCwd: URL) async {
        let orch = orchestrator
        let startTasks: [(String, Task<Void, Error>)] = agentsToStart.map { agent, resumeID in
            (agent.id, Task { @MainActor in
                try await orch.startAgent(agent.id, cwd: agentCwd, resumeSessionID: resumeID)
            })
        }
        for (agentID, task) in startTasks {
            do {
                try await task.value
                chatViewModels[agentID] = makeChatViewModel(agentID: agentID, projectURL: agentCwd)
            } catch {
                let name = orch.agents.first { $0.id == agentID }?.name ?? agentID
                onError?("\(name) failed to start in \(projectURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Watches the team file and, when it changes to something that yields a
    /// team, posts `.teamConfigFileChanged` with the new templates.
    private static func makeTeamConfigWatcher(
        project: KiteloopProject,
        url: URL,
        resolver: PackageResolver?
    ) -> TeamConfigWatcher {
        let projID = project.id
        let projURL = url
        let localAgentsURL = project.localAgentsURL
        return TeamConfigWatcher(
            teamConfigURL: project.teamConfigURL
        ) { load in
            // The watcher hands over what the file decoded to, not templates:
            // the package-ref shape only becomes templates once a resolver has
            // looked its refs up, and the resolver is on the main actor.
            Task { @MainActor in
                let newTemplates = liveTemplates(
                    for: load,
                    resolver: resolver,
                    localAgentsURL: localAgentsURL
                )
                guard !newTemplates.isEmpty else { return }
                NotificationCenter.default.post(
                    name: .teamConfigFileChanged,
                    object: nil,
                    userInfo: ["projectID": projID, "projectURL": projURL, "templates": newTemplates]
                )
            }
        }
    }

    /// Whether a team template takes the mode picked on the welcome screen —
    /// or, with none picked, the project's configured one: a template that
    /// names no mode (decoded as `Agent.defaultPermissionMode`) or names
    /// "default". A template that names any other mode keeps it.
    static func takesWelcomeMode(_ template: AgentTemplate) -> Bool {
        [Agent.defaultPermissionMode, "default"].contains(template.permissionMode)
    }

    /// Tidies the project's worktrees directory in the background as the project
    /// opens: prunes registrations whose checkout is gone, and reaps orphaned
    /// worktrees — the ones no run is behind because it crashed, was cancelled,
    /// or outlived the app. Teardown on the happy path is the only thing that
    /// removes a worktree otherwise, and every leftover is a full checkout.
    ///
    /// Open is the right seam for the same reason `AppDelegate` reaps session
    /// FIFOs at launch rather than at quit: `applicationWillTerminate` covers an
    /// orderly quit and nothing else, while a crash or a force quit — the cases
    /// that actually strand a worktree — skip it entirely.
    ///
    /// A project can't have a run in flight before it is open, so nothing is
    /// live to protect here; the guards in `WorktreeManager.orphanVerdict` are
    /// what keep the sweep off anything holding work. Detached because it shells
    /// out to git a few times per worktree, and opening a project shouldn't wait
    /// on that.
    /// Names a trace's agent id as the team named it, looked up at call time
    /// so an agent hired mid-session is named; an id no agent carries stays as is.
    private static func traceAgentName(_ orchestrator: Orchestrator) -> (String) -> String {
        { [weak orchestrator] id in orchestrator?.agents.first { $0.id == id }?.name ?? id }
    }

    /// Names a trace's CLI session id by the chat that carries it, looked up in
    /// the store at call time so a chat titled after the pane opened is named;
    /// nil when no chat carries it.
    static func traceChatTitle(_ store: SessionStore) -> (String) -> String? {
        { [weak store] id in
            guard !id.isEmpty, let store else { return nil }
            return store.sessions.values.lazy.flatMap { $0 }
                .first { $0.claudeSessionID == id }?.title
        }
    }

    private static func sweepWorktrees(for project: KiteloopProject) {
        let manager = WorktreeManager(projectRoot: project.rootURL)
        let name = project.rootURL.lastPathComponent
        let base = BacklogAutopilot.configuredBaseBranch(projectRoot: project.rootURL)
        Task.detached(priority: .utility) {
            let report = await manager.sweep(base: base)
            for line in report.logLines {
                kiteloopLog("[worktrees] \(name): \(line)", category: "runtime")
            }
        }
    }

    /// A team file is one of two shapes: the package-ref `PackageTeamConfig`
    /// object (written by the setup wizard / package system), or the
    /// self-contained `[AgentTemplate]` array that `persistTeamConfig` writes
    /// whenever agents are added or edited at runtime.
    ///
    /// The two remaining cases are the ones that used to be a single `nil`: a
    /// project that has never had a team, and a team file that is there and
    /// won't decode. Both fall back to `AgentTemplate.predefined`, but only the
    /// second is a problem a human needs to hear about — a truncated team.json
    /// silently taking the predefined agents looks exactly like a fresh project.
    ///
    /// Deliberately `nonisolated`: `TeamConfigWatcher` reads the file on its own
    /// background queue, and reading JSON off disk needs no main actor.
    nonisolated enum TeamConfigLoad: Sendable {
        case packages(PackageTeamConfig)
        case templates([AgentTemplate])
        /// No file at all — and also a file that decodes to an empty template
        /// array, which configures no team and is nothing to complain about.
        case absent
        /// The file exists but is not one of the two shapes; `reason` is the
        /// decoder's own account of why.
        case unreadable(reason: String)
    }

    nonisolated static func loadTeamConfig(from url: URL) -> TeamConfigLoad {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(reason: "the file exists but could not be read")
        }
        let decoder = JSONDecoder()
        if let config = try? decoder.decode(PackageTeamConfig.self, from: data) {
            return .packages(config)
        }
        do {
            let templates = try decoder.decode([AgentTemplate].self, from: data)
            return templates.isEmpty ? .absent : .templates(templates)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Turns the package-ref shape of a team file into the templates the app
    /// runs: resolve each ref against the packages on disk, map the package to a
    /// template, then lay the ref's overrides on top.
    ///
    /// Each template comes back beside the `ResolvedAgent` it was made from,
    /// because boot needs the package as well — the workspace it generates and
    /// the `mcp.json` it looks for live there. A live reload takes the templates
    /// alone.
    static func resolveTeamTemplates(
        config: PackageTeamConfig,
        resolver: PackageResolver,
        localAgentsURL: URL
    ) -> [(agent: ResolvedAgent, template: AgentTemplate)] {
        resolver.resolveTeam(config: config, localAgentsURL: localAgentsURL).map { agent in
            var template = agent.package.toAgentTemplate(id: agent.refID)
            if let overrides = agent.overrides {
                if let m = overrides.model { template.model = m }
                if let t = overrides.tools { template.tools = t }
                if let d = overrides.denied { template.denied = d }
                if let p = overrides.permissionMode { template.permissionMode = p }
                if let mc = overrides.mcpServers { template.mcpServers = mc }
                if let s = overrides.skills { template.skills = s }
            }
            return (agent, template)
        }
    }

    /// What an external edit to team.json means for a project that is already
    /// open — the templates its team should be synced to, in either of the file's
    /// two shapes.
    ///
    /// `.absent` and `.unreadable` resolve to nothing on purpose. Boot answers
    /// those with the predefined agents and, for the unreadable one, tells the
    /// human; doing the same to a live project would fire the whole predefined
    /// team at it the moment someone's editor wrote a half-saved file.
    static func liveTemplates(
        for load: TeamConfigLoad,
        resolver: PackageResolver?,
        localAgentsURL: URL
    ) -> [AgentTemplate] {
        switch load {
        case .templates(let inlineTemplates):
            return inlineTemplates
        case .packages(let config):
            guard let resolver else { return [] }
            return resolveTeamTemplates(
                config: config,
                resolver: resolver,
                localAgentsURL: localAgentsURL
            ).map(\.template)
        case .absent, .unreadable:
            return []
        }
    }

    // MARK: - Chat View Models

    /// The agent's chat, made on first ask and kept: what the control API's
    /// message endpoint delivers into, so a phone and the Mac read one
    /// conversation.
    func chatViewModel(for agentID: String) -> ChatViewModel {
        if let existing = chatViewModels[agentID] { return existing }
        let vm = makeChatViewModel(agentID: agentID, projectURL: project.rootURL)
        chatViewModels[agentID] = vm
        return vm
    }

    /// Builds a configured ChatViewModel for an agent — the one place this
    /// wiring lives (previously copy-pasted at six call sites).
    func makeChatViewModel(agentID: String, projectURL: URL? = nil) -> ChatViewModel {
        let vm = ChatViewModel(agentID: agentID, projectURL: projectURL ?? self.projectURL, orchestrator: orchestrator)
        vm.configure(
            catalogStore: context.agentCatalogStore,
            knowledgeIndex: knowledgeIndex,
            globalConfigStore: context.globalConfigStore
        )
        // An aside's chat lives in memory only: no session record, no
        // messages.json under `.kiteloop/sessions/`. Without a session the
        // save/load paths short-circuit, which is what "dies with the app"
        // means — otherwise every aside would leave a directory behind that
        // nothing ever reaps.
        if orchestrator.agents.first(where: { $0.id == agentID })?.isAside != true {
            vm.setupSessionStore(sessionStore)
        }
        return vm
    }

    /// Starts a new chat with the selected agent — what the sidebar's + and
    /// File > New Chat both do. Nothing when no agent is selected or it has
    /// no chat yet.
    func startNewChatForSelectedAgent() async {
        guard let selectedAgentID, let vm = chatViewModels[selectedAgentID] else { return }
        await vm.startNewChat()
    }

    func registerChatViewModel(_ vm: ChatViewModel, for agentID: String) {
        chatViewModels[agentID] = vm
    }

    // MARK: - Agent Lifecycle

    @discardableResult
    func addAgent(
        name: String,
        model: String,
        permissionMode: String,
        avatar: String? = nil,
        runtimeKind: String? = nil,
        systemPrompt: String? = nil,
        tools: [String]? = nil,
        denied: [String]? = nil,
        askFirst: [String] = [],
        mcpServers: [String]? = nil,
        skills: [String]? = nil,
        select: Bool = true
    ) -> String {
        var agent = Agent(
            id: UUID().uuidString,
            name: name,
            model: model,
            systemPrompt: systemPrompt ?? "You are a senior developer. Write clean, testable code.",
            tools: tools ?? ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "ask_human", "recall_knowledge", "save_knowledge"],
            denied: denied ?? [],
            permissionMode: permissionMode,
            mcpServers: mcpServers ?? [],
            skills: skills ?? [],
            avatar: avatar,
            runtimeKind: runtimeKind,
            state: .idle
        )
        let tuning = Self.startingTuning(
            config: project.loadConfig(),
            appDefaultEffort: context.globalConfigStore.config.defaultEffort
        )
        agent.effort = tuning.effort
        agent.maxBudgetUSD = tuning.maxBudgetUSD
        agent.askFirst = askFirst
        orchestrator.addAgent(agent)
        persistTeamConfig()
        Task {
            do {
                try await orchestrator.startAgent(agent.id, cwd: project.rootURL)
            } catch {
                onError?("Couldn't start \(agent.name): \(error.localizedDescription)")
                return
            }
            // A message sent the moment the hire answered has already made
            // this agent's chat and is running a turn in it: that chat stays.
            if chatViewModels[agent.id] == nil {
                chatViewModels[agent.id] = makeChatViewModel(agentID: agent.id, projectURL: project.rootURL)
            }
            // Skipped for API-hired agents so they don't yank the user's view
            // (e.g. off the Autopilot screen) to the new agent's chat.
            if select { selectedAgentID = agent.id }
        }
        return agent.id
    }

    func stopAgent(_ agentID: String) {
        orchestrator.stopAgent(agentID)
        chatViewModels.removeValue(forKey: agentID)
        if selectedAgentID == agentID {
            selectedAgentID = orchestrator.agents.first?.id
        }
    }

    /// Starts a stopped agent in the project. An agent that is already running
    /// is left alone; a start that fails is reported through onError, naming
    /// the agent. Not routed through `restartAgent`, which stops first.
    func startAgent(_ agentID: String) {
        guard !orchestrator.hasSession(for: agentID) else { return }
        Task {
            do {
                try await orchestrator.startAgent(agentID, cwd: project.rootURL)
            } catch {
                let name = orchestrator.agents.first(where: { $0.id == agentID })?.name ?? agentID
                onError?("Couldn't start \(name): \(error.localizedDescription)")
            }
        }
    }

    /// Stops the agent's session and starts it again, so values read at spawn
    /// time take effect. A start that fails is reported through onError rather
    /// than leaving the agent stopped in silence.
    func restartAgent(_ agentID: String) {
        orchestrator.stopAgent(agentID)
        Task {
            do {
                try await orchestrator.startAgent(agentID, cwd: project.rootURL)
            } catch {
                let name = orchestrator.agents.first(where: { $0.id == agentID })?.name ?? agentID
                onError?("Couldn't restart \(name): \(error.localizedDescription)")
            }
        }
    }

    func removeAgent(_ agentID: String) {
        orchestrator.removeAgent(agentID)
        chatViewModels.removeValue(forKey: agentID)
        if selectedAgentID == agentID {
            selectedAgentID = orchestrator.agents.first?.id
        }
        persistTeamConfig()
    }

    /// Stops every agent and releases the session's watchers; called when the
    /// project tab closes. The knowledge store holds a descriptor and a live
    /// kevent registration on `knowledge/agents` — without this, opening and
    /// closing projects leaks one of each per open, for the life of the process.
    /// The event subscriptions leak the same way: stopping an agent's session
    /// leaves it subscribed, so the watch task and the `EventBus` behind it
    /// outlive the tab unless `stopSubscriptions()` drops them.
    func shutdown() {
        for agent in orchestrator.agents {
            orchestrator.stopAgent(agent.id)
        }
        orchestrator.stopSubscriptions()
        knowledgeStore.stop()
    }

    // MARK: - Team Config

    /// Writes the current live team back to team.json. Failures surface via
    /// onError — a silent failure here means agent edits vanish on restart.
    func persistTeamConfig() {
        let configManager = TeamConfigManager(project: project)
        let templates = orchestrator.teamAgents.map { AgentTemplate(from: $0) }
        do {
            try configManager.saveTeam(templates)
        } catch {
            sessionLog.error("Failed to save team config for \(self.project.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?("Couldn't save the team configuration: \(error.localizedDescription)")
        }
    }

    func toggleSkillAssignment(skill: Skill, agentID: String) {
        let qualifiedName = skill.qualifiedName
        orchestrator.updateAgent(id: agentID) { agent in
            if agent.skills.contains(qualifiedName) {
                agent.skills.removeAll { $0 == qualifiedName }
            } else {
                agent.skills.append(qualifiedName)
            }
        }
        persistTeamConfig()
    }

    /// Reconciles the live team with templates from a team.json file change.
    func syncTeamFromConfig(templates: [AgentTemplate], projectURL: URL) {
        let currentIDs = Set(orchestrator.agents.map(\.id))
        let templateIDs = Set(templates.map(\.id))

        // Add agents that exist in config but not in orchestrator
        let toAdd = templates.filter { !currentIDs.contains($0.id) }
        for template in toAdd {
            let agent = template.instantiateAgentWithFixedID()
            orchestrator.addAgent(agent)

            Task { @MainActor in
                do {
                    try await orchestrator.startAgent(agent.id, cwd: projectURL)
                } catch {
                    onError?("Couldn't start \(agent.name): \(error.localizedDescription)")
                    return
                }
                if chatViewModels[agent.id] == nil {
                    chatViewModels[agent.id] = makeChatViewModel(agentID: agent.id, projectURL: projectURL)
                }
                // A change on disk is not something the user asked to look at:
                // select the newcomer only when nothing is selected.
                if selectedAgentID == nil {
                    selectedAgentID = agent.id
                }
            }
        }

        // Remove agents that no longer exist in config. Asides are never in it
        // — they're ephemeral by design — so they're exempt from the reap
        // rather than swept away by the next edit to team.json.
        let toRemove = orchestrator.teamAgents.filter { !templateIDs.contains($0.id) }
        for agent in toRemove {
            orchestrator.removeAgent(agent.id)
            chatViewModels.removeValue(forKey: agent.id)
            if selectedAgentID == agent.id {
                selectedAgentID = orchestrator.agents.first?.id
            }
        }
    }

    // MARK: - Hire / Summon

    func handleAgentHired(_ agent: Agent, projectURL: URL) {
        chatViewModels[agent.id] = makeChatViewModel(agentID: agent.id, projectURL: projectURL)
        selectedAgentID = agent.id
        persistTeamConfig()
    }

    func handleAgentFired(_ agentID: String) {
        chatViewModels.removeValue(forKey: agentID)
        if selectedAgentID == agentID {
            selectedAgentID = orchestrator.agents.first?.id
        }
    }

    /// Opens the summoned agent's chat and sends it the message it was summoned
    /// with, through the tray so the files go with it.
    func handleAgentSummoned(_ agent: Agent, projectURL: URL, initialMessage: String,
                             attachments: [ChatAttachment] = []) {
        let vm = makeChatViewModel(agentID: agent.id, projectURL: projectURL)
        chatViewModels[agent.id] = vm
        selectedAgentID = agent.id

        guard !initialMessage.trimmingCharacters(in: .whitespaces).isEmpty || !attachments.isEmpty else { return }
        vm.inputText = initialMessage
        vm.pendingAttachments = attachments
        Task { await vm.send() }
    }
}
