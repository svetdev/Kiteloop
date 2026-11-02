import Foundation

/// The one file `~/.kiteloop/global-config.json` decodes to: every app-wide
/// setting, each optional so a config written by any older build still loads.
/// `GlobalConfigStore` owns reading and writing it; the value itself is plain
/// data, which is why it lives apart from the store.
package struct GlobalConfig: Codable, Sendable {
    package var knowledgeRepoPath: String?
    package var vaultPath: String?
    package var defaultModel: String?
    package var defaultEffort: String?
    /// ClaudeAuthMethod raw value; nil means bedrock if a bedrock block exists
    /// (legacy installs), otherwise subscription.
    package var claudeAuth: String?
    package var bedrock: BedrockConfig?
    package var observability: OTLPConfig?
    package var mcpServers: [String: ClaudeMCPServerEntry]?
    package var claudePath: String?
    package var nodePath: String?
    package var githubOrg: String?
    /// Local control API (127.0.0.1) that lets external tools — e.g. a Claude Code
    /// session — start backlog items, monitor them, and read results. Off by
    /// default; enabling it opens a token-guarded loopback socket.
    package var controlServerEnabled: Bool?
    package var controlServerPort: Int?
    /// What the human is trying to get out of this stretch, across every
    /// project — the tie-breaker when per-project priorities are level. Nil
    /// means nothing stated, which is a legitimate state.
    package var portfolioGoal: String?
    /// The most every project together may spend in one local day before
    /// **autonomous** work stops asking for more (`DailyBudget`). Portfolio-wide
    /// on purpose: the per-project caps bound one item and one session, and
    /// neither bounds a coordinator starting fresh sessions all night. Nil = no
    /// ceiling, which is the default.
    package var dailyBudgetUSD: Double?
    /// The queue-refill loop's switch. Grooming's cost is bounded by
    /// `dailyBudgetUSD`, like everything else autonomous. Portfolio state rather than any one project's: the loop chooses
    /// *between* projects, so a per-project copy would have no single answer.
    ///
    /// Nil throughout is the shipped default — **off**. Only a stored value
    /// ever turns the loop on, so upgrading the app cannot start it filing
    /// backlog items.
    package var coordinatorRefillEnabled: Bool?
    /// The most grooming passes a day may run. Stored so a ceiling the operator
    /// tuned outlives a relaunch; nil means the shipped default.
    package var coordinatorMaxPassesPerDay: Int?
    /// The autonomous run scheduler's switch (`CoordinatorRunScheduler`).
    ///
    /// Deliberately **separate from the refill switch**: filing work and running
    /// it unattended are different levels of trust, and one switch for both
    /// would make the second an accident of granting the first. Nil is the
    /// shipped default — off — so an upgrade never starts running work.
    package var coordinatorSchedulingEnabled: Bool?
    /// How many autonomous runs the fleet may have in flight at once, across
    /// projects — each project still runs one at a time. Nil is the shipped
    /// default, one, which is how the fleet always ran: the scheduler awaits
    /// the run it starts before it looks again.
    package var maxConcurrentRuns: Int?
    /// Directories appended to the app's executable search path
    /// (`ExecutableSearchPath`) for every project — where a tool lives that
    /// neither the login shell's `PATH` nor the fixed extras reach. Entries may
    /// be written with `~`. Nil is the shipped default: nothing extra.
    package var extraExecutablePaths: [String]?
    /// The APNs key pushes to the phone are signed with. Nil is
    /// the shipped default: no pushes.
    package var pushKey: PushKeyConfig?
    /// The replies the phone offers as one tap above its chat composer. Nil
    /// means never set, which reads as `QuickReplies.starters`; an empty list
    /// is one cleared on purpose and stays empty.
    package var quickReplies: [String]?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(knowledgeRepoPath: String? = nil, vaultPath: String? = nil, defaultModel: String? = nil, defaultEffort: String? = nil, claudeAuth: String? = nil, bedrock: BedrockConfig? = nil, observability: OTLPConfig? = nil, mcpServers: [String: ClaudeMCPServerEntry]? = nil, claudePath: String? = nil, nodePath: String? = nil, githubOrg: String? = nil, controlServerEnabled: Bool? = nil, controlServerPort: Int? = nil, portfolioGoal: String? = nil, dailyBudgetUSD: Double? = nil, coordinatorRefillEnabled: Bool? = nil, coordinatorMaxPassesPerDay: Int? = nil, coordinatorSchedulingEnabled: Bool? = nil, extraExecutablePaths: [String]? = nil) {
        self.knowledgeRepoPath = knowledgeRepoPath
        self.vaultPath = vaultPath
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.claudeAuth = claudeAuth
        self.bedrock = bedrock
        self.observability = observability
        self.mcpServers = mcpServers
        self.claudePath = claudePath
        self.nodePath = nodePath
        self.githubOrg = githubOrg
        self.controlServerEnabled = controlServerEnabled
        self.controlServerPort = controlServerPort
        self.portfolioGoal = portfolioGoal
        self.dailyBudgetUSD = dailyBudgetUSD
        self.coordinatorRefillEnabled = coordinatorRefillEnabled
        self.coordinatorMaxPassesPerDay = coordinatorMaxPassesPerDay
        self.coordinatorSchedulingEnabled = coordinatorSchedulingEnabled
        self.extraExecutablePaths = extraExecutablePaths
    }
}

/// What `~/.kiteloop/global-config.json` decodes to on load: the config, with
/// the keys of retired settings read once and dropped.
///
/// `coordinatorRefillMode` (advisory mode's knob) meant nothing and is simply
/// ignored. `coordinatorRefillDailyBudgetUSD` was grooming's own ceiling before
/// the ceilings merged; a positive one becomes `dailyBudgetUSD` when that is
/// unset, so a bound never silently disappears. `GlobalConfig` has neither
/// property, so the next save writes neither key.
package struct StoredGlobalConfig: Decodable {
    package let config: GlobalConfig
    /// Whether the file still carried a retired key — the store saves once
    /// so the file stops carrying it.
    package let carriedRetiredKeys: Bool

    private enum RetiredKeys: String, CodingKey {
        case coordinatorRefillMode, coordinatorRefillDailyBudgetUSD
    }

    package init(from decoder: Decoder) throws {
        var config = try GlobalConfig(from: decoder)
        let retired = try decoder.container(keyedBy: RetiredKeys.self)
        let legacyBudget = try? retired.decodeIfPresent(Double.self, forKey: .coordinatorRefillDailyBudgetUSD)
        if config.dailyBudgetUSD == nil, let legacyBudget, legacyBudget > 0 {
            config.dailyBudgetUSD = legacyBudget
        }
        self.config = config
        self.carriedRetiredKeys = !retired.allKeys.isEmpty
    }
}
