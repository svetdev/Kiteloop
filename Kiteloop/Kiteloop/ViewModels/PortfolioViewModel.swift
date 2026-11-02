import Foundation
import KiteloopCore
import os.log

private let portfolioLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "portfolio")

/// What the Portfolio screen shows: several projects' backlogs, read together.
///
/// **Read-only.** It loads `PortfolioBacklogs`, which cannot write, and the one
/// file it ever writes is `portfolio.md` itself — and only when the human asks
/// it to seed one. No `BACKLOG.md` is opened for writing on any path through
/// this type.
///
/// The reads happen off the main actor. This is a `@MainActor` `@Observable`
/// whose properties a SwiftUI body re-evaluates freely, and a portfolio is many
/// projects rather than one, so doing the per-project disk work inline would put
/// a growing synchronous read on the actor that draws the UI.
@Observable
@MainActor
final class PortfolioViewModel {

    /// The portfolio as of the last completed load.
    private(set) var backlogs: PortfolioBacklogs = .empty

    /// The paths `portfolio.md` named, whether or not they produced a backlog.
    /// Kept so the empty state can tell "no file yet" from "a file naming
    /// projects that all failed to load" — the second is not an empty portfolio.
    private(set) var listedPaths: [String] = []

    private(set) var isLoading = false

    /// True once a load has finished, so the screen shows its empty state rather
    /// than flashing it before the first read comes back.
    private(set) var hasLoaded = false

    /// What went wrong writing a seed file. Nil is the normal state.
    private(set) var errorMessage: String?

    /// The stage control. Narrows every project at once — that is the point of
    /// it living here rather than per-section.
    var filter: PortfolioStatusFilter = .all {
        didSet { clearSelectionIfFiltered() }
    }

    /// The item whose detail page is open, or nil when the list is showing.
    var selectedItem: PortfolioBacklogs.Item?

    private let listURL: URL
    private var watcher: BacklogFileWatcher?

    /// - Parameter listURL: the portfolio file. Injectable so a test drives a
    ///   temporary one rather than whatever this machine happens to have in
    ///   `~/.kiteloop/`.
    init(listURL: URL = PortfolioList.defaultURL) {
        self.listURL = listURL
    }

    /// The portfolio file being read, for the screen's footer — a screen that
    /// says "no projects" without saying which file it read leaves the reader
    /// nowhere to go.
    var listPath: String { listURL.path(percentEncoded: false) }

    // MARK: - Loading

    /// Start reading, and keep up with edits to `portfolio.md`.
    ///
    /// Watching the list file — not each project's backlog — is the deliberate
    /// scope for v0: the acceptance criterion is that editing the portfolio file
    /// is reflected, and one watcher per listed project is a cost that should
    /// follow a decision to pay it. The Refresh control re-reads everything.
    func start() {
        reload()
        guard watcher == nil else { return }
        // `BacklogFileWatcher` is named for its first caller but is a general
        // file watcher: it survives the write-to-temp + rename that every atomic
        // write (and every editor) performs, which a bare fd on the path does
        // not. It also picks the file up when it appears, so watching a
        // portfolio nobody has written yet is a legitimate state.
        let fileWatcher = BacklogFileWatcher { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
        fileWatcher.watch(url: listURL)
        watcher = fileWatcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-read the list and every project it names.
    func reload() {
        let url = listURL
        isLoading = true
        Task { [weak self] in
            let (paths, loaded) = await Task.detached(priority: .userInitiated) { () -> ([String], PortfolioBacklogs) in
                let paths = PortfolioList.load(from: url)
                return (paths, PortfolioBacklogs.load(paths: paths))
            }.value
            guard let self else { return }
            self.listedPaths = paths
            self.backlogs = loaded
            self.isLoading = false
            self.hasLoaded = true
            self.clearSelectionIfFiltered()
            portfolioLog.info(
                "Portfolio loaded: \(loaded.projects.count) projects, \(loaded.itemCount) items, \(loaded.skipped.count) skipped")
        }
    }

    // MARK: - Presentation

    /// The projects to draw, narrowed by the stage control.
    var visibleProjects: [PortfolioBacklogs.Project] { backlogs.filtered(by: filter) }

    /// The stage control's choices — All, plus the stages this portfolio holds.
    var filterChoices: [PortfolioStatusFilter] {
        PortfolioStatusFilter.choices(for: backlogs.presentStatuses)
    }

    /// How many items are on screen, against how many the portfolio holds. The
    /// pair is what keeps a filtered list from reading as the whole portfolio.
    var visibleItemCount: Int { visibleProjects.reduce(0) { $0 + $1.items.count } }
    var totalItemCount: Int { backlogs.itemCount }

    /// Nothing to show, and a finished load to say so with.
    var isEmpty: Bool { hasLoaded && backlogs.projects.isEmpty }

    /// True when no portfolio file has been written yet — the state the seed
    /// offer belongs to. A file that names only unreachable projects is a
    /// different problem, and the skipped list explains that one.
    var hasNoList: Bool { listedPaths.isEmpty }

    /// Where the selected item's groomed detail lives, or nil when it has none.
    var selectedDetailURL: URL? {
        guard let selected = selectedItem,
              let project = backlogs.projects.first(where: { $0.path == selected.projectPath })
        else { return nil }
        return PortfolioBacklogs.detailURL(for: selected.item, backlogURL: project.backlogURL)
    }

    /// The selected item's detail, parsed. Nil when it has no detail file, which
    /// is a legitimate state the page reports rather than treating as an error.
    var selectedDetail: BacklogItemDetail? {
        selectedDetailURL.flatMap { BacklogParser.parseDetail(at: $0) }
    }

    /// The project a given item belongs to.
    func project(for item: PortfolioBacklogs.Item) -> PortfolioBacklogs.Project? {
        backlogs.projects.first { $0.path == item.projectPath }
    }

    /// Drops a selection the current filter no longer shows, so narrowing the
    /// list cannot leave a detail page open on an item the list behind it does
    /// not contain.
    private func clearSelectionIfFiltered() {
        guard let selected = selectedItem else { return }
        if !filter.matches(selected.item.status) { selectedItem = nil }
    }

    // MARK: - Seeding

    /// Write a starter `portfolio.md` from the projects currently open.
    ///
    /// The one write this type makes, and it is the human's: the empty state
    /// offers it and nothing calls it otherwise. It refuses to overwrite an
    /// existing file — a portfolio somebody has edited is not something a button
    /// on an empty screen gets to replace.
    func seedList(from paths: [String]) {
        guard !FileManager.default.fileExists(atPath: listURL.path(percentEncoded: false)) else {
            errorMessage = "\(listURL.lastPathComponent) already exists — edit it by hand."
            return
        }
        let canonical = paths.map(KiteloopProject.canonicalPath)
        do {
            try FileManager.default.createDirectory(
                at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFileWriter.write(Data(PortfolioList.text(for: canonical).utf8), to: listURL)
            errorMessage = nil
            reload()
        } catch {
            portfolioLog.error("Failed to seed portfolio list: \(error.localizedDescription)")
            errorMessage = "Couldn't write \(listURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
