import Foundation
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "repo-status")

@Observable
@MainActor
package class RepoStatusStore {
    package enum RepoAvailability: Equatable {
        case available(String)
        case missing
        case cloning
    }

    /// What `loadLinks()` made of the links file. Two of these used to be one:
    /// any failure to read `~/.kiteloop/repo-links.json` came back as no links
    /// at all, said nothing, and the next `linkRepo`/`unlinkRepo` wrote that
    /// empty-plus-one dictionary over the file — so every repo somebody had
    /// resolved by hand went back to `.missing`, which is the state
    /// `RepoResolutionPopover` exists to clear.
    ///
    /// It is the verdict on the file as it was found, not a running state: a
    /// later save does not revise it.
    package enum LinksFileState: Equatable {
        /// No file. The ordinary first-run state, and silent.
        case absent
        /// Read and decoded.
        case loaded
        /// Present and unusable. `movedAsideTo` names the sibling its bytes
        /// were renamed to, so what was in it is still recoverable. Nil when
        /// the file is still exactly where it was — it could not be moved, or
        /// could not be read at all — in which case nothing is written over it
        /// and every save is skipped.
        case unusable(movedAsideTo: String?)
    }

    package private(set) var agentRepos: [String: [String]] = [:]
    package private(set) var repoStatus: [String: RepoAvailability] = [:]
    package private(set) var linkedRepos: [String: String] = [:]
    /// Logged as well, but exposed so a caller — and a test — can see how the
    /// links file was read without going to os_log.
    package private(set) var linksFileState: LinksFileState = .absent

    private let cloneService: RepoCloneService
    private let linksURL: URL

    /// `linksURL` is for tests, so a store can be pointed somewhere other than
    /// the developer's own `~/.kiteloop/repo-links.json` — the way
    /// `RunRecordStore(url:)` is injected.
    package init(cloneService: RepoCloneService, linksURL: URL? = nil) {
        self.cloneService = cloneService
        let home = KiteloopHome.url
        self.linksURL = linksURL ?? home.appending(path: ".kiteloop/repo-links.json")
        loadLinks()
    }

    package func register(agentID: String, repos: [String]) {
        agentRepos[agentID] = repos
        for repo in repos where repoStatus[repo] == nil {
            repoStatus[repo] = checkAvailability(repo)
        }
    }

    package func refresh() {
        for repo in repoStatus.keys {
            repoStatus[repo] = checkAvailability(repo)
        }
    }

    package func missingRepos(for agentID: String) -> [String] {
        guard let repos = agentRepos[agentID] else { return [] }
        return repos.filter { repo in
            if case .available = repoStatus[repo] { return false }
            return true
        }
    }

    package func hasMissingRepos(_ agentID: String) -> Bool {
        !missingRepos(for: agentID).isEmpty
    }

    package func repoPath(for repo: String) -> URL? {
        if case .available(let path) = repoStatus[repo] {
            return URL(filePath: path)
        }
        return nil
    }

    package func linkRepo(_ repo: String, to path: URL) {
        let pathStr = path.path(percentEncoded: false)
        linkedRepos[repo] = pathStr
        repoStatus[repo] = .available(pathStr)
        saveLinks()
        log.info("[repo-status] linked \(repo) → \(pathStr)")
    }

    package func unlinkRepo(_ repo: String) {
        linkedRepos.removeValue(forKey: repo)
        repoStatus[repo] = checkAvailability(repo)
        saveLinks()
    }

    // MARK: - Private

    private func checkAvailability(_ repo: String) -> RepoAvailability {
        if cloneService.isCloned(repo) {
            return .available(cloneService.repoDir(for: repo).path(percentEncoded: false))
        }
        if let linked = linkedRepos[repo] {
            let gitDir = URL(filePath: linked).appending(path: ".git")
            if FileManager.default.fileExists(atPath: gitDir.path(percentEncoded: false)) {
                return .available(linked)
            }
        }
        if case .cloning = cloneService.statuses[repo] {
            return .cloning
        }
        return .missing
    }

    /// Reads the links file, telling apart the ways it can fail to be read.
    ///
    /// No file is how every install starts and stays silent. A file that is
    /// there and will not decode is somebody's hand-resolved repo paths, so it
    /// is named and moved aside once before the store carries on with no links
    /// — the same choice `TokenStore` and `SessionStore` make for a file they
    /// cannot read. A file that cannot be read *at all* — a permission
    /// tightened, a directory in its place — is a third thing: nothing here
    /// could tell what moving it would rescue, so it is left exactly as it was,
    /// and `saveLinks()` writes nothing over it either.
    private func loadLinks() {
        guard let data = try? Data(contentsOf: linksURL) else {
            guard FileManager.default.fileExists(atPath: linksURL.path(percentEncoded: false)) else { return }
            linksFileState = .unusable(movedAsideTo: nil)
            log.error("[repo-status] \(self.linksURL.lastPathComponent) is there but could not be read — carrying on with no links, and no link will be written over it")
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            linksFileState = .unusable(movedAsideTo: moveAsideUnreadableLinks())
            return
        }
        linkedRepos = decoded
        linksFileState = .loaded
    }

    /// Renames the undecodable links file to a sibling and answers what it was
    /// renamed to, or nil if it could not be moved — in which case the file is
    /// still where it was and no save may write over it.
    ///
    /// A sibling rather than a temp directory: the rename has to stay on one
    /// volume, and it keeps the salvage next to the file it came from. A move
    /// that fails in practice means a directory that cannot be written to, so
    /// the saves it goes on to skip would not have landed anyway.
    private func moveAsideUnreadableLinks() -> String? {
        let name = linksURL.lastPathComponent
        let destination = Self.unusedSibling(of: linksURL, named: "\(name).unreadable")
        do {
            try FileManager.default.moveItem(at: linksURL, to: destination)
        } catch {
            log.error("[repo-status] \(name) could not be decoded and could not be moved aside to \(destination.lastPathComponent): \(error.localizedDescription) — leaving it in place rather than overwriting it, so no link is saved")
            return nil
        }
        log.error("[repo-status] \(name) could not be decoded; moved it aside to \(destination.lastPathComponent) and started a new one. The repo paths it held have to be linked again, and are still recoverable from that file.")
        return destination.lastPathComponent
    }

    /// The first of `name`, `name-2`, `name-3`… that nothing occupies.
    ///
    /// `moveItem` refuses to replace an existing file, so without this a second
    /// unreadable links file would leave the move failing and every save with it.
    private static func unusedSibling(of url: URL, named name: String) -> URL {
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appending(path: name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(name)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private func saveLinks() {
        // A file that would not decode and could not be moved aside is still
        // sitting there, and this write is the one step that cannot be undone.
        if case .unusable(nil) = linksFileState {
            log.error("[repo-status] not writing \(self.linksURL.lastPathComponent): it could not be read and could not be moved aside, and the links it holds are not this store's to replace")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(linkedRepos) else { return }
        try? data.write(to: linksURL, options: .atomic)
    }
}
