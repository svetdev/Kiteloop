import AppKit
import Foundation
import KiteloopCore
import Security
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "setup-wizard")

@Observable
@MainActor
class SetupWizardViewModel {
    enum CheckStatus: Equatable {
        case checking
        case ok(String)
        case missing(String)
    }

    var claudeStatus: CheckStatus = .checking
    var nodeStatus: CheckStatus = .checking
    var authStatus: CheckStatus = .checking
    var githubStatus: CheckStatus = .checking

    var authMethod: ClaudeAuthMethod { globalConfig.claudeAuthConfig.method }

    var availableAgents: [AgentOption] = []
    var selectedAgentIDs: Set<String> = []
    var finishError: String?
    /// Why the last knowledge install did not happen; nil after one that did.
    var knowledgeError: String?

    struct AgentOption: Identifiable {
        let id: String
        let name: String
        let description: String
        let group: String
        let repos: [String]
        let avatar: String
    }

    private let packageResolver: PackageResolver?
    let repoCloneService: RepoCloneService
    private let globalConfig: GlobalConfigStore

    init(packageResolver: PackageResolver?, repoCloneService: RepoCloneService, globalConfig: GlobalConfigStore) {
        self.packageResolver = packageResolver
        self.repoCloneService = repoCloneService
        self.globalConfig = globalConfig
    }

    func runChecks() async {
        await checkClaude()
        await checkNode()
        await checkAuth()
        await checkGitHub()
        loadAgents()
        repoCloneService.refreshStatuses(repos: requiredRepos)
        let org = globalConfig.config.githubOrg ?? ""
        await repoCloneService.fetchRepoSizes(repos: requiredRepos, org: org)
    }

    var requiredRepos: [String] {
        let selected = availableAgents.filter { selectedAgentIDs.contains($0.id) }
        return Array(Set(selected.flatMap(\.repos)))
    }

    var knowledgeInstalled: Bool {
        let path = KiteloopHome.url
            .appending(path: ".kiteloop/knowledge/agents")
        return FileManager.default.fileExists(atPath: path.path(percentEncoded: false))
    }

    func installKnowledge() async {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "select knowledge directory")
        let panel = NSOpenPanel()
        panel.title = "Select kiteloop-knowledge directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the kiteloop-knowledge folder (contains an 'agents' subdirectory)"

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let agentsCheck = sourceURL.appending(path: "agents")
        guard FileManager.default.fileExists(atPath: agentsCheck.path(percentEncoded: false)) else {
            log.error("[setup-wizard] selected dir has no agents/ subdirectory")
            knowledgeError = "That folder has no agents subfolder, so it isn't a knowledge folder."
            return
        }

