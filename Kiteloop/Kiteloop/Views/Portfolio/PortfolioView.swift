import KiteloopCore
import SwiftUI

/// Every project's backlog in one list.
///
/// The consolidation surface: each project's work lives in its own root
/// `BACKLOG.md`, and until this screen there was nowhere to see them together.
/// Which projects it reads is `~/.kiteloop/portfolio.md` — a plain list of
/// paths, edited by hand, reflected here as it changes.
///
/// **Read-only, v0.** There is no control here that writes to a `BACKLOG.md`,
/// and the model behind it (`PortfolioBacklogs`) cannot: it is plain data, not
/// a `BacklogViewModel`. Editing an item and dispatching one to autopilot are
/// both deliberately absent — a portfolio-wide edit surface is a different
/// decision from a portfolio-wide *view*, and this is the view.
struct PortfolioView: View {
    @Bindable var viewModel: PortfolioViewModel

    /// The projects open in the window right now, offered as a starting point
    /// when no `portfolio.md` exists yet. The file stays the source of truth —
    /// this only writes the first draft of it.
    var openProjectPaths: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = viewModel.selectedItem {
                PortfolioItemDetailView(
                    item: item.item,
                    projectName: viewModel.project(for: item)?.name ?? item.projectPath,
                    detail: viewModel.selectedDetail,
                    detailURL: viewModel.selectedDetailURL,
                    onClose: { viewModel.selectedItem = nil }
                )
            } else if viewModel.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.teal)
            Text("Portfolio").font(.headline)

            // The pair, always: a narrowed list showing "12 items" reads as a
            // portfolio holding twelve.
            Text(countSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.backlogs.projects.isEmpty {
                Picker("Stage", selection: $viewModel.filter) {
                    ForEach(viewModel.filterChoices) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("portfolio-status-filter")
            }

            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-read every project's backlog")
            .accessibilityIdentifier("portfolio-refresh")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    private var countSummary: String {
        let visible = viewModel.visibleItemCount
        let total = viewModel.totalItemCount
        let projects = viewModel.backlogs.projects.count
        let projectPart = "\(projects) project\(projects == 1 ? "" : "s")"
        return visible == total
            ? "\(projectPart) · \(total) item\(total == 1 ? "" : "s")"
            : "\(projectPart) · \(visible) of \(total) items"
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.visibleProjects) { project in
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(project.items) { entry in
                                PortfolioItemRow(
                                    item: entry.item,
                                    action: { viewModel.selectedItem = entry }
                                )
                            }
                        }
                    } header: {
                        projectHeader(project)
                    }
                }

                if !viewModel.backlogs.skipped.isEmpty { skippedSection }
                listFooter
            }
            .padding(KiteloopTokens.Spacing.xl)
        }
    }

    private func projectHeader(_ project: PortfolioBacklogs.Project) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text(project.name)
                .font(.system(.subheadline, weight: .semibold))
            Text("\(project.items.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(project.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(project.path)
        }
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .background(.background)
    }

    /// The paths that produced nothing. Named rather than dropped: a project
    /// that has quietly vanished from the screen looks exactly like a project
    /// with no work left.
    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            Text("Not shown")
                .font(.system(.subheadline, weight: .semibold))
            ForEach(viewModel.backlogs.skipped) { skipped in
                HStack(spacing: KiteloopTokens.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(skipped.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(skipped.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, KiteloopTokens.Spacing.md)
    }

    private var listFooter: some View {
        Text("Read from \(viewModel.listPath)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .padding(.top, KiteloopTokens.Spacing.md)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(viewModel.hasNoList ? "No portfolio yet" : "Nothing to show")
                .font(.headline)
            Text(emptyExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if viewModel.hasNoList, !openProjectPaths.isEmpty {
                Button("Create from \(openProjectPaths.count) open project\(openProjectPaths.count == 1 ? "" : "s")") {
                    viewModel.seedList(from: openProjectPaths)
                }
                .accessibilityIdentifier("portfolio-seed")
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            // The skipped paths are the whole explanation when a file exists and
            // every project in it failed, so they belong in the empty state too.
            if !viewModel.backlogs.skipped.isEmpty {
                skippedSection.frame(maxWidth: 460, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(KiteloopTokens.Spacing.xl)
    }

    private var emptyExplanation: String {
        viewModel.hasNoList
            ? "List one project root per line in \(viewModel.listPath) to see their backlogs together."
            : "\(viewModel.listPath) names \(viewModel.listedPaths.count) path\(viewModel.listedPaths.count == 1 ? "" : "s"), and none of them has a BACKLOG.md to read."
    }
}

/// One item's row. Read-only: the whole row is a button that opens the item's
/// detail, and there is no status control on it — the project's own Backlog
/// panel is where an item is edited.
private struct PortfolioItemRow: View {
    let item: BacklogItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                PortfolioStatusIcon(status: item.status)
                Text(item.title)
                    .font(.callout)
                    // Finished work is visibly finished, the same way the
                    // project's own panel draws it.
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                    .strikethrough(item.status == .done)
                    .lineLimit(1)
                Text(item.id)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: KiteloopTokens.Spacing.md)
                if let size = item.size {
                    PortfolioPill(text: size.rawValue, color: .secondary)
                }
                PortfolioPill(text: item.status.displayName,
                              color: PortfolioStatusIcon.style(item.status).tint)
            }
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.sm)
            .background(isHovering ? KiteloopTokens.Sidebar.hoverBg : .clear,
                        in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("portfolio-item-\(item.id)")
    }
}

/// The stage icon, spelled the same way the project's own backlog panel spells
/// it — two surfaces drawing one item in two colours is its own bug.
struct PortfolioStatusIcon: View {
    let status: BacklogItemStatus

    static func style(_ status: BacklogItemStatus) -> (icon: String, tint: Color) {
        switch status {
        case .done: ("checkmark.circle.fill", .green)
        case .awaitingApproval: ("hand.raised.circle.fill", .orange)
        case .inReview: ("magnifyingglass.circle.fill", .purple)
        case .active: ("play.circle.fill", .blue)
        case .blocked: ("nosign", .red)
        case .draft: ("pencil.circle", .gray)
        case .ready: ("circle", .secondary)
        }
    }

    var body: some View {
        let style = Self.style(status)
        Image(systemName: style.icon)
            .foregroundStyle(style.tint)
            .font(.system(size: 13))
            .help(status.displayName)
    }
}

private struct PortfolioPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(KiteloopTokens.Opacity.medium), in: Capsule())
            .foregroundStyle(color)
    }
}

