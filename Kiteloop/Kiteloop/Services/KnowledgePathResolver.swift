import Foundation
import KiteloopCore

struct KnowledgePathResolver {
    /// Touches the filesystem, including paths that may sit behind a TCC consent
    /// prompt (e.g. ~/Documents) where any access blocks — call off the main thread.
    /// `home` defaults to the real home directory; tests pass a temporary one so
    /// the assertions don't depend on the developer's actual `~/.kiteloop`.
    ///
    /// An isolated home (`KITELOOP_HOME` set, as a QA run sets it) never walks up
    /// into the source checkout: the checkout sits under ~/Documents, and the QA
    /// copy — rebuilt and ad-hoc signed every run — would ask for Documents access
    /// each time, a prompt nobody is there to answer on an unattended run.
    static func resolveScanPaths(configuredRepoPath: String?,
                                  home: URL = KiteloopHome.url,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentScanPath] {
        var paths: [AgentScanPath] = []

        if let path = configuredRepoPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            paths.append(AgentScanPath(url: URL(filePath: path), source: .shared))
        } else if environment[KiteloopHome.variable] == nil, let url = resolveRelativeToRepo() {
            paths.append(AgentScanPath(url: url, source: .shared))
        }

        let userAgentsDir = home.appending(path: ".kiteloop/agents")
        let userKnowledgeDir = home.appending(path: ".kiteloop")
        let fm = FileManager.default
        if !fm.fileExists(atPath: userAgentsDir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        }
        paths.append(AgentScanPath(url: userKnowledgeDir, source: .user))

        // The wizard's `installKnowledge` copies the chosen knowledge repo to
        // ~/.kiteloop/knowledge, not ~/.kiteloop/agents — this second user-sourced
        // path is what makes that copy actually scannable. It's appended after
        // the ~/.kiteloop path so a handle already sitting under ~/.kiteloop/agents
        // keeps winning the dedup `PackageResolver.scan` already does.
        let userKnowledgeRepoDir = home.appending(path: ".kiteloop/knowledge")
        paths.append(AgentScanPath(url: userKnowledgeRepoDir, source: .user))

        if let builtIn = resolveBuiltInPath() {
            paths.append(AgentScanPath(url: builtIn, source: .builtIn))
        }

        return paths
    }

    private static func resolveRelativeToRepo() -> URL? {
        if let sourceRoot = ProcessInfo.processInfo.environment["KITELOOP_SOURCE_ROOT"] {
            let knowledge = URL(fileURLWithPath: sourceRoot).appending(path: "knowledge/agents")
            if FileManager.default.fileExists(atPath: knowledge.path(percentEncoded: false)) {
                return URL(fileURLWithPath: sourceRoot).appending(path: "knowledge")
            }
        }

        // This walk-up from `#filePath` — the *compile-time* source path — resolves
        // only on the machine that built the binary, which is why it's compiled out
        // of Release builds rather than left to consult a path that means nothing
        // off that machine.
        #if DEBUG
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let knowledgeDir = current.appending(path: "knowledge")
            let agentsDir = knowledgeDir.appending(path: "agents")
            if FileManager.default.fileExists(atPath: agentsDir.path(percentEncoded: false)) {
                return knowledgeDir
            }
            current = current.deletingLastPathComponent()
        }
        #endif

        guard let execURL = Bundle.main.executableURL else { return nil }
        var execCurrent = execURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let knowledgeDir = execCurrent.appending(path: "knowledge")
            let agentsDir = knowledgeDir.appending(path: "agents")
            if FileManager.default.fileExists(atPath: agentsDir.path(percentEncoded: false)) {
                return knowledgeDir
            }
            execCurrent = execCurrent.deletingLastPathComponent()
        }
        return nil
    }

    /// The directory `examples/agents` sits under — the shipped app's bundled
    /// `examples`, or the repo checkout's when running unpackaged. Not private:
    /// `SampleProjectService` reuses it to find `examples/sample-project`
    /// beside the agent packages, rather than re-deriving the same bundle path.
    static func resolveBuiltInPath() -> URL? {
        // The shipped app, first. Everything below this walks up from `#filePath`
        // — the *compile-time* source path, which resolves only on the machine
        // that built it — or from the executable, whose parents in an installed
        // bundle are `Contents/MacOS` and `Contents`, neither of which holds
        // `examples`. So for every user who was not the developer this function
        // returned nil, the built-in packages were never found, and the setup
        // wizard offered an empty agent list with a file picker for a knowledge
        // repo they had no way to obtain. The folder is copied into the bundle's
        // resources now, and this is where it lands.
        if let bundled = Bundle.main.resourceURL?.appending(path: "examples"),
           FileManager.default.fileExists(
               atPath: bundled.appending(path: "agents").path(percentEncoded: false)) {
            return bundled
        }

        // A release build never falls through to here in practice — the bundle
        // check above always finds `examples`. This walk-up exists only for
        // running unpackaged from the repo, so it's compiled out of Release
        // builds rather than left to consult a compile-time path that means
        // nothing off the machine that built the binary.
        #if DEBUG
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let examplesDir = current.appending(path: "examples")
            let agentsDir = examplesDir.appending(path: "agents")
            if FileManager.default.fileExists(atPath: agentsDir.path(percentEncoded: false)) {
                return examplesDir
            }
            current = current.deletingLastPathComponent()
        }

        guard let execURL = Bundle.main.executableURL else { return nil }
        current = execURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let examplesDir = current.appending(path: "examples")
            let agentsDir = examplesDir.appending(path: "agents")
            if FileManager.default.fileExists(atPath: agentsDir.path(percentEncoded: false)) {
                return examplesDir
            }
            current = current.deletingLastPathComponent()
        }
        #endif
        return nil
    }
}
