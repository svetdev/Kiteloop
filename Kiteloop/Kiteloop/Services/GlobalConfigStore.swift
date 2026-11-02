import Foundation
import KiteloopCore

@Observable
@MainActor
class GlobalConfigStore {
    private let storageURL: URL
    private let reporter: StoreProblemReporter
    private(set) var config: GlobalConfig

    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the dedup key, so it is spelled once.
    static let storeName = "Settings"

    static let defaultURL: URL = {
        let home = KiteloopHome.url
        let dir = home.appending(path: ".kiteloop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "global-config.json")
    }()

    init(storageURL: URL? = nil, reporter: StoreProblemReporter = .shared) {
        self.storageURL = storageURL ?? Self.defaultURL
        self.reporter = reporter
        self.config = GlobalConfig()
        load()
    }

    var knowledgeRepoURL: URL? {
        guard let path = config.knowledgeRepoPath, !path.isEmpty else { return nil }
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    var needsSetup: Bool { knowledgeRepoURL == nil }

    func setKnowledgeRepoPath(_ path: String) {
        config.knowledgeRepoPath = path
        save()
    }

    func setVaultPath(_ path: String?) {
        config.vaultPath = path
        save()
    }

    var vaultURL: URL? {
        guard let path = config.vaultPath, !path.isEmpty else { return nil }
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    func setDefaultModel(_ model: String?) {
        config.defaultModel = model
        save()
    }

    var claudeAuthConfig: ClaudeAuthConfig { ClaudeAuthConfig.resolve(from: config) }

    func setClaudeAuth(_ method: ClaudeAuthMethod) {
        config.claudeAuth = method.rawValue
        if method == .bedrock, config.bedrock == nil {
            config.bedrock = .default
        }
        save()
    }

    func setBedrockConfig(_ bedrock: BedrockConfig?) {
        config.bedrock = bedrock
        save()
    }

    func setDefaultEffort(_ effort: String?) {
        config.defaultEffort = effort
        save()
    }

    func setMCPServers(_ servers: [String: ClaudeMCPServerEntry]?) {
        config.mcpServers = servers
        save()
        ClaudeCodeCLIRuntime.broadcastGlobalMCPServers(servers ?? [:])
    }

    /// The portfolio-level statement, or nil when nothing is stated. Whitespace
    /// only counts as nothing.
    var portfolioGoal: String? { KiteloopProject.normalizedStatement(config.portfolioGoal) }

    func setPortfolioGoal(_ goal: String?) {
        config.portfolioGoal = KiteloopProject.normalizedStatement(goal)
        save()
    }

    /// Sets the portfolio-wide daily ceiling. A non-positive value means **no
    /// ceiling** rather than a permanent refusal — the same reading the cost-cap
    /// fields give a cleared or junk entry.
    func setDailyBudgetUSD(_ budget: Double?) {
        config.dailyBudgetUSD = (budget ?? 0) > 0 ? budget : nil
        save()
    }

    // MARK: - Queue refill

    /// The refill loop's switch as stored. Off unless a human turned it on.
    var coordinatorRefillEnabled: Bool { config.coordinatorRefillEnabled ?? false }

    /// Persists the refill loop's settings. An omitted argument is left alone;
    /// `maxPassesPerDay: .some(nil)` clears the pass ceiling.
    func setCoordinatorRefill(enabled: Bool? = nil,
                              maxPassesPerDay: Int?? = nil) {
        if let enabled { config.coordinatorRefillEnabled = enabled }
        if let maxPassesPerDay {
            config.coordinatorMaxPassesPerDay = (maxPassesPerDay ?? 0) > 0 ? maxPassesPerDay : nil
        }
        save()
    }

    // MARK: - Autonomous run scheduling

    /// The scheduler's switch as stored. Off unless a human turned it on — an
    /// upgrade must never inherit a loop that starts runs.
    var coordinatorSchedulingEnabled: Bool { config.coordinatorSchedulingEnabled ?? false }

    func setCoordinatorScheduling(enabled: Bool) {
        config.coordinatorSchedulingEnabled = enabled
        save()
    }

    /// How many autonomous runs the fleet may have in flight at once; one
    /// unless a person raised it.
    var maxConcurrentRuns: Int { config.maxConcurrentRuns ?? 1 }

    func setMaxConcurrentRuns(_ count: Int) {
        config.maxConcurrentRuns = count
        save()
    }

    /// A digest of every global setting — the backend agents resolve through,
    /// the ceilings, the switches.
    ///
    /// `RunScheduling.ProjectHold` is what reads it. A hold formed by two
    /// different items failing the same way is not about either item, so no
    /// backlog edit clears it; what does is a change out here or in the
    /// project's own autopilot config, and this is the half of that pair that
    /// covers "the runtime resolves differently now".
    var configFingerprint: String { RunScheduling.fingerprint(config) }

    /// The push key, or nil to stop pushing. A key missing any of its three
    /// parts is stored as none.
    func setPushKey(_ key: PushKeyConfig?) {
        config.pushKey = key?.isComplete == true ? key : nil
        save()
    }

    /// The phone's one-tap replies; an empty list clears them for good.
    func setQuickReplies(_ replies: [String]) {
        config.quickReplies = replies
        save()
    }

    func setControlServer(enabled: Bool, port: Int) {
        config.controlServerEnabled = enabled
        config.controlServerPort = port
        save()
    }

    private func load() {
        // A config the decoder refuses is kept, not dropped: `try?` here read a
        // truncated file as "no settings at all", and the first save — every
        // setter makes one — wrote the defaults over it for good.
        guard let decoded = QuarantiningJSONFile.load(StoredGlobalConfig.self,
                                                      from: storageURL,
                                                      store: Self.storeName,
                                                      reporter: reporter) else {
            return
        }
        config = decoded.config
        // A retired key is read once, then the file is written without it.
        if decoded.carriedRetiredKeys { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        // Durably, not just `.atomic` — an unclean shutdown must never leave a
        // truncated config behind, because the next launch would read it as an
        // empty one and the first save would make that permanent.
        do {
            try AtomicFileWriter.write(data, to: storageURL)
        } catch {
            // Every setter saves, so a config that has stopped saving looks
            // exactly like one nobody changed: the setting reverts on the next
            // launch and nothing anywhere said why. Discarding this error was
            // how that happened.
            reporter.report(store: Self.storeName, operation: .write, url: storageURL, error: error)
        }
    }
}
