import Foundation
import KiteloopCore

struct ResolvedAgent: Sendable {
    let package: AgentPackage
    let overrides: AgentOverrides?
    let source: AgentSource
    let packageURL: URL
    let refID: String

    var effectiveModel: String { overrides?.model ?? package.template.model }
    var effectiveName: String { package.template.name }
    var effectiveHandle: String { package.handleNormalized }
}

enum AgentSource: String, Codable, Sendable {
    case builtIn
    case user
    case shared
    case local
}

struct AgentScanPath: Sendable {
    let url: URL
    let source: AgentSource
}

struct AgentUpdate: Sendable {
    let handle: String
    let currentVersion: String
    let availableVersion: String
    let changelogURL: URL?
}

struct SourcedPackage: Sendable {
    let package: AgentPackage
    let source: AgentSource
    let packageURL: URL
}

@Observable
@MainActor
class PackageResolver {
    private(set) var scanPaths: [AgentScanPath] = []
    private(set) var availablePackages: [SourcedPackage] = []
    private var bootstrapTask: Task<Void, Never>?
    private let reporter: StoreProblemReporter

    /// The name this resolver reports under. A human reads it in a notification
    /// title, and it is half the dedup key, so it is spelled once. `nonisolated`
    /// because the scan that reports under it runs off the main actor.
    nonisolated static let storeName = "Agent packages"

    @available(*, deprecated, message: "Use scanPaths-based init")
    var knowledgeRepoURL: URL {
        scanPaths.first(where: { $0.source == .shared })?.url
            ?? scanPaths.first(where: { $0.source == .user })?.url
            ?? KiteloopHome.url.appending(path: ".kiteloop/knowledge")
    }

    init(scanPaths: [AgentScanPath], reporter: StoreProblemReporter = .shared) {
        self.scanPaths = scanPaths
        self.reporter = reporter
        bootstrapTask = Task { await reload() }
    }

    /// Scan paths are resolved and scanned in the background: filesystem access can
    /// block on a TCC consent prompt (e.g. ~/Documents), which must never stall
    /// app launch. Await `ensureLoaded()` before resolving agents.
    init(scanPathsProvider: @escaping @Sendable () -> [AgentScanPath],
         reporter: StoreProblemReporter = .shared) {
        self.reporter = reporter
        bootstrapTask = Task {
            self.scanPaths = await Task.detached(priority: .userInitiated) {
                scanPathsProvider()
            }.value
            await reload()
        }
    }

    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    /// Re-resolves the scan paths from a configured knowledge repository path and
    /// rescans them. The path a person picks in Settings used to reach only the
    /// config file: `reload()` rescans the paths this resolver already holds, and
    /// the provider `init(scanPathsProvider:)` was given runs exactly once, so the
    /// chosen repository's packages stayed invisible until the next launch.
    /// Resolution touches the filesystem and can block on a TCC consent prompt, so
    /// it runs off the main actor — the same hop `init(scanPathsProvider:)` makes.
    /// `home` is the real home directory; tests pass a temporary one so they never
    /// write under `~/.kiteloop`.
    func rescanPaths(configuredRepoPath: String?,
                     home: URL = KiteloopHome.url) async {
        scanPaths = await Task.detached(priority: .userInitiated) {
            KnowledgePathResolver.resolveScanPaths(configuredRepoPath: configuredRepoPath, home: home)
        }.value
        await reload()
    }

    func reload() async {
        let paths = scanPaths
        let reporter = self.reporter
        availablePackages = await Task.detached(priority: .userInitiated) {
            Self.scan(paths: paths, reporter: reporter)
        }.value
    }