        do {
            try Self.installKnowledge(from: sourceURL, to: KiteloopHome.url.appending(path: ".kiteloop/knowledge"))
            knowledgeError = nil
            log.info("[setup-wizard] copied knowledge repo to ~/.kiteloop/knowledge")
            await packageResolver?.reload()
            loadAgents()
        } catch {
            log.error("[setup-wizard] failed to copy knowledge: \(error.localizedDescription)")
            knowledgeError = "Couldn't install the knowledge folder: \(error.localizedDescription) "
                + "The one already installed is unchanged."
        }
    }

    /// Replaces `dest` with a copy of `source`, never leaving it with neither:
    /// the copy lands in a staging sibling first, and the old install is
    /// removed only once the new one is in its place. Any failure leaves
    /// `dest` as it was and no staging directory behind.
    nonisolated static func installKnowledge(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()
        let staging = parent.appending(path: ".\(dest.lastPathComponent).staging-\(UUID().uuidString)")
        let retired = parent.appending(path: ".\(dest.lastPathComponent).old-\(UUID().uuidString)")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let hadInstall = fm.fileExists(atPath: dest.path(percentEncoded: false))
        if hadInstall { try fm.moveItem(at: dest, to: retired) }
        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            if hadInstall { try? fm.moveItem(at: retired, to: dest) }
            throw error
        }
        try? fm.removeItem(at: retired)
    }

    var isCloning: Bool {
        repoCloneService.statuses.values.contains { if case .cloning = $0 { return true } else { return false } }
    }

    func cloneAllRepos() async {
        let org = globalConfig.config.githubOrg ?? ""
        repoCloneService.refreshStatuses(repos: requiredRepos)
        await repoCloneService.cloneIfNeeded(repos: requiredRepos, org: org)
    }

    func cloneRepo(_ repo: String) async {
        let org = globalConfig.config.githubOrg ?? ""
        await repoCloneService.clone(repo: repo, org: org)
    }

    /// Returns false when the team config couldn't be written — the wizard
    /// must not report success with a broken home workspace.
    func finish() async -> Bool {
        writeTeamConfig()
    }

    private func writeTeamConfig() -> Bool {
        let home = KiteloopProject.homeWorkspace

        let selected = availableAgents.filter { selectedAgentIDs.contains($0.id) }
        let refs: [PackageAgentRef] = selected.map { agent in
            PackageAgentRef(id: agent.id, ref: "shared:\(agent.id)", version: nil, overrides: nil)
        }
        let teamConfig = PackageTeamConfig(agents: refs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try home.ensureKiteloopDirectory()
            let data = try encoder.encode(teamConfig)
            try AtomicFileWriter.write(data, to: home.teamConfigURL)
            log.info("[setup-wizard] wrote team.json with \(refs.count) agents")
            finishError = nil
            return true
        } catch {
            log.error("[setup-wizard] failed to write team.json: \(error.localizedDescription)")
            finishError = "Couldn't set up the home workspace: \(error.localizedDescription)"
            return false
        }
    }


    private func loadAgents() {
        guard let resolver = packageResolver else { return }
        let packages = resolver.availablePackages
        availableAgents = packages.compactMap { sourced -> AgentOption? in
            let pkg = sourced.package
            return AgentOption(
                id: pkg.handle.replacingOccurrences(of: "@", with: ""),
                name: pkg.template.name,
                description: pkg.template.description ?? "",
                group: pkg.template.group ?? "",
                repos: pkg.repos ?? [],
                avatar: pkg.template.avatar ?? "🤖"
            )
        }
        selectedAgentIDs = Set(availableAgents.map(\.id))
    }

    private func checkClaude() async {
        if let path = CLIResolver.resolve(globalConfig: globalConfig.config).claude {
            claudeStatus = .ok(path)
        } else {
            claudeStatus = .missing("Install: npm install -g @anthropic-ai/claude-code")
        }
    }

    private func checkNode() async {
        if let path = CLIResolver.resolve(globalConfig: globalConfig.config).node {
            nodeStatus = .ok(path)
        } else {
            nodeStatus = .missing("Install Node.js from nodejs.org")
        }
    }

    private func checkAuth() async {
        switch authMethod {
        case .subscription:
            checkSubscriptionAuth()
        case .apiKey:
            let key = TokenStore.get(ClaudeAuthConfig.anthropicTokenKey) ?? ""
            authStatus = key.isEmpty
                ? .missing("Add your API key in Settings → Claude Backend")
                : .ok("API key configured")
        case .bedrock:
            await checkBedrock()
        }
    }

    private func checkSubscriptionAuth() {
        // The claude CLI stores login credentials in the login Keychain on macOS,
        // falling back to ~/.claude/.credentials.json. Either marks a completed login.
        let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
        let hasKeychainEntry = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: false,
        ] as CFDictionary, nil) == errSecSuccess
        if hasKeychainEntry || FileManager.default.fileExists(atPath: credentialsFile.path(percentEncoded: false)) {
            authStatus = .ok("Claude account login found")
        } else {
            authStatus = .missing("Run `claude` in a terminal and sign in")
        }
    }

    private func checkBedrock() async {
        // Try with AWS_PROFILE from: Kiteloop config → env var → first profile in ~/.aws/config
        let profile = globalConfig.config.bedrock?.profile
            ?? ProcessInfo.processInfo.environment["AWS_PROFILE"]
            ?? detectFirstAWSProfile()

        let extraEnv = profile.map { ["AWS_PROFILE": $0] } ?? [:]
        let success = await Self.runCredentialCheck(
            arguments: ["aws", "sts", "get-caller-identity"],
            extraEnv: extraEnv
        )

        if success {
            authStatus = .ok("AWS active (\(profile ?? "default"))")
        } else {
            authStatus = .missing("Run: aws sso login" + (profile.map { " --profile \($0)" } ?? ""))
        }
    }

    private func detectFirstAWSProfile() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws/config")
        guard let content = String(lenientContentsOf: configURL) else { return nil }
        // Match [profile xyz] — return first non-default profile name
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("[profile ") && line.hasSuffix("]") {
                let name = String(line.dropFirst(9).dropLast(1))
                return name
            }
        }
        return nil
    }

    private func checkGitHub() async {
        let success = await Self.runCredentialCheck(arguments: ["gh", "auth", "status"])
        if success {
            githubStatus = .ok("Authenticated")
        } else {
            githubStatus = .missing("Run: gh auth login")
        }
    }

    /// Read from background process-spawn closures, so it can't be main-actor
    /// isolated. It's an immutable String computed once — safe to share.
    private nonisolated static let expandedPath: String = ExecutableSearchPath.resolved(projectRoot: nil).joined

    /// How long a credential check may run before it's abandoned. Both `aws
    /// sts get-caller-identity` and `gh auth status` make a network call, and
    /// neither can prompt for anything here — `runWithDeadline` points the
    /// child's stdin at the null device — so a hang past this point is a dead
    /// network path, not a question waiting on an answer.
    nonisolated static let credentialCheckTimeout: TimeInterval = 15

    /// Runs `env <arguments>` with `Self.expandedPath` and `extraEnv` layered
    /// onto the current environment, and reports only whether it exited zero.
    ///
    /// On a deadline via `SubprocessOutput.runWithDeadline`: a check that
    /// spawned its own `Process` by hand here previously had no time limit,
    /// so a hung `aws` or `gh` call left every later check in `runChecks` on
    /// `.checking` forever. `executable` exists so a test can point this at a
    /// script that never exits and drive the timeout without waiting on a
    /// real one; nothing in the app passes it.
    nonisolated static func runCredentialCheck(
        arguments: [String],
        extraEnv: [String: String] = [:],
        executable: String = "/usr/bin/env",
        timeout: TimeInterval = credentialCheckTimeout
    ) async -> Bool {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.expandedPath
        for (k, v) in extraEnv { env[k] = v }
        let result = await Task.detached(priority: .utility) {
            SubprocessOutput.runWithDeadline(
                executable: executable,
                arguments: arguments,
                environment: env,
                timeout: timeout,
                discardStandardError: true
            )
        }.value
        return result.status == 0
    }
}