/// One item's groomed detail, read from its `backlog/<id>.md`.
///
/// A separate page from `BacklogItemDetailView` on purpose. That one joins an
/// item's runs, approvals and git history and offers the actions its state
/// permits — all of which need the project's live session, autopilot and metric
/// index. A portfolio lists projects that need not be open at all, so this shows
/// what the detail *file* says and nothing it cannot stand behind.
private struct PortfolioItemDetailView: View {
    let item: BacklogItem
    let projectName: String
    let detail: BacklogItemDetail?
    let detailURL: URL?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
                    if let detail {
                        section("What", body: detail.what)
                        section("How", body: detail.approach)
                        section("Why", body: detail.why)
                        checklist("Validation", detail.acceptanceCriteria)
                        checklist("Out of scope", detail.outOfScope)
                        verifySection(detail)
                        section("Context", body: detail.context)
                        section("Notes", body: detail.notes)
                    } else {
                        noDetailState
                    }
                    if let detailURL {
                        Text(detailURL.path(percentEncoded: false))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(KiteloopTokens.Spacing.xl)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.lg) {
            Button(action: onClose) {
                Label("Portfolio", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("portfolio-detail-back")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                Text("\(projectName) · \(item.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PortfolioStatusIcon(status: item.status)
            Text(item.status.displayName).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    /// An item with no detail file is ungroomed, not broken — say which file is
    /// missing rather than showing an empty page.
    private var noDetailState: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("No detail file").font(.headline)
            Text("This item has no `backlog/\(item.id).md`. Its backlog line is all there is.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let verify = item.verify {
                Text("verify: \(verify)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, body text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                Text(GroomedText.attributed(text)).font(.callout).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func checklist(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: KiteloopTokens.Spacing.md) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(GroomedText.attributed(line)).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func verifySection(_ detail: BacklogItemDetail) -> some View {
        let commands = detail.verifyCommands.map(\.cmd) + [item.verify].compactMap { $0 }
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                Text("Verify").font(.system(.subheadline, weight: .semibold))
                ForEach(Array(Set(commands)).sorted(), id: \.self) { cmd in
                    Text(cmd)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
