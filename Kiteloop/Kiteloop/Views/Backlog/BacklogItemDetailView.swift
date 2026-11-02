import AppKit
import KiteloopCore
import SwiftUI

/// One backlog item, and everything that has happened to it.
///
/// The backlog lists an item as one line — id, title, status — and its life is
/// recorded in five places nobody joins: the run ledger, the item's Notes, the
/// approvals ledger, the grooming ledger, and git. This is the join, plus the
/// actions the item's state permits, so the answer and the next step are in the
/// same place.
///
/// It reads and never edits. Re-grooming opens the detail file; a transcript is
/// linked rather than inlined; and where a ledger and git disagree, both are
/// shown.
///
/// A **page**, not a sheet. It was a 720×620 modal floating over the backlog,
/// which is the wrong shape for the item's whole story: a run list, a checklist
/// and the groomed text do not fit in it, and a sheet cannot be reached from the
/// other places an item is named — the Autopilot queue and its run history,
/// where the display-only red row that started this had no answer at all. So it
/// fills the surface it is opened over and leaves by the Back control, and the
/// list underneath keeps its scroll position and selection because it is never
/// torn down (see `itemDetailPage`).
struct BacklogItemDetailView: View {
    let model: BacklogItemDetailViewModel
    var onClose: () -> Void

