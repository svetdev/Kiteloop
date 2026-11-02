import Foundation

/// Every project in the portfolio's backlog, read together.
///
/// **Read-only by construction.** Nothing here opens a file for writing, and
/// the whole result is plain `Sendable` data holding no reference to a
/// `BacklogViewModel`, so no caller can reach back through it to edit a
/// `BACKLOG.md`. That is the v0 promise, kept in the type rather than in a
/// comment on the screen.
///
/// It is also independent of what is *open*: the projects here come from
/// `PortfolioList`, so a portfolio reads the same whether its projects have
/// tabs in the window or not. `PortfolioSnapshot` answers the other question —
/// what the live registry is doing right now — and the two are deliberately not
/// the same source.
package struct PortfolioBacklogs: Sendable {

    /// The projects that produced a backlog, in the order `portfolio.md` names
    /// them.
    package let projects: [Project]

    /// The paths that produced none, and why. Carried rather than dropped: a
    /// project silently missing from the screen reads as a project with no work,
    /// and the two mean opposite things.
    package let skipped: [Skipped]

    package static let empty = PortfolioBacklogs(projects: [], skipped: [])

    /// One project's backlog.
    package struct Project: Identifiable, Sendable {
        /// The canonical root path — the same identity `KiteloopProject.id`
        /// uses, so a portfolio row and an open tab agree on which project they
        /// are about.
        package var id: String { path }
        package let name: String
        package let path: String
        /// The `BACKLOG.md` the items were read from. Detail paths resolve
        /// relative to its directory, not to the project root — see
        /// `detailURL(for:)`.
        package let backlogURL: URL
        /// Every item in the file, flattened across its epics and tagged with
        /// this project by virtue of living here.
        package let items: [Item]

        package func matching(_ filter: PortfolioStatusFilter) -> Project {
            Project(name: name, path: path, backlogURL: backlogURL,
                    items: items.filter { filter.matches($0.item.status) })
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(name: String, path: String, backlogURL: URL, items: [Item]) {
            self.name = name
            self.path = path
            self.backlogURL = backlogURL
            self.items = items
        }
    }

    /// A backlog item and the project it came from.
    ///
    /// The pair is the unit the screen deals in: an id is only unique within one
    /// backlog, and two projects can both hold `task-1`. Identity is the pair
    /// for exactly that reason — a portfolio-wide list keyed on the item id
    /// alone would collapse them into one row.
    package struct Item: Identifiable, Sendable {
        package var id: String { "\(projectPath)\u{0}\(item.id)" }
        package let projectPath: String
        package let item: BacklogItem
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(projectPath: String, item: BacklogItem) {
            self.projectPath = projectPath
            self.item = item
        }
    }

    /// A path in `portfolio.md` the screen has nothing to show for.
    package struct Skipped: Identifiable, Sendable {
        package var id: String { path }
        package let path: String
        package let reason: Reason

        package enum Reason: Sendable, Equatable {
            /// Nothing is at this path — an unmounted volume, a moved repo, a
            /// typo.
            case missingDirectory
            /// The directory is there, with no `BACKLOG.md` in its root.
            case noBacklogFile
            /// The file is there and its bytes could not be read — permissions,
            /// say. Bytes that are not UTF-8 still read, as U+FFFD.
            case unreadableBacklog
        }

        /// Phrased for whoever is editing `portfolio.md`, since that is the file
        /// they will fix it in.
        package var explanation: String {
            switch reason {
            case .missingDirectory: "No folder at this path"
            case .noBacklogFile: "No BACKLOG.md in this project"
            case .unreadableBacklog: "BACKLOG.md could not be read"
            }
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(path: String, reason: Reason) {
            self.path = path
            self.reason = reason
        }
    }

    // MARK: - Loading

    /// Read every path in the list.
    ///
    /// `nonisolated` and synchronous on purpose: it touches the disk once per
    /// project, so it is called off the main actor (see `PortfolioViewModel.
    /// reload`) and hands back finished data rather than doing its I/O where the
    /// UI is drawn.
    ///
    /// A path that yields nothing is skipped with a reason and the read
    /// continues — one moved repo must not empty the whole screen.
    package static func load(paths: [String], fileManager: FileManager = .default) -> PortfolioBacklogs {
        var projects: [Project] = []
        var skipped: [Skipped] = []

        for path in paths {
            let rootURL = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                skipped.append(Skipped(path: path, reason: .missingDirectory))
                continue
            }

            let backlogURL = rootURL.appending(path: "BACKLOG.md")
            guard fileManager.fileExists(atPath: backlogURL.path(percentEncoded: false)) else {
                skipped.append(Skipped(path: path, reason: .noBacklogFile))
                continue
            }
            // Decoded lossily: one bad byte must not drop every item in the project.
            guard let data = try? Data(contentsOf: backlogURL) else {
                skipped.append(Skipped(path: path, reason: .unreadableBacklog))
                continue
            }
            let content = String(decoding: data, as: UTF8.self)

            // The existing parser, unchanged: a portfolio that read backlogs its
            // own way would eventually disagree with the project's own panel
            // about what an item says.
            let file = BacklogParser.parse(content)
            projects.append(Project(
                name: projectName(file: file, rootURL: rootURL),
                path: path,
                backlogURL: backlogURL,
                items: file.sections.flatMap(\.items).map { Item(projectPath: path, item: $0) }
            ))
        }

        return PortfolioBacklogs(projects: projects, skipped: skipped)
    }

    /// What to call a project on screen: the name its backlog frontmatter
    /// states, falling back to the folder. The frontmatter is what the project's
    /// own panel shows, and a folder named `src` or `main` says nothing.
    package static func projectName(file: BacklogFile, rootURL: URL) -> String {
        let stated = file.project.trimmingCharacters(in: .whitespaces)
        return stated.isEmpty ? rootURL.lastPathComponent : stated
    }

    // MARK: - Filtering

    /// The portfolio narrowed to one stage, across every project at once.
    ///
    /// Projects with no matching item are dropped rather than shown empty: a
    /// filter is a question about items, and a heading with nothing under it is
    /// noise in a list that is already several projects long.
    package func filtered(by filter: PortfolioStatusFilter) -> [Project] {
        projects.map { $0.matching(filter) }.filter { !$0.items.isEmpty }
    }

    /// How many items the portfolio holds in total, unfiltered.
    package var itemCount: Int { projects.reduce(0) { $0 + $1.items.count } }

    /// The stages that actually occur, in the order an item moves through them.
    ///
    /// What the filter control offers: a portfolio with nothing in review should
    /// not offer In Review as a choice that narrows to an empty screen.
    package var presentStatuses: [BacklogItemStatus] {
        let present = Set(projects.flatMap(\.items).map(\.item.status))
        return BacklogItemStatus.allCases.filter { present.contains($0) }
    }

    // MARK: - Detail files

    /// Where an item's groomed detail lives, or nil when it has none on disk.
    ///
    /// Resolved the way `BacklogViewModel.detailURL(for:)` resolves it —
    /// relative to the backlog file's directory — and then, for an item whose
    /// line carries no `→ [detail](…)` link, the `backlog/<id>.md` convention
    /// that `createDetail` writes to. Existence is checked because this screen
    /// only ever opens a detail file it can show: it does not create one.
    package static func detailURL(for item: BacklogItem, backlogURL: URL,
                          fileManager: FileManager = .default) -> URL? {
        let directory = backlogURL.deletingLastPathComponent()
        let candidates = [
            item.detailPath.map { directory.appending(path: $0) },
            directory.appending(path: "backlog/\(item.id).md")
        ].compactMap { $0 }
        return candidates.first {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(projects: [Project], skipped: [Skipped]) {
        self.projects = projects
        self.skipped = skipped
    }
}

/// What the Portfolio screen's stage control is set to.
///
/// `all` is a case rather than a nil filter so the control has something to
/// select and the screen has one type to reason about.
package enum PortfolioStatusFilter: Hashable, Identifiable, Sendable {
    case all
    case status(BacklogItemStatus)

    package var id: String {
        switch self {
        case .all: "all"
        case .status(let status): status.rawValue
        }
    }

    package var label: String {
        switch self {
        case .all: "All"
        case .status(let status): status.displayName
        }
    }

    package func matches(_ status: BacklogItemStatus) -> Bool {
        switch self {
        case .all: true
        case .status(let wanted): status == wanted
        }
    }

    /// The choices for a portfolio holding these stages — All, then whichever
    /// stages are actually in it.
    package static func choices(for statuses: [BacklogItemStatus]) -> [PortfolioStatusFilter] {
        [.all] + statuses.map { .status($0) }
    }
}
