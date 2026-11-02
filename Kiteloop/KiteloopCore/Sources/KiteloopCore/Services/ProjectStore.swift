import Foundation

package protocol ProjectStoring: Sendable {
    func openProjects() async -> [KiteloopProject]
    func activeProject() async -> KiteloopProject?
    func setActive(_ project: KiteloopProject) async
    func open(_ url: URL) async throws -> KiteloopProject
    func close(_ projectID: String) async
    func reorder(_ projectID: String, before targetID: String?) async
    func sortOpen(byURLOrder order: [URL]) async
    func recentProjects() async -> [RecentProject]
}

package struct RecentProject: Codable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package let path: String
    package let lastOpened: Date

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, name: String, path: String, lastOpened: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.lastOpened = lastOpened
    }
}

/// Opening a project whose folder is not there. Opening used to recreate the
/// whole path as an empty project — a moved folder's empty twin, a phantom
/// folder under /Volumes for an unmounted drive.
package struct ProjectFolderMissingError: LocalizedError, Equatable {
    package let path: String

    package var errorDescription: String? {
        "The folder \(path) isn't there — it may have been moved, renamed or deleted, "
            + "or be on a drive that isn't connected."
    }
}

package actor ProjectStore: ProjectStoring {
    private var open: [KiteloopProject] = []
    private var activeID: String?
    private var recents: [RecentProject] = []
    private let recentsURL: URL
    private let reporter: StoreProblemReporter

    package static let maxRecents = 10

    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the dedup key, so it is spelled once.
    package static let storeName = "Recent projects"

    package init(recentsURL: URL, reporter: StoreProblemReporter = .shared) {
        self.recentsURL = recentsURL
        self.reporter = reporter
        self.recents = Self.loadRecents(from: recentsURL, reporter: reporter)
    }

    package func openProjects() -> [KiteloopProject] { open }

    package func activeProject() -> KiteloopProject? {
        if let id = activeID { return open.first(where: { $0.id == id }) }
        return open.first
    }

    package func setActive(_ project: KiteloopProject) {
        activeID = project.id
    }

    package func open(_ url: URL) throws -> KiteloopProject {
        if let existing = open.first(where: { $0.rootURL == url }) {
            activeID = existing.id
            return existing
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectFolderMissingError(path: url.path)
        }

        let project = KiteloopProject(rootURL: url)
        try project.ensureKiteloopDirectory()
        open.append(project)
        activeID = project.id
        addToRecents(project)
        return project
    }

    package func close(_ projectID: String) {
        open.removeAll(where: { $0.id == projectID })
        if activeID == projectID {
            activeID = open.first?.id
        }
    }

    package func reorder(_ projectID: String, before targetID: String?) {
        guard let fromIndex = open.firstIndex(where: { $0.id == projectID }),
              projectID != targetID else { return }
        let project = open.remove(at: fromIndex)
        if let targetID, let toIndex = open.firstIndex(where: { $0.id == targetID }) {
            open.insert(project, at: toIndex)
        } else {
            open.append(project)
        }
    }

    /// Reorders the open projects to match the given URL order. Projects whose URL isn't
    /// in `order` are kept after the ordered ones, in their current relative order.
    /// Used on launch to restore saved tab order after concurrent reopening.
    package func sortOpen(byURLOrder order: [URL]) {
        var rank: [String: Int] = [:]
        for (index, url) in order.enumerated() where rank[url.path] == nil {
            rank[url.path] = index
        }
        open = open.enumerated().sorted { lhs, rhs in
            let lRank = rank[lhs.element.rootURL.path] ?? Int.max
            let rRank = rank[rhs.element.rootURL.path] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            return lhs.offset < rhs.offset  // stable for equal/unranked entries
        }.map(\.element)
    }

    package func recentProjects() -> [RecentProject] { recents }

    private func addToRecents(_ project: KiteloopProject) {
        let canonical = project.id
        recents.removeAll(where: { KiteloopProject.canonicalPath($0.path) == canonical })
        let recent = RecentProject(
            id: canonical,
            name: project.rootURL.lastPathComponent,
            path: canonical,
            lastOpened: Date()
        )
        recents.insert(recent, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    private static func loadRecents(from url: URL, reporter: StoreProblemReporter) -> [RecentProject] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A file the decoder refuses is kept, not dropped: reading it as "no
        // recents at all" meant the next `addToRecents` overwrote the bytes a
        // human could have repaired, with nothing anywhere saying why.
        let raw = QuarantiningJSONFile.load([RecentProject].self,
                                            from: url,
                                            store: Self.storeName,
                                            decoder: decoder,
                                            reporter: reporter) ?? []
        // Collapse legacy duplicates that point at the same folder but differ
        // only by a trailing slash, keeping the first (most recent) occurrence
        // and rewriting it to the canonical path.
        var seen = Set<String>()
        var deduped: [RecentProject] = []
        for r in raw {
            let key = KiteloopProject.canonicalPath(r.path)
            guard seen.insert(key).inserted else { continue }
            deduped.append(RecentProject(id: key, name: r.name, path: key, lastOpened: r.lastOpened))
        }
        return deduped
    }

    private func saveRecents() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(recents) else { return }
        // Durably, not just `.atomic` — an unclean shutdown must never leave a
        // truncated recents file behind, because the next launch would read it
        // as an empty list and the first save would make that permanent.
        do {
            try AtomicFileWriter.write(data, to: recentsURL)
        } catch {
            // A save that has stopped writing looks exactly like one nobody
            // changed: the project opened this morning is missing tomorrow and
            // nothing anywhere says why. Discarding this error was how that
            // happened.
            reporter.report(store: Self.storeName, operation: .write, url: recentsURL, error: error)
        }
    }
}
