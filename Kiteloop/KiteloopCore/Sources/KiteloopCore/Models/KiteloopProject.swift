import Foundation

package struct KiteloopProject: Identifiable {
    package let id: String
    package let rootURL: URL

    package init(rootURL: URL) {
        // Canonicalize identity so the same folder always yields one id. NSOpenPanel
        // returns directory URLs with a trailing slash while restored bookmarks and
        // recents often don't — without this, opening a project both ways created two
        // identities (and two Portfolio cards). `rootURL` is left as-is for file I/O.
        self.id = KiteloopProject.canonicalPath(rootURL.path(percentEncoded: false))
        self.rootURL = rootURL
    }

    /// Strips trailing slashes so directory paths compare equal regardless of
    /// how the URL was constructed.
    package static func canonicalPath(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Whether two stored paths name the same project. The one spelling of
    /// "is this row mine?" every project-scoped ledger read uses, so a project
    /// opened as `/Users/me/repo/` reads rows a run recorded as `/Users/me/repo`.
    /// Canonicalisation is the whole rule: nothing here resolves symlinks,
    /// expands `~`, case-folds or touches the filesystem.
    package static func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    package static var homeWorkspace: KiteloopProject {
        let home = KiteloopHome.url
        return KiteloopProject(rootURL: home.appending(path: ".kiteloop/home"))
    }

    package var isHomeWorkspace: Bool {
        id == Self.homeWorkspace.id
    }

    package static func workspacesDir(orgName: String? = nil) -> URL {
        let name = orgName ?? "default"
        return KiteloopHome.url.appending(path: ".kiteloop/workspaces/\(name)")
    }

    package static func ensureWorkspacesDir(orgName: String? = nil) {
        let dir = workspacesDir(orgName: orgName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let claudeMD = dir.appending(path: "CLAUDE.md")
        if !fm.fileExists(atPath: claudeMD.path(percentEncoded: false)) {
            let label = orgName ?? "Project"
            let content = """
            # \(label) Workspaces

            Each subdirectory is a cloned repo. Only access repos within this directory.
            """
            try? content.write(to: claudeMD, atomically: true, encoding: .utf8)
        }
    }

    package var kiteloopDirURL: URL { rootURL.appending(path: ".kiteloop") }
    package var configURL: URL { kiteloopDirURL.appending(path: "config.json") }
    package var eventsURL: URL { kiteloopDirURL.appending(path: "events.jsonl") }
    package var costsURL: URL { kiteloopDirURL.appending(path: "costs.jsonl") }
    package var logsURL: URL { kiteloopDirURL.appending(path: "logs") }
    package var agentsURL: URL { kiteloopDirURL.appending(path: "agents") }
    package var contextURL: URL { kiteloopDirURL.appending(path: "context.md") }
    package var teamConfigURL: URL { kiteloopDirURL.appending(path: "team.json") }
    package var autopilotConfigURL: URL { kiteloopDirURL.appending(path: "autopilot-config.json") }
    package var autopilotHistoryURL: URL { kiteloopDirURL.appending(path: "autopilot-history.json") }
    package var backlogWorkflowConfigURL: URL { kiteloopDirURL.appending(path: "backlog-workflow.json") }
    /// The repo-level path glob → verify command map (`VerifyCoverage.Map`),
    /// tracked at the repository root so it is reviewed and a fresh clone has it.
    /// Optional: absent means a run's diff is not checked for coverage at all.
    /// Read through `VerifyMapFile.load(for:)`, which falls back to
    /// `legacyVerifyMapURL`.
    package var verifyMapURL: URL { rootURL.appending(path: "kiteloop-verify.json") }
    /// Where the map lived before it was tracked: gitignored, so unreviewed and
    /// absent from a fresh clone. Still read when the root file is absent.
    package var legacyVerifyMapURL: URL { kiteloopDirURL.appending(path: "verify-map.json") }
    package var notificationsURL: URL { kiteloopDirURL.appending(path: "notifications.log") }
    package var skillsURL: URL { kiteloopDirURL.appending(path: "skills") }
    package var workflowCheckpointsURL: URL { kiteloopDirURL.appending(path: "checkpoints") }
    package var tracesURL: URL { kiteloopDirURL.appending(path: "traces") }
    /// One directory per autopilot run, holding that run's transcript — see
    /// `RunTranscriptStore`. Kept separate from `sessions/`, which is the agent's
    /// rolling chat and is overwritten as it works.
    package var runTranscriptsURL: URL { kiteloopDirURL.appending(path: "transcripts") }
    package var knowledgeURL: URL { kiteloopDirURL.appending(path: "knowledge") }
    package var workspacesURL: URL { kiteloopDirURL.appending(path: "workspaces") }
    /// Scratch space for the web preview pane — screenshots agents capture and
    /// then `Read` back. Gitignored (see `requiredGitignoreEntries`).
    package var webURL: URL { kiteloopDirURL.appending(path: "web") }
    package var teamLockURL: URL { kiteloopDirURL.appending(path: "team.lock.json") }
    /// When the memory librarian last read this project's corpus, and what it
    /// found — see `MemoryLibrarianPass.State`. Absent means never.
    package var memoryLibrarianStateURL: URL { kiteloopDirURL.appending(path: "memory-librarian.json") }
    package var localAgentsURL: URL { kiteloopDirURL.appending(path: "agents") }

    package func agentDir(for agentID: String) -> URL {
        agentsURL.appending(path: agentID)
    }

    package func ensureKiteloopDirectory() throws {
        try ensureDirectoryExists()
    }

    package func ensureDirectoryExists() throws {
        let fm = FileManager.default
        for dir in [kiteloopDirURL, agentsURL, knowledgeURL, workspacesURL] {
            if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        ensureKiteloopGitignored()
    }

    /// Subdirectories that must never be committed, even in projects that
    /// deliberately track parts of `.kiteloop/`: `worktrees/` holds checked-out
    /// git worktrees, `web/` holds web preview scratch output (screenshots), and
    /// `backlog-tree/` is the private checkout of the shared backlog branch
    /// (`BacklogBranch.checkoutComponent`) — a linked worktree living inside the
    /// project root, so an unignored one leaves the tree permanently dirty and
    /// every auto-merge refusing.
    package static let requiredGitignoreEntries = [
        ".kiteloop/worktrees/", ".kiteloop/web/", ".kiteloop/backlog-tree/",
    ]

    private func ensureKiteloopGitignored() {
        let gitignoreURL = rootURL.appending(path: ".gitignore")
        let fm = FileManager.default
        let gitignoreExists = fm.fileExists(atPath: gitignoreURL.path(percentEncoded: false))
        // A directory that isn't a git repo (the home workspace, a plain folder) is left
        // alone even without a .gitignore; a repo with none gets one seeded from scratch.
        guard gitignoreExists || isGitRepository else { return }
        let original: Data
        if gitignoreExists {
            guard let existing = try? Data(contentsOf: gitignoreURL) else { return }
            original = existing
        } else {
            original = Data()
        }
        // Decide from the lenient text, but write back the original bytes, so a
        // byte that is not UTF-8 stays as it was rather than being re-encoded.
        let contents = String(decoding: original, as: UTF8.self)
        guard let addition = Self.gitignoreAddition(for: contents) else { return }
        let separator = contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n"
        try? (original + Data((separator + addition).utf8)).write(to: gitignoreURL, options: .atomic)
    }

    /// The same plain existence test `RepoCloneService` uses: a `.git` entry under
    /// `rootURL`, covering both a directory and the file a linked worktree carries.
    private var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: rootURL.appending(path: ".git").path(percentEncoded: false))
    }

    /// Lines to append to a project `.gitignore` so Kiteloop's runtime state stays
    /// untracked, or nil when it already is.
    ///
    /// A project that hasn't heard of Kiteloop gets the blanket `.kiteloop/`. A project
    /// that already ignores all of `.kiteloop/` is left alone. A project that ignores
    /// only parts of it (tracking e.g. `team.json`) keeps its own patterns — blanket-
    /// ignoring there would defeat its negations — so only the entries in
    /// `requiredGitignoreEntries` are forced.
    package static func gitignoreAddition(for contents: String) -> String? {
        var ignored: Set<String> = []
        var mentionsKiteloop = false
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let negated = line.hasPrefix("!")
            let pattern = normalizedGitignorePattern(negated ? String(line.dropFirst()) : line)
            guard pattern == ".kiteloop" || pattern.hasPrefix(".kiteloop/") else { continue }
            mentionsKiteloop = true
            if !negated { ignored.insert(pattern) }
        }
        // `.kiteloop`, `.kiteloop/` and `.kiteloop/*` all normalize to ".kiteloop" and
        // all cover every subdirectory, negations for direct children aside.
        if ignored.contains(".kiteloop") { return nil }
        let missing = requiredGitignoreEntries.filter { !ignored.contains(normalizedGitignorePattern($0)) }
        if missing.isEmpty { return nil }
        return mentionsKiteloop ? missing.joined(separator: "\n") + "\n" : ".kiteloop/\n"
    }

    /// Reduces a gitignore pattern to a comparable path: anchoring slashes and a
    /// trailing `/` or `/*` don't change which of our directories it covers.
    private static func normalizedGitignorePattern(_ pattern: String) -> String {
        var p = pattern
        if p.hasSuffix("/*") { p.removeLast(2) }
        while p.hasSuffix("/") { p.removeLast() }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    // MARK: - Parked state and goal

    /// Whether a human has parked this project. Unset reads as running: a
    /// project nobody has touched is a live one, never a parked one.
    ///
    /// This is a hard stop rather than a hint — `PortfolioSnapshot.
    /// selectableProjects` drops parked projects before any persona is given a
    /// choice to reason about, so no amount of coordinator reasoning can put
    /// work on one.
    package var isPaused: Bool { loadConfig().paused ?? false }

    /// The human's one-paragraph statement of what this project is for. Nil when
    /// nothing is stated, which is a legitimate state rather than an error.
    package var goal: String? { Self.normalizedStatement(loadConfig().goal) }

    /// Write both together — they are edited together in the Portfolio and this
    /// keeps a save of one from racing a stale read of the other. Every other
    /// field of the project's config is preserved.
    package func setPaused(_ paused: Bool, goal: String?) throws {
        var config = loadConfig()
        config.paused = paused
        config.goal = Self.normalizedStatement(goal)
        try FileManager.default.createDirectory(at: kiteloopDirURL, withIntermediateDirectories: true)
        try saveConfig(config)
    }

    /// A stated goal, trimmed; whitespace-only is nothing stated, so it collapses
    /// to nil rather than persisting an empty string.
    package static func normalizedStatement(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the reporter's dedup key, so it is spelled once.
    package static let configStoreName = "Project Config"

    package func loadConfig(reporter: StoreProblemReporter = .shared) -> ProjectConfig {
        // A config the decoder refuses is kept, not dropped: `try?` here read a
        // truncated file as "no config at all", and the next `saveConfig` wrote
        // the defaults over it for good.
        guard let config = QuarantiningJSONFile.load(ProjectConfig.self,
                                                      from: configURL,
                                                      store: Self.configStoreName,
                                                      reporter: reporter) else {
            return .default
        }
        return config
    }

    package func saveConfig(_ config: ProjectConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try AtomicFileWriter.write(data, to: configURL)
    }
}

package struct ProjectConfig: Codable {
    package var model: String?
    package var permissionMode: String
    package var deniedTools: [String]
    /// Claude CLI session ID per agent name, for resume across app restarts.
    package var agentSessionIDs: [String: String]?
    package var claudeCodeVersion: String?
    package var effort: String?
    package var maxBudgetUSD: Double?
    package var observability: OTLPConfig?
    package var bedrock: BedrockConfig?
    /// Whether a human has parked this project: nothing is picked up for it
    /// unattended until it is unparked. Nil — nothing ever said — is a running
    /// project, so silence never reads as parked.
    package var paused: Bool?
    /// The human's statement of what this project is for, read by the
    /// coordinator. Nil means nothing stated.
    package var goal: String?
    /// Directories appended, after the global ones, to the executable search
    /// path this project's verify commands and agents run with
    /// (`ExecutableSearchPath`). Entries may be written with `~`. Nil means
    /// the project adds nothing.
    package var extraExecutablePaths: [String]?
    /// Variables exported into every verify shell and agent spawn on this
    /// project's behalf, on top of the defaults `BuildEnvironment` derives
    /// from the tree (a `Cargo.toml` shares one cargo target directory across
    /// item worktrees). An entry here wins over a derived one; a value may
    /// carry `~` and `$PROJECT_ROOT`; `PATH` is ignored — it is
    /// `extraExecutablePaths`'s. Nil means the project adds nothing.
    package var buildEnvironment: [String: String]?
    /// One file of the project, by its path from the project's root, that the
    /// phone shows first when the project is opened — the brief an agent
    /// writes each morning. Nil pins nothing.
    package var pinnedDocument: String?

    /// What a pinned-document field holds: the path trimmed, or nil for one
    /// left empty.
    package static func pinnedPath(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    package static let `default` = ProjectConfig(
        model: nil,
        permissionMode: "auto",
        deniedTools: [],
        agentSessionIDs: nil,
        claudeCodeVersion: nil,
        effort: nil,
        maxBudgetUSD: nil,
        observability: nil,
        bedrock: nil,
        paused: nil,
        goal: nil,
        extraExecutablePaths: nil,
        buildEnvironment: nil
    )

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(model: String? = nil, permissionMode: String, deniedTools: [String], agentSessionIDs: [String: String]? = nil, claudeCodeVersion: String? = nil, effort: String? = nil, maxBudgetUSD: Double? = nil, observability: OTLPConfig? = nil, bedrock: BedrockConfig? = nil, paused: Bool? = nil, goal: String? = nil, extraExecutablePaths: [String]? = nil, buildEnvironment: [String: String]? = nil) {
        self.model = model
        self.permissionMode = permissionMode
        self.deniedTools = deniedTools
        self.agentSessionIDs = agentSessionIDs
        self.claudeCodeVersion = claudeCodeVersion
        self.effort = effort
        self.maxBudgetUSD = maxBudgetUSD
        self.observability = observability
        self.bedrock = bedrock
        self.paused = paused
        self.goal = goal
        self.extraExecutablePaths = extraExecutablePaths
        self.buildEnvironment = buildEnvironment
    }

    private enum CodingKeys: String, CodingKey {
        case model, permissionMode, deniedTools, agentSessionIDs
        case claudeCodeVersion, effort, maxBudgetUSD, observability, bedrock
        case paused, goal, extraExecutablePaths, buildEnvironment, pinnedDocument
    }

    /// The key this config used to carry, kept only so `init(from:)` can read a
    /// file written before the dial became a switch. Separate from
    /// `CodingKeys` because nothing stores it and nothing writes it back: a
    /// config saved once loses the old key.
    private enum LegacyKeys: String, CodingKey {
        case priority
    }

    /// Spelled out rather than synthesised for one reason: `paused` falls back
    /// to the legacy `priority` string when it is absent, so a project a human
    /// parked before this change stays parked across the upgrade.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decode(String.self, forKey: .permissionMode)
        deniedTools = try c.decode([String].self, forKey: .deniedTools)
        agentSessionIDs = try c.decodeIfPresent([String: String].self, forKey: .agentSessionIDs)
        claudeCodeVersion = try c.decodeIfPresent(String.self, forKey: .claudeCodeVersion)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        maxBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .maxBudgetUSD)
        observability = try c.decodeIfPresent(OTLPConfig.self, forKey: .observability)
        bedrock = try c.decodeIfPresent(BedrockConfig.self, forKey: .bedrock)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        extraExecutablePaths = try c.decodeIfPresent([String].self, forKey: .extraExecutablePaths)
        buildEnvironment = try c.decodeIfPresent([String: String].self, forKey: .buildEnvironment)
        pinnedDocument = try c.decodeIfPresent(String.self, forKey: .pinnedDocument)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
            ?? Self.pausedFromLegacyPriority(in: decoder)
    }

    /// The one thing the old three-way priority said that anything still reads:
    /// `paused` parked the project. `high` and `normal` ranked a fleet that now
    /// orders itself by which project has been idle longest, so they map to
    /// nothing at all — nil rather than `false`, so an upgraded config stays
    /// silent instead of gaining a field nobody set.
    private static func pausedFromLegacyPriority(in decoder: Decoder) -> Bool? {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
              let raw = try? legacy.decodeIfPresent(String.self, forKey: .priority) else { return nil }
        return raw.trimmingCharacters(in: .whitespaces).lowercased() == "paused" ? true : nil
    }
}
