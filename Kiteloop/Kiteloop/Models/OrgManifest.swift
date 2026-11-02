import Foundation

struct OrgManifest: Codable, Sendable {
    let name: String
    let version: String?
    let org: OrgConfig?

    struct OrgConfig: Codable, Sendable {
        let githubOrg: String?
        let workspaceName: String?
    }
}

@Observable
@MainActor
class OrgManifestLoader {
    private(set) var manifest: OrgManifest?
    private var loadTask: Task<Void, Never>?

    /// Idempotent: the first caller kicks off the load (after the resolver's scan
    /// paths are ready), later callers await the same task. File reads run in the
    /// background — they can block on a TCC consent prompt (e.g. ~/Documents).
    func loadIfNeeded(resolver: PackageResolver) async {
        if loadTask == nil {
            loadTask = Task {
                await resolver.ensureLoaded()
                let paths = resolver.scanPaths
                manifest = await Task.detached(priority: .userInitiated) {
                    Self.read(from: paths)
                }.value
            }
        }
        await loadTask?.value
    }

    private nonisolated static func read(from scanPaths: [AgentScanPath]) -> OrgManifest? {
        for source in [AgentSource.shared, .user] {
            for path in scanPaths where path.source == source {
                let manifestURL = path.url.appending(path: "manifest.json")
                if let data = try? Data(contentsOf: manifestURL),
                   let decoded = try? JSONDecoder().decode(OrgManifest.self, from: data) {
                    return decoded
                }
            }
        }
        return nil
    }
}