    @State private var rejectionReason = ""
    @State private var showingRejection = false
    /// Whether the verify row is open for editing, and what is typed in it.
    @State private var editingVerify = false
    @State private var verifyDraft = ""
    /// Whether the needs row is open for editing, and what is typed in it.
    @State private var editingNeeds = false
    @State private var needsDraft = ""
    /// Whether the first read has come back. The spinner belongs to the page's
    /// opening only: every read after it happens under a page that already has
    /// contents, and replacing them with a `ProgressView` every few seconds is
    /// worse than showing a row a moment stale.
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
                        if !model.disagreements.isEmpty { disagreementSection }
                        if model.showsReadiness { readinessSection }
                        gitSection
                        runsSection
                        timelineSection
                        lineSection
                        if model.groomPhase != .idle { groomSection }
                        groomedSection
                        notesSection
                    }
                    .padding(KiteloopTokens.Spacing.xl)
                    // Prose measure, then left-aligned in whatever the pane is:
                    // a page can be as wide as the window, and a paragraph of
                    // What running the full width of a 27" display is not
                    // readable at any font size.
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("item-detail-page")
        .task { await readWhileOpen() }
    }

    private static let refreshInterval: Duration = .seconds(3)

    /// Keeps the page up with the item it is about.
    ///
    /// The page used to be a snapshot taken when it was opened: a run that
    /// started, advanced a phase, reached its gate or appended to the item's
    /// Notes showed only after going Back and opening it again — and this is
    /// the surface an operator has open precisely while a run is going.
    /// `load()` re-reads every source and is cheap enough to call after each
    /// action, so the loop is nothing but calling it again. SwiftUI cancels the
    /// `.task` when the page is torn down, and that is what stops it — no
    /// timer, no observer.
    private func readWhileOpen() async {
        await model.load()
        hasLoaded = true
        guard !UITestingSupport.isUnitTesting else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            await model.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                // The way out of a page, in the place and the words a page's way
                // out lives — a sheet's "Done" read as "I have finished with this
                // item", which is not what closing it means.
                Button {
                    onClose()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("item-detail-back")
                .help("Back to the list")
                Text(model.item.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: KiteloopTokens.Spacing.md)
            }
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text(model.item.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let gate = model.gateState {
                    // The gate is a step, not a status: verifying, waiting on
                    // you, or refused — with the reason on the refusal.
                    pill(gate.line(now: Date()),
                         color: gate.kind == .refused ? .red : (gate.kind == .verifying ? .orange : .blue))
                        .accessibilityIdentifier("item-detail-gate-state")
                } else {
                    pill(model.item.status.displayName, color: .blue)
                }
                if let size = model.item.size { pill(size.rawValue, color: .purple) }
                if let epic = model.detail?.epic { pill(epic, color: .gray) }
                Spacer()
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    // MARK: - Disagreements

    /// Ledger against git, side by side. Shown first because it is the one thing
    /// on this screen that says something is wrong.
    private var disagreementSection: some View {
        section("Ledger and git disagree", icon: "exclamationmark.triangle.fill", tint: .orange) {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                ForEach(model.disagreements) { conflict in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(conflict.ledgerSays, systemImage: "doc.text")
                            .font(.callout)
                        Label(conflict.gitSays, systemImage: "arrow.triangle.branch")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(KiteloopTokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(KiteloopTokens.Opacity.light),
                        in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm))
        }
    }

    // MARK: - Readiness

    /// The Definition-of-Ready gate, clause by clause, above the history —
    /// where the eye lands on a draft that has no history yet. It is the one
    /// section about what happens next rather than what already happened, and an
    /// item autopilot will skip at pickup used to look exactly like one it will
    /// run.
    ///
    /// Every phrase comes from the verdict; nothing here decides anything.
    private var readinessSection: some View {
        section("Definition of Ready",
                icon: model.readiness.isReady ? "checkmark.seal" : "exclamationmark.triangle",
                tint: model.readiness.isReady ? .secondary : .orange,
                // What the gate decides, and only that: a met checklist does not
                // promise a run, since the stage, the retry ceiling and the
                // assigned roles each withhold an item on their own — which is
                // what Run's own tooltip is for.
                trailing: model.readiness.isReady
                    ? "every clause met"
                    : "autopilot skips this item at pickup") {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                ForEach(model.readinessRows) { row in
                    readinessRow(row)
                }
            }
            .accessibilityIdentifier("item-detail-readiness")
        }
    }

    private func readinessRow(_ row: ItemReadinessRow) -> some View {
        HStack(alignment: .top, spacing: KiteloopTokens.Spacing.md) {
            Image(systemName: row.isMet ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(row.isMet ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.clause)
                    .font(.callout)
                    .foregroundStyle(row.isMet ? .secondary : .primary)
                // The gate's own sentence when unmet, so what to do is on the
                // row that says it is undone.
                if let text = row.unmet ?? row.note {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Git

    private var gitSection: some View {
        section("Git, right now", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                Text(model.git.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                if let path = model.git.worktreePath {
                    HStack(spacing: KiteloopTokens.Spacing.sm) {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                if model.git.isUnreadable {
                    Text("Nothing here is a claim about the work — a project with no repository leaves every one of these questions open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Runs

    /// Every run this item has had, newest first — the whole reason the detail is
    /// a page. A history row said `blocked` in red and the sentence explaining it
    /// was only in `control-runs.jsonl`; here the reason is on the row.
    private var runsSection: some View {
        section("Runs", icon: "clock.arrow.circlepath",
                trailing: model.runRows.isEmpty ? nil : model.runsSummary.text) {
            if model.runRows.isEmpty {
                emptyRuns
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = model.runsSummary.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, KiteloopTokens.Spacing.sm)
                    }
                    ForEach(model.runRows) { run in
                        runRow(run)
                        if run.id != model.runRows.last?.id { Divider() }
                    }
                }
                .accessibilityIdentifier("item-detail-runs")
            }
        }
    }

    /// An item nobody has run yet. `PanelEmptyState`'s copy rules applied in
    /// place — this is a section inside a page, not a surface with room for the
    /// centred view — so it says what will appear here and names the control
    /// that fills it, rather than leaving the section blank.
    private var emptyRuns: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No runs yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The first time autopilot picks this item up, the run lands here with its time, cost, outcome and branch. Press Run below to start one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("item-detail-runs-empty")
    }

    private func runRow(_ run: ItemRunHistory.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            runSummaryRow(run)
            // The reason, on the row that failed. This is the sentence that used
            // to live only in the run-record file.
            if let reason = run.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            roundsDetail(run)
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text(evidence(run))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let retries = run.reviewerRetries, retries > 0 {
                    Text("\(retries) rework loop\(retries == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = run.pullRequestURL, let link = URL(string: url) {
                    Link("Pull request", destination: link)
                        .font(.caption)
                        .help(url)
                }
                if model.transcriptURL(for: run) != nil {
                    Button("Transcript") { model.revealTranscript(for: run) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Reveal this run's transcript directory in Finder. It is linked rather than shown — a run's transcript is far larger than this panel.")
                }
            }
        }
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The date, pass/fail, outcome, branch, duration, cost and quality pill —
    /// split out of `runRow` only to hold it under the complexity gate's line
    /// ceiling; the row reads exactly as it did before the split.
    private func runSummaryRow(_ run: ItemRunHistory.Row) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Image(systemName: run.isPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(run.isPass ? Color.green : Color.red)
            Text(run.outcome)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: KiteloopTokens.Spacing.md)
            if let link = model.branchLink(for: run) {
                branchChip(link)
            }
            // A dash, and a tooltip saying nobody measured it — rather than
            // `0:00` and `$0.00`, which are what a run that took no time and
            // cost nothing would read as. They are different facts.
            Text(run.durationSeconds.map(duration) ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help(run.durationSeconds == nil ? "Nothing measured how long this run took" : "How long the run took")
            Text(run.costUSD.map(ItemRunHistory.money) ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help(run.costUSD == nil ? "Nothing measured what this run cost" : "What the run cost")
            qualityPill(run)
        }
    }

    /// The judge's score, or `unscored` and why — nothing for a run nobody
    /// judged (`ItemRunHistory.Row.qualityMark`).
    @ViewBuilder
    private func qualityPill(_ run: ItemRunHistory.Row) -> some View {
        switch run.qualityMark {
        case .scored(let percent)?:
            pill(percent, color: .green)
                .help(judgeHelp(run))
        case .unscored(let why)?:
            pill("unscored", color: .gray).help("No quality score: \(why)")
        case nil:
            EmptyView()
        }
    }

    /// The branch a run left behind, with the ways of getting to it behind a
    /// menu — the same chip and the same read-only actions the Autopilot history
    /// rows carry, so a branch offers the same things wherever it is named.
    private func branchChip(_ link: BacklogAutopilot.BranchLink) -> some View {
        Menu {
            Button("Copy Branch Name") { copyToPasteboard(link.branch) }
            Button("Copy Checkout Command") { copyToPasteboard("git checkout \(link.branch)") }
            if let path = link.worktreePath {
                Divider()
                Button("Reveal Worktree in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(link.shortName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.gray.opacity(KiteloopTokens.Opacity.light)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("item-detail-branch-chip")
        .help(link.worktreePath == nil
              ? "Branch \(link.branch) — the worktree is gone; check the branch out to see the work."
              : "Branch \(link.branch) — its worktree is still on disk for inspection.")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The run's review rounds, one line each — reject, pass, made
    /// readable without opening the transcript. Nothing at all for a run whose
    /// only round passed (`showsRoundDetail`): the page must not grow to repeat
    /// the outcome already on the row above it.
    @ViewBuilder
    private func roundsDetail(_ run: ItemRunHistory.Row) -> some View {
        if run.showsRoundDetail {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(run.rounds.enumerated()), id: \.offset) { _, round in
                    HStack(spacing: KiteloopTokens.Spacing.sm) {
                        Text(round.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        pill(round.verdict.rawValue, color: roundColor(round.verdict))
                        if let detail = roundCountDetail(round) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func roundColor(_ verdict: ReviewRound.Verdict) -> Color {
        switch verdict {
        case .passed: return .green
        case .rejected: return .red
        case .unreadable: return .gray
        }
    }

    /// The count worth putting beside a round's pill — blocking findings on a
    /// rejection — or nil where the verdict alone already says everything the
    /// round has to say.
    private func roundCountDetail(_ round: ReviewRound) -> String? {
        switch round.verdict {
        case .rejected where round.blockingCount > 0:
            return "\(round.blockingCount) blocking"
        default:
            return nil
        }
    }

    /// What the run left behind, in the words the ledger records it in — and
    /// "nobody could tell" where that is the honest answer.
    private func evidence(_ run: ItemRunHistory.Row) -> String {
        switch run.workEvidence {
        case .produced:
            let files = run.changedFileCount.map { "\($0) file\($0 == 1 ? "" : "s") changed" }
                ?? "work recorded"
            return files
        case .empty:
            return "left no work behind"
        case .unknown:
            // `unknown` beside a file count is the run that reached no verdict
            // (`TaskMetricRecord.outcomesReachingNoVerdict`): the files were
            // measured, so saying nothing was would contradict the count shown
            // next to it — what is missing is anyone's judgement of them.
            if let count = run.changedFileCount, count > 0 {
                return "\(count) file\(count == 1 ? "" : "s") changed, but the run reached no verdict"
            }
            return "nothing measured what this run left"
        case nil:
            // A control record with no measurement beside it. It knows the run
            // happened and nothing about what came of it.
            return "no measurement was recorded for this run"
        }
    }

    private func judgeHelp(_ run: ItemRunHistory.Row) -> String {
        guard let dimensions = run.judgeDimensions, !dimensions.isEmpty else {
            return "Quality score (advisory)"
        }
        return dimensions.sorted { $0.key < $1.key }
            .map { "\($0.key): \(String(format: "%.0f%%", $0.value * 100))" }
            .joined(separator: " · ")
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        section("State changes", icon: "list.bullet.rectangle") {
            if model.changes.isEmpty {
                Text("Nothing has been recorded against this item yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                    ForEach(model.changes) { change in
                        HStack(alignment: .top, spacing: KiteloopTokens.Spacing.md) {
                            Text(stamp(change))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: KiteloopTokens.Spacing.sm) {
                                    Text(change.kind.rawValue)
                                        .font(.caption.weight(.semibold))
                                    Text(change.source.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                if let detail = change.detail {
                                    Text(detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// A note carries a date and no clock, so it prints one — a time invented
    /// for it would be the only made-up number on the screen.
    private func stamp(_ change: ItemStateChange) -> String {
        switch change.precision {
        case .day:
            return change.at.formatted(.dateTime.year().month(.abbreviated).day())
        case .instant:
            return change.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    // MARK: - The backlog line

    /// The fields on the item's own line in `BACKLOG.md` — the ones the header's
    /// pills don't carry. `verify:` is what the run is judged by and `needs:` is
    /// what withholds it, and both were readable only by opening the file.
    ///
    /// The verify and needs rows are always drawn — reading "none" on an item
    /// without one — so either can be added here as well as changed.
    private var lineSection: some View {
        section("On the backlog line", icon: "text.line.first.and.arrowtriangle.forward") {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("verify:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if editingVerify { verifyEditField } else { verifyReadRow }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("needs:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if editingNeeds { needsEditField } else { needsReadRows }
                }
                lineageRows
            }
        }
    }

    private var verifyReadRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.md) {
            Text(model.item.verify ?? "none")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.item.verify == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Edit") {
                verifyDraft = model.item.verify ?? ""
                model.clearVerifyRefusal()
                editingVerify = true
            }
            .controlSize(.small)
        }
    }

    /// The line's `verify:` as one editable command. A refusal keeps the field
    /// open, draft intact, over the reason — as the backlog row's rename does.
    /// When the detail file has a groomed Verify list, a run executes that list
    /// and reads the line only when it is empty, so the field says so.
    private var verifyEditField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                TextField("verify command", text: $verifyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { commitVerify() }
                Button("Save") { commitVerify() }
                    .controlSize(.small)
                Button("Cancel") { editingVerify = false }
                    .controlSize(.small)
            }
            if let refusal = model.verifyRefusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
            }
            if model.detail?.verifyCommands.isEmpty == false {
                Text("A run executes the groomed Verify list shown under “As groomed”, not this line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitVerify() {
        guard model.setVerify(verifyDraft) else { return }
        editingVerify = false
    }

    @ViewBuilder
    private var needsReadRows: some View {
        ForEach(model.dependencies, id: \.id) { dependencyRow($0) }
        HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.md) {
            if model.item.needs.isEmpty {
                Text("none").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button("Edit") {
                needsDraft = model.item.needs.joined(separator: ", ")
                model.clearNeedsRefusal()
                editingNeeds = true
            }
            .controlSize(.small)
        }
    }

    /// The line's `needs:` as ids separated by spaces or commas; an empty field
    /// clears them. A refusal — an unknown id, the item itself, a loop — keeps
    /// the field open, draft intact, over the reason, as the verify field does.
    private var needsEditField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                TextField("item ids, separated by spaces or commas", text: $needsDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { commitNeeds() }
                Button("Save") { commitNeeds() }
                    .controlSize(.small)
                Button("Cancel") { editingNeeds = false }
                    .controlSize(.small)
            }
            if let refusal = model.needsRefusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func commitNeeds() {
        guard model.setNeeds(needsDraft) else { return }
        editingNeeds = false
    }

    /// The item's `from:` parent, and every item split out of it — each a link
    /// with its status, read the same way `needs:` is.
    @ViewBuilder
    private var lineageRows: some View {
        if let origin = model.origin {
            VStack(alignment: .leading, spacing: 2) {
                Text("from:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                dependencyRow(origin)
            }
        }
        if !model.children.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("split into:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.children, id: \.id) { dependencyRow($0) }
            }
        }
    }

    /// One id the item waits on: a link to its page and its current status, or
    /// "not in the backlog" — with no link — when nothing by that id is left.
    @ViewBuilder
    private func dependencyRow(_ dependency: BacklogItemDetailViewModel.Dependency) -> some View {
        let id = Text(dependency.id)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            if let status = dependency.status {
                ItemLink(dependency.id, in: .path(model.projectPath)) { id }
                if status == .done {
                    Label(status.displayName, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text(status.displayName).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                id
                Text("not in the backlog").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Notes

    /// The item's `## Notes`, as written. The timeline above reads the same
    /// section for the state changes it can recognise; this is everything else
    /// in it — a reviewer's feedback for the next run, most of all.
    ///
    /// Drawn for every item, notes or none, because it is also where a person
    /// adds one for the next run; an item with no detail file says it has
    /// nowhere to put one instead.
    private var notesSection: some View {
        section("Notes", icon: "note.text") {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                if let notes = model.detail?.notes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(GroomedText.attributed(notes))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("item-detail-notes")
                }
                ItemNoteComposer(model: model)
            }
        }
    }

    // MARK: - Groom proposal

    /// The one agent pass over a draft, and where it stands. Hidden entirely
    /// at `.idle` — the caller only mounts this section once a pass has
    /// actually started, so an item nobody has groomed shows nothing here.
    @ViewBuilder
    private var groomSection: some View {
        switch model.groomPhase {
        case .idle:
            EmptyView()
        case .thinking:
            section("Grooming…", icon: "wand.and.stars") {
                HStack(spacing: KiteloopTokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading the repo and drafting a groomed detail…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("item-detail-groom-thinking")
        case .review(let proposal):
            groomProposalSection(proposal)
        case .error(let message):
            section("Groom failed", icon: "exclamationmark.triangle", tint: .orange) {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { model.discardGroom() }
                        .controlSize(.small)
                }
            }
            .accessibilityIdentifier("item-detail-groom-error")
        }
    }

    /// The previewed grooming — What, How, Validation, Out of Scope, `verify:`
    /// and size, plus what the repo says about it — with nothing written until
    /// Apply is pressed. The same preview-then-apply shape every other AI
    /// backlog edit already uses.
    private func groomProposalSection(_ proposal: BacklogGroomer.Proposal) -> some View {
        section("Proposed grooming", icon: "wand.and.stars",
                tint: proposal.readiness.isReady ? .secondary : .orange,
                trailing: proposal.readiness.isReady
                    ? "meets the Definition of Ready"
                    : "some clauses still unmet") {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
                prose("What", proposal.draft.what)
                prose("How", proposal.draft.how)
                bullets("Validation", proposal.draft.validation)
                bullets("Out of scope", proposal.draft.outOfScope)
                VStack(alignment: .leading, spacing: 2) {
                    Text("verify:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(proposal.draft.verify)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Size \(proposal.draft.size.uppercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                groomGroundingNotice(proposal)
                HStack {
                    Button("Discard") { model.discardGroom() }.controlSize(.small)
                    Spacer()
                    Button("Apply") { model.applyGroom() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("item-detail-groom-apply")
                }
            }
        }
        .accessibilityIdentifier("item-detail-groom-proposal")
    }

    /// What `GroundingCheck` found unresolved — a claimed path, symbol or
    /// executable the repo doesn't bear out. Shown, not blocked: the human
    /// reading the preview decides whether to apply it anyway, same as every
    /// other AI proposal here.
    @ViewBuilder
    private func groomGroundingNotice(_ proposal: BacklogGroomer.Proposal) -> some View {
        if !proposal.grounding.isGrounded {
            VStack(alignment: .leading, spacing: 2) {
                Text("Grounding check").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                ForEach(proposal.grounding.unresolved, id: \.text) { reference in
                    Text(reference.note ?? "\(reference.kind.rawValue) `\(reference.text)` is unresolved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Groomed content

    private var groomedSection: some View {
        section("As groomed", icon: "doc.text") {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
                    prose("What", detail.what ?? detail.why)
                    prose("How", detail.approach)
                    bullets("Validation", detail.acceptanceCriteria)
                    bullets("Out of scope", detail.outOfScope)
                    if !detail.verifyCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verify").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(detail.verifyCommands, id: \.cmd) { command in
                                Text("\(command.name): \(command.cmd)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                Text("No detail file — this item has no groomed What / How / Validation, which is also why autopilot will not pick it up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func prose(_ title: String, _ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(GroomedText.attributed(text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func bullets(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { line in
                    Text(AttributedString("• ") + GroomedText.attributed(line))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Actions

    /// Every action, always — an unavailable one is disabled and says why in its
    /// tooltip, because a hidden action is indistinguishable from one that does
    /// not exist.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            if let note = model.actionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: KiteloopTokens.Spacing.md) {
                ForEach(model.actions) { action in
                    actionButton(action)
                }
                Spacer()
                if model.isActing { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    private func actionButton(_ action: ItemAction) -> some View {
        Button {
            perform(action.kind)
        } label: {
            Label(action.kind.label, systemImage: action.kind.icon)
                .font(.caption)
        }
        .controlSize(.small)
        .disabled(!action.isAvailable || model.isActing)
        .help(action.unavailable ?? action.kind.label)
        .accessibilityIdentifier("item-detail-action-\(action.kind.rawValue)")
        .popover(isPresented: Binding(
            get: { showingRejection && action.kind == .reject },
            set: { if !$0 { showingRejection = false } }
        )) {
            rejectionPopover
        }
    }

    private var rejectionPopover: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Send back with feedback").font(.headline)
            Text("Whatever you write here lands in the item's Notes and is what the next worker run reads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $rejectionReason)
                .font(.callout)
                .frame(width: 360, height: 90)
                .overlay(RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                    .strokeBorder(Color.gray.opacity(KiteloopTokens.Opacity.medium)))
            HStack {
                Spacer()
                Button("Cancel") { showingRejection = false }
                    .controlSize(.small)
                Button("Reject") {
                    showingRejection = false
                    let reason = rejectionReason
                    rejectionReason = ""
                    Task { await model.resolveGate(approve: false, reason: reason) }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func perform(_ kind: ItemAction.Kind) {
        switch kind {
        case .run, .cancel, .approve, .reject:
            performRunAction(kind)
        case .unblock, .release, .regroom, .groom, .promote:
            performGroomingAction(kind)
        }
    }

    /// The four actions about a run itself: starting one, stopping one, and
    /// the human gate at its far end.
    private func performRunAction(_ kind: ItemAction.Kind) {
        switch kind {
        case .run: Task { await model.run() }
        case .cancel: Task { await model.cancel() }
        case .approve: Task { await model.resolveGate(approve: true) }
        case .reject: showingRejection = true
        default: break
        }
    }

    /// The five actions about the item's own shape rather than a run in
    /// flight: lifting a block, releasing a retirement, and the three ways a
    /// draft becomes something a run could pick up.
    private func performGroomingAction(_ kind: ItemAction.Kind) {
        switch kind {
        case .unblock: Task { await model.unblock() }
        case .release: Task { await model.release() }
        case .regroom: model.regroom()
        case .groom: Task { await model.groom() }
        case .promote: Task { await model.promote() }
        default: break
        }
    }

    // MARK: - Shared

    private func section<Content: View>(_ title: String, icon: String,
                                        tint: Color = .secondary,
                                        trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if let trailing {
                    Text(trailing).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(KiteloopTokens.Opacity.medium), in: Capsule())
            .foregroundStyle(color)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension View {

    /// Presents the item page over this surface, and hands the surface back when
    /// Back is pressed.
    ///
    /// An overlay rather than a `NavigationStack` push, deliberately: the list
    /// underneath stays mounted, so its scroll position, its selection and its
    /// collapsed groups are exactly where they were on the way back — a push
    /// takes the root out of the hierarchy and the round trip lands at the top of
    /// the list, which for a long backlog is the same as losing your place. The
    /// surface below is hidden from accessibility while the page is up so it
    /// reads as one screen rather than two stacked ones.
    ///
    /// - Parameter model: the item to show, or nil for no page.
    @ViewBuilder
    func itemDetailPage(_ model: BacklogItemDetailViewModel?,
                        onBack: @escaping () -> Void) -> some View {
        ZStack {
            self
                .accessibilityHidden(model != nil)
                .disabled(model != nil)
            if let model {
                BacklogItemDetailView(model: model, onClose: onBack)
                    // Identity is the item: opening a second one from within the
                    // page (there is nowhere that does yet) would rebuild it
                    // rather than leave the first item's sections on screen.
                    .id(model.id)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
            }
        }
    }

    /// Opens an item's page when the row is clicked, where the row's click means
    /// nothing else.
    ///
    /// A gesture rather than a `Button`: these rows carry branch menus and
    /// quality badges, and wrapping controls inside a control is how the inner
    /// ones stop answering. `enabled` is false for an item the page cannot be
    /// built for — a history row outlives the item it names — and then the row
    /// keeps its tooltip, which says why, instead of silently doing nothing.
    func openItemOnTap(_ itemID: String,
                       enabled: Bool,
                       open: @escaping (String) -> Void) -> some View {
        onTapGesture { if enabled { open(itemID) } }
    }
}

/// The Notes section's Add Note control: a note for the next worker run,
/// written from the page rather than only by rejecting a run at the gate.
///
/// The field closes only when the note landed — a blank note, or one the
/// detail file refused, leaves it open over what was typed.
private struct ItemNoteComposer: View {
    let model: BacklogItemDetailViewModel

    @State private var isOpen = false
    @State private var draft = ""

    var body: some View {
        if model.item.detailPath == nil {
            Text("A note needs a groomed detail file — this item has none to write it to yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("item-detail-note-no-detail")
        } else if isOpen {
            field
        } else {
            Button("Add Note") { isOpen = true }
                .controlSize(.small)
                .accessibilityIdentifier("item-detail-add-note")
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            Text("Whatever you write here lands in the item's Notes and is what the next worker run reads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.callout)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                    .strokeBorder(Color.gray.opacity(KiteloopTokens.Opacity.medium)))
                .accessibilityIdentifier("item-detail-note-field")
            HStack {
                Spacer()
                Button("Cancel") { isOpen = false }
                    .controlSize(.small)
                Button("Save Note") { save() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        let text = draft
        Task {
            guard await model.addNote(text) else { return }
            draft = ""
            isOpen = false
        }
    }
}