    /// `report` is sync and the reporter is `@unchecked Sendable`, so the scan
    /// reports from whatever thread it is running on — no hop back to the main
    /// actor, which is the whole reason the scan is off it.
    private nonisolated static func scan(paths: [AgentScanPath],
                                         reporter: StoreProblemReporter) -> [SourcedPackage] {
        var packages: [SourcedPackage] = []
        var seenHandles: Set<String> = []

        let priorityOrder: [AgentSource] = [.local, .shared, .user, .builtIn]
        let sortedPaths = paths.sorted { a, b in
            let ai = priorityOrder.firstIndex(of: a.source) ?? 99
            let bi = priorityOrder.firstIndex(of: b.source) ?? 99
            return ai < bi
        }

        for scanPath in sortedPaths {
            let agentsDir = scanPath.url.appending(path: "agents")
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: agentsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
                continue
            }

            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let agentJSON = entry.appending(path: "agent.json")
                // A directory with no `agent.json` is not a package, and saying so
                // about every stray folder under `agents/` would be noise. One that
                // has the file but cannot be read or decoded is a different thing:
                // a single typo and the agent is absent from the sidebar, the team
                // config and every hire, with nothing anywhere saying why. So the
                // two are told apart here rather than sharing one silent `try?`.
                guard fm.fileExists(atPath: agentJSON.path(percentEncoded: false)) else { continue }
                let package: AgentPackage
                do {
                    let data = try Data(contentsOf: agentJSON)
                    package = try JSONDecoder().decode(AgentPackage.self, from: data)
                } catch {
                    reporter.report(store: Self.storeName,
                                    operation: .read,
                                    url: agentJSON,
                                    error: error)
                    continue
                }
                guard !seenHandles.contains(package.handleNormalized) else { continue }
                seenHandles.insert(package.handleNormalized)
                packages.append(SourcedPackage(package: package, source: scanPath.source, packageURL: entry))
            }
        }
        return packages.sorted { $0.package.handle < $1.package.handle }
    }

    func resolve(ref: PackageAgentRef, localAgentsURL: URL) -> ResolvedAgent? {
        if ref.isLocal {
            return resolveLocal(name: ref.refName, ref: ref, localAgentsURL: localAgentsURL)
        } else if ref.isShared {
            return resolveFromScanPaths(name: ref.refName, ref: ref, preferredSource: .shared)
        } else if ref.isUser {
            return resolveFromScanPaths(name: ref.refName, ref: ref, preferredSource: .user)
        }
        return resolveFromScanPaths(name: ref.refName, ref: ref, preferredSource: nil)
    }

    func resolveTeam(config: PackageTeamConfig, localAgentsURL: URL) -> [ResolvedAgent] {
        var resolved: [ResolvedAgent] = []
        var seenHandles: Set<String> = []

        for agentRef in config.agents {
            guard let agent = resolve(ref: agentRef, localAgentsURL: localAgentsURL) else {
                continue
            }
            guard !seenHandles.contains(agent.effectiveHandle) else {
                continue
            }
            seenHandles.insert(agent.effectiveHandle)
            resolved.append(agent)
        }
        return resolved
    }

    func availableUpdates(lock: TeamLock) -> [AgentUpdate] {
        var updates: [AgentUpdate] = []
        for (agentID, locked) in lock.agents {
            let refPrefix = locked.ref.components(separatedBy: ":").first ?? ""
            guard ["shared", "user"].contains(refPrefix) else { continue }
            let name = String(locked.ref.dropFirst(refPrefix.count + 1))
            guard let sourced = findPackage(name: name) else { continue }
            if sourced.package.version != locked.version {
                let changelogURL = sourced.packageURL.appending(path: "CHANGELOG.md")
                updates.append(AgentUpdate(
                    handle: agentID,
                    currentVersion: locked.version,
                    availableVersion: sourced.package.version,
                    changelogURL: changelogURL
                ))
            }
        }
        return updates
    }

    func sharedImportsURL() -> URL? {
        for path in scanPaths where path.source == .shared {
            let sharedDir = path.url.appending(path: "shared")
            if FileManager.default.fileExists(atPath: sharedDir.path(percentEncoded: false)) {
                return sharedDir
            }
        }
        for path in scanPaths where path.source == .user {
            let sharedDir = path.url.appending(path: "shared")
            if FileManager.default.fileExists(atPath: sharedDir.path(percentEncoded: false)) {
                return sharedDir
            }
        }
        return nil
    }

    func packageURL(name: String) -> URL? {
        findPackage(name: name)?.packageURL
    }

    // MARK: - Private

    private func findPackage(name: String) -> SourcedPackage? {
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return availablePackages.first { $0.package.handleNormalized == normalized }
    }

    private func resolveFromScanPaths(name: String, ref: PackageAgentRef, preferredSource: AgentSource?) -> ResolvedAgent? {
        let match: SourcedPackage?
        if let preferred = preferredSource {
            match = availablePackages.first {
                $0.package.handleNormalized == name && $0.source == preferred
            } ?? findPackage(name: name)
        } else {
            match = findPackage(name: name)
        }

        guard let sourced = match else { return nil }
        return ResolvedAgent(
            package: sourced.package,
            overrides: ref.overrides,
            source: sourced.source,
            packageURL: sourced.packageURL,
            refID: ref.id
        )
    }

    private func resolveLocal(name: String, ref: PackageAgentRef, localAgentsURL: URL) -> ResolvedAgent? {
        let agentDir = localAgentsURL.appending(path: name)
        let agentJSON = agentDir.appending(path: "agent.json")
        guard let data = try? Data(contentsOf: agentJSON),
              let package = try? JSONDecoder().decode(AgentPackage.self, from: data) else {
            return nil
        }
        return ResolvedAgent(
            package: package,
            overrides: ref.overrides,
            source: .local,
            packageURL: agentDir,
            refID: ref.id
        )
    }
}
