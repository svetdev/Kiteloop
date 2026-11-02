import KiteloopCore
import SwiftUI

/// The portfolio's per-project backlog editor: epics (backlog sections) as
/// collapsible groups with editable title/description and their child items.
/// Drives a standalone `BacklogViewModel`; every edit persists to `BACKLOG.md`.
struct EpicBacklogView: View {
    @Bindable var viewModel: BacklogViewModel
    let projectName: String
    let projectPath: String
    let aiEditor: BacklogAIEditor
    let scopingEngine: TaskScopingEngine
    let metricStore: TaskMetricStore
    /// The queryable projection of the run and approval ledgers, for the item
    /// detail view — which reads its history from here rather than re-walking
    /// the JSONL. Optional so a caller that has no index still gets the list.
    var metricIndex: MetricIndex?
    /// This project's autopilot, for the actions the detail view offers: run,
    /// cancel, and the approval gate. Optional for the same reason.
    var autopilot: BacklogAutopilot?
    /// Where a human release of the retry ceiling is written. Defaulted to the
    /// app-wide ledger so tests can point it somewhere disposable.
    var groomingLedger: GroomingLedger = .shared
    /// An item the window's open-item action asked this surface to show, set
    /// from anywhere in the app that names an item. This surface presents the
    /// page — so a page reached from a mention is the same page over the same
    /// list as one opened from the item's own row here, and Back lands on the
    /// backlog either way. Cleared to nil once the page is up, so pressing Back
    /// doesn't immediately reopen it.
    var openRequest: Binding<String?> = .constant(nil)
    /// Where a request this surface couldn't honour is reported, naming the id.
    /// The window resolves what it can before routing, but a project opened by
    /// the click itself has no parsed backlog to check against yet — so the last
    /// word on whether the item exists is here, and it must not be silence.
    var onOpenFailed: ((String) -> Void)? = nil
    /// When set, item rows offer "Run with Agent" (loads the item into the
    /// selected agent's input). nil hides the action.
    var onRun: ((BacklogItem) -> Void)? = nil
    /// Opens the Inspector drawer to the Insights tab. nil hides the button.
    var onShowInsights: (() -> Void)? = nil

    /// Whether finished items are drawn. On by default — 531 of this backlog's
    /// 626 items are `done`, so the default view was ~85% strikethrough.
    ///
    /// A *view* filter, deliberately, rather than moving finished items out of
    /// the file. `needs:` resolves against the items in `BACKLOG.md`, and an id
    /// that names nothing counts as **unmet** rather than as no dependency — so
    /// archiving a done item silently blocks whatever waits on it. Three open
    /// items point at done ones today, and they would have been the first
    /// casualties. Hiding a row costs nothing and breaks nothing.
    @AppStorage("backlogHidesCompleted") private var hidesCompleted = true

    /// Loaded from `collapseStore` for `projectPath`, and saved back on every
    /// toggle — as plain view state it reopened every epic on each project switch.
    @State private var collapsedEpics: Set<String> = []
    var collapseStore = CollapsedEpicsStore()
    @State private var editingEpicName: String?
    @State private var epicNameDraft = ""
    @State private var editingItemID: String?
    @State private var itemTitleDraft = ""
    @State private var editingDescriptionEpic: String?
    @State private var descriptionDraft = ""
    @State private var addingItemEpic: String?
    @State private var newItemTitle = ""
    @State private var showingAddEpic = false
    @State private var newEpicName = ""
    @State private var parseIssuesExpanded = false
    /// What the header's search field holds. A view filter like
    /// `hidesCompleted`: it narrows the rows drawn, never the counts.
    @State private var query = ""
    /// The epic whose Delete was chosen, held until the confirmation answers.
    /// Deleting an epic takes every item in it out of `BACKLOG.md` with no
    /// undo, so the menu click only asks — nothing is written until the
    /// destructive button is pressed.
    @State private var pendingDeleteEpic: String?
    /// The item whose Remove was chosen, held until the confirmation answers.
    /// Removing takes its line out of `BACKLOG.md` with no undo, so the menu
    /// click only asks.
    @State private var pendingRemoveItem: BacklogItem?
    /// The item whose detail page is open, and the model behind it. Built when
    /// the page opens rather than per row: it queries the metric index and git,
    /// which is not work to do for every line of a backlog.
    @State private var detailModel: BacklogItemDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.parseIssues.isEmpty {
                parseIssuesBanner
                Divider()
            }
            if let message = viewModel.operationMessage {
                operationMessageBanner(message)
                Divider()
            }
            content
            Divider()
            BacklogAIInputBar(editor: aiEditor, viewModel: viewModel, projectPath: projectPath)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A page over this whole surface, not a sheet floating on it — the list
        // stays mounted underneath, so Back lands where you left it.
        .itemDetailPage(detailModel) { detailModel = nil }
        // `initial: true` because switching projects mounts a fresh copy of this
        // view with the request already set — the cross-project case, where
        // waiting for a *change* would mean the request arrives before there is
        // anything to observe it.
        .onChange(of: projectPath, initial: true) { _, path in
            collapsedEpics = collapseStore.load(projectPath: path)
        }
        .onChange(of: openRequestKey, initial: true) { _, _ in
            guard let requested = openRequest.wrappedValue else { return }
            openRequestedItem(requested)
        }
        .confirmationDialog(
            "Delete this epic?",
            isPresented: Binding(
                get: { pendingDeleteEpic != nil },
                set: { if !$0 { pendingDeleteEpic = nil } }
            )
        ) {
            Button("Delete Epic", role: .destructive) {
                guard let name = pendingDeleteEpic else { return }
                pendingDeleteEpic = nil
                viewModel.deleteEpic(name: name)
            }
            Button("Cancel", role: .cancel) { pendingDeleteEpic = nil }
        } message: {
            let name = pendingDeleteEpic ?? ""
            let items = viewModel.backlogFile?.sections.first { $0.name == name }?.items.count ?? 0
            Text(Self.deleteEpicMessage(name: name, itemCount: items))
        }
        .confirmationDialog(
            "Remove this item?",
            isPresented: Binding(
                get: { pendingRemoveItem != nil },
                set: { if !$0 { pendingRemoveItem = nil } }
            )
        ) {
            Button("Remove Item", role: .destructive) {
                guard let item = pendingRemoveItem else { return }
                pendingRemoveItem = nil
                viewModel.removeItem(itemID: item.id)
            }
            Button("Cancel", role: .cancel) { pendingRemoveItem = nil }
        } message: {
            Text(Self.removeItemMessage(title: pendingRemoveItem?.title ?? "", id: pendingRemoveItem?.id ?? ""))
        }
    }

    /// What the Delete Epic confirmation says: the epic by name, and how many
    /// of its items go out of `BACKLOG.md` with it — the part of the action
    /// that the menu it was chosen from doesn't show.
    static func deleteEpicMessage(name: String, itemCount: Int) -> String {
        switch itemCount {
        case 0:
            "Deletes the epic “\(name)”, which holds no items. This can't be undone."
        case 1:
            "Deletes the epic “\(name)” and the 1 item in it. This can't be undone."
        default:
            "Deletes the epic “\(name)” and all \(itemCount) items in it. This can't be undone."
        }
    }

    /// What the Remove confirmation says: the item by title and id, since a
    /// backlog can hold two items with near-identical titles.
    static func removeItemMessage(title: String, id: String) -> String {
        "Removes “\(title)” (\(id)) from the backlog. This can't be undone."
    }

    /// The rows an item's Move Up and Move Down step over, taken from the ids
    /// the epic draws — so a hidden finished row is never the one swapped
    /// with. `previous` is nil on the first row, `next` on the last, and both
    /// for an id the list doesn't hold.
    static func moveNeighbours(of id: String, in shownIDs: [String]) -> (previous: String?, next: String?) {
        guard let index = shownIDs.firstIndex(of: id) else { return (nil, nil) }
        let previous = index > 0 ? shownIDs[index - 1] : nil
        let next = index + 1 < shownIDs.count ? shownIDs[index + 1] : nil
        return (previous, next)
    }

    /// Whether an item is drawn under the header's search: its title or id
    /// contains the query, ignoring case. A blank query matches everything.
    static func matchesQuery(title: String, id: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(needle) || id.localizedCaseInsensitiveContains(needle)
    }

    /// Whether an item's row is drawn under an epic. A search reaches finished
    /// items whatever 'Hide completed' says, so the id of something just merged
    /// still finds it; with a blank query the toggle applies as before.
    static func isShown(status: BacklogItemStatus, title: String, id: String,
                        hidesCompleted: Bool, query: String) -> Bool {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hidesCompleted, !searching, status == .done { return false }
        return matchesQuery(title: title, id: id, query: query)
    }

    private func matches(_ item: BacklogItem) -> Bool {
        Self.matchesQuery(title: item.title, id: item.id, query: query)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The pending request, plus whether the backlog file has been read.
    ///
    /// Both, because a click that *opened* the project arrives before the file
    /// is parsed: keyed on the request alone, the one retry that matters — the
    /// moment the backlog lands — would never fire.
    private var openRequestKey: String {
        "\(openRequest.wrappedValue ?? "")#\(viewModel.backlogFile == nil ? 0 : 1)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text(projectName)
                .font(.headline)
            if let file = viewModel.backlogFile {
                let items = file.sections.flatMap(\.items)
                let open = items.count { $0.status != .done }
                let done = items.count - open
                // Both numbers, always. "95 open" alone reads like the backlog
                // holds 95 items; the finished ones are the bulk of it and the
                // toggle below only makes sense next to how much it hides.
                Text("\(String(count: file.sections.count, noun: "epic")) · \(open) open · \(done) done")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if done > 0 {
                    Toggle(isOn: $hidesCompleted) {
                        Text("Hide completed").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Draw only the items still to do. A view filter: nothing is moved or removed, so `needs:` keeps resolving against finished items and the history stays where it is.")
                    .accessibilityIdentifier("backlog-hide-completed-toggle")
                }

                TextField("Search items", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .help("Show only the items whose title or id contains this text")
                    .accessibilityIdentifier("backlog-search-field")
            }
            Spacer()
            if let onShowInsights {
                Button {
                    onShowInsights()
                } label: {
                    Label("Insights", systemImage: "chart.bar")
                }
                .help("Task duration & cost insights")
            }
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload from disk")
            Button {
                showingAddEpic = true
                newEpicName = ""
            } label: {
                Label("Add Epic", systemImage: "plus")
            }
            .disabled(viewModel.backlogFile == nil)
            .popover(isPresented: $showingAddEpic) {
                addEpicPopover
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    // MARK: - Parse issues

    /// Lines the parser couldn't use. They're invisible in the list below and
    /// disappear from the file the next time an edit rewrites it, so the panel
    /// says so out loud and points at the line to fix.
    private var parseIssuesBanner: some View {
        let issues = viewModel.parseIssues
        let fileName = viewModel.backlogURL?.lastPathComponent ?? "BACKLOG.md"
        return VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(issues.count == 1
                     ? "1 line in \(fileName) couldn't be read"
                     : "\(issues.count) lines in \(fileName) couldn't be read")
                    .font(.callout.weight(.medium))
                Text("they're skipped, and lost when the backlog is next saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(parseIssuesExpanded ? "Hide" : "Show") {
                    parseIssuesExpanded.toggle()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                if let url = viewModel.backlogURL {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Show \(fileName) in Finder")
                }
            }

            if parseIssuesExpanded {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                            Text("Line \(issue.line) — \(issue.reason)")
                                .font(.caption)
                            Text(issue.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(KiteloopTokens.Opacity.light))
    }

    // MARK: - Refused edit

    /// The last edit the view model refused or couldn't write. The backlog is
    /// still loaded and still below this, so the message sits beside it rather
    /// than in place of it, and goes when the next edit lands.
    private func operationMessageBanner(_ message: String) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(KiteloopTokens.Opacity.light))
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage {
            centeredMessage(icon: "exclamationmark.triangle", title: error, tint: .orange)
        } else if viewModel.noBacklogFound {
            noBacklogState
        } else if let file = viewModel.backlogFile {
            if file.sections.isEmpty {
                emptyBacklogState
            } else {
                // Computed once for the whole list, not once per row: the cheap
                // pass is a single walk of the run ledger.
                let retired = retiredItemIDs(in: file)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
                        backlogList(file, retired: retired)
                    }
                    .padding(KiteloopTokens.Spacing.xl)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The Now lane and the epics. While searching, only the epics holding a
    /// match are drawn; when none does, one line says so in place of the list.
    /// Every Now match is also a match in its epic, so no epic left means
    /// nothing matched anywhere.
    @ViewBuilder
    private func backlogList(_ file: BacklogFile, retired: Set<String>) -> some View {
        let epics = isSearching ? file.sections.filter { !shown($0.items).isEmpty } : file.sections
        if isSearching, epics.isEmpty {
            noMatchesLine
        } else {
            nowSection(file, retired: retired)
            ForEach(epics) { epic in
                epicGroup(epic, retired: retired)
            }
        }
    }

    // MARK: - Now

    /// Every `now` item across the epics, in the order a run walks them — the
    /// run order, where the epics below are the map. Always drawn: an empty
    /// lane is a statement about the queue, not something to hide.
    @ViewBuilder
    private func nowSection(_ file: BacklogFile, retired: Set<String>) -> some View {
        let epicByItem = Dictionary(file.sections.flatMap { epic in epic.items.map { ($0.id, epic.name) } },
                                    uniquingKeysWith: { first, _ in first })
        let now = BacklogLane.ordered(file.sections.flatMap(\.items))
            .filter { $0.lane == .now && $0.status != .done && matches($0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text("Now")
                    .font(.system(.headline, weight: .semibold))
                Text("\(now.count) · run order")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, KiteloopTokens.Spacing.lg)
            .padding(.vertical, KiteloopTokens.Spacing.md)

            if now.isEmpty, isSearching {
                noMatchesLine
            } else if now.isEmpty {
                Text("Nothing is marked now — every open item runs in the order the epics below list it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, KiteloopTokens.Spacing.lg)
                    .padding(.bottom, KiteloopTokens.Spacing.md)
            }
            ForEach(now) { item in
                nowRow(item, epic: epicByItem[item.id] ?? "", isRetired: retired.contains(item.id))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .strokeBorder(Color.blue.opacity(KiteloopTokens.Opacity.medium), lineWidth: 1)
        )
        .accessibilityIdentifier("backlog-now-section")
    }

    /// One item in the run order, tagged with the epic it stays in.
    private func nowRow(_ item: BacklogItem, epic: String, isRetired: Bool) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            statusIcon(item.status)
            Text(item.title)
                .font(.callout)
            Text(item.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: KiteloopTokens.Spacing.md)
            pill(epic, color: .secondary)
                .help("In the \(epic) epic")
            statusPill(item)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.lg)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDetail(item, isRetired: isRetired) }
        .contextMenu { laneButton(item) }
    }

    /// Flips the item between the lanes, in place: it stays in its epic, and
    /// only the `lane:now` mark on its line changes.
    @ViewBuilder
    private func laneButton(_ item: BacklogItem) -> some View {
        if item.status != .done {
            if item.lane == .now {
                Button("Back to later") { viewModel.updateItemLane(itemID: item.id, lane: .later) }
            } else {
                Button("Run now") { viewModel.updateItemLane(itemID: item.id, lane: .now) }
            }
        }
    }

    // MARK: - Epic group

    @ViewBuilder
    private func epicGroup(_ epic: BacklogSection, retired: Set<String>) -> some View {
        // Drawn open while searching, without touching the collapsed set, so
        // clearing the query brings back the epics the user had folded.
        let collapsed = !isSearching && collapsedEpics.contains(epic.name)
        VStack(alignment: .leading, spacing: 0) {
            epicHeader(epic, collapsed: collapsed)

            if !collapsed {
                epicDescription(epic)

                let shownIDs = shown(epic.items).map(\.id)
                ForEach(shown(epic.items)) { item in
                    itemRow(item, isRetired: retired.contains(item.id),
                            neighbours: Self.moveNeighbours(of: item.id, in: shownIDs))
                }

                // Said rather than left as a gap: an epic whose rows are all
                // finished would otherwise render as an empty box with a count
                // in its header and nothing under it.
                if !isSearching, hidesCompleted, shown(epic.items).isEmpty, !epic.items.isEmpty {
                    Text("\(epic.items.count) completed — hidden")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, KiteloopTokens.Spacing.lg)
                        .padding(.vertical, KiteloopTokens.Spacing.sm)
                }

                addItemControl(epic)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .strokeBorder(Color.gray.opacity(KiteloopTokens.Opacity.medium), lineWidth: 1)
        )
    }

    /// The rows this view draws for an epic. Filtering here rather than at the
    /// model keeps the counts honest — every header still reports what the epic
    /// holds, not what is on screen.
    private func shown(_ items: [BacklogItem]) -> [BacklogItem] {
        items.filter {
            Self.isShown(status: $0.status, title: $0.title, id: $0.id, hidesCompleted: hidesCompleted, query: query)
        }
    }

    /// Said in place of the Now lane's rows, or of the whole list, when the
    /// search leaves none of them — rather than an empty box.
    private var noMatchesLine: some View {
        Text("No items match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, KiteloopTokens.Spacing.lg)
            .padding(.vertical, KiteloopTokens.Spacing.sm)
    }

    @ViewBuilder
    private func epicHeader(_ epic: BacklogSection, collapsed: Bool) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Button {
                toggleCollapse(epic.name)
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            if editingEpicName == epic.name {
                TextField("Epic name", text: $epicNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.headline))
                    .onSubmit { commitEpicRename(from: epic.name) }
                    .frame(maxWidth: 320)
                Button("Save") { commitEpicRename(from: epic.name) }
                    .controlSize(.small)
                Button("Cancel") { editingEpicName = nil }
                    .controlSize(.small)
            } else {
                Text(epic.name)
                    .font(.system(.headline, weight: .semibold))
                let done = epic.items.count { $0.status == .done }
                Text("\(done)/\(epic.items.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            epicMenu(epic)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.lg)
        .padding(.vertical, KiteloopTokens.Spacing.md)
    }

    private func epicMenu(_ epic: BacklogSection) -> some View {
        Menu {
            Button("Rename Epic") {
                epicNameDraft = epic.name
                editingEpicName = epic.name
            }
            Button("Move Epic Up") { viewModel.moveEpic(name: epic.name, by: -1) }
                .disabled(!canMoveEpic(epic.name, by: -1))
            Button("Move Epic Down") { viewModel.moveEpic(name: epic.name, by: 1) }
                .disabled(!canMoveEpic(epic.name, by: 1))
            Button(epic.description == nil ? "Add Description" : "Edit Description") {
                descriptionDraft = epic.description ?? ""
                editingDescriptionEpic = epic.name
            }
            Button("Add Item") {
                newItemTitle = ""
                addingItemEpic = epic.name
            }
            Divider()
            Button("Delete Epic", role: .destructive) {
                pendingDeleteEpic = epic.name
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A search draws only the matching epics, so the neighbour on screen may
    /// not be the neighbour in the file: moving is off while one is showing.
    private func canMoveEpic(_ name: String, by offset: Int) -> Bool {
        !isSearching && viewModel.canMoveEpic(name: name, by: offset)
    }

    /// What sits under an epic's header: the editor while that epic's
    /// description is being edited, its description when it has one, or nothing.
    enum EpicDescriptionLine: Equatable {
        case editor
        case text(String)
        case hidden
    }

    static func epicDescriptionLine(epicName: String, description: String?,
                                    editingEpic: String?) -> EpicDescriptionLine {
        if editingEpic == epicName { return .editor }
        guard let description, !description.isEmpty else { return .hidden }
        return .text(description)
    }

    @ViewBuilder
    private func epicDescription(_ epic: BacklogSection) -> some View {
        switch Self.epicDescriptionLine(epicName: epic.name, description: epic.description,
                                        editingEpic: editingDescriptionEpic) {
        case .editor:
            epicDescriptionEditor(epic)
        case .text(let description):
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, KiteloopTokens.Spacing.lg)
                .padding(.bottom, KiteloopTokens.Spacing.md)
                .onTapGesture {
                    descriptionDraft = description
                    editingDescriptionEpic = epic.name
                }
        case .hidden:
            EmptyView()
        }
    }

    private func epicDescriptionEditor(_ epic: BacklogSection) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            TextEditor(text: $descriptionDraft)
                .font(.callout)
                .frame(minHeight: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                        .strokeBorder(Color.gray.opacity(KiteloopTokens.Opacity.medium))
                )
            HStack {
                Spacer()
                Button("Cancel") { editingDescriptionEpic = nil }
                    .controlSize(.small)
                Button("Save") {
                    // A refused description keeps the editor open over the draft.
                    if viewModel.updateEpicDescription(name: epic.name, text: descriptionDraft) == .applied {
                        editingDescriptionEpic = nil
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.lg)
        .padding(.bottom, KiteloopTokens.Spacing.md)
    }

    // MARK: - Item row

    @ViewBuilder
    private func itemRow(_ item: BacklogItem, isRetired: Bool,
                         neighbours: (previous: String?, next: String?)) -> some View {
        if editingItemID == item.id {
            itemRenameField(item)
        } else {
            itemRowContent(item, isRetired: isRetired)
                .contextMenu {
                    Button("Rename Item…") {
                        itemTitleDraft = item.title
                        editingItemID = item.id
                    }
                    // Position is the queue's priority, so this is "run it next"
                    // within its epic. Meaningless for a finished item.
                    if item.status != .done {
                        Button("Move to top of epic") {
                            viewModel.moveItem(itemID: item.id, before: nil)
                        }
                        moveStepButtons(item, neighbours: neighbours)
                    }
                    laneButton(item)
                }
        }
    }

    /// One place up or down among the rows the epic draws. Down moves the
    /// next row in front of this one, since `moveItem` only places before.
    @ViewBuilder
    private func moveStepButtons(_ item: BacklogItem, neighbours: (previous: String?, next: String?)) -> some View {
        Button("Move Up") {
            if let previous = neighbours.previous { viewModel.moveItem(itemID: item.id, before: previous) }
        }
        .disabled(neighbours.previous == nil)
        Button("Move Down") {
            if let next = neighbours.next { viewModel.moveItem(itemID: next, before: item.id) }
        }
        .disabled(neighbours.next == nil)
    }

    private func itemRenameField(_ item: BacklogItem) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            TextField("Item title", text: $itemTitleDraft)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { commitItemRename(itemID: item.id) }
            Button("Save") { commitItemRename(itemID: item.id) }
                .controlSize(.small)
            Button("Cancel") { editingItemID = nil }
                .controlSize(.small)
        }
    }

    private func itemRowContent(_ item: BacklogItem, isRetired: Bool) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            statusIcon(item.status)
            Text(item.title)
                .font(.callout)
                .foregroundStyle(item.status == .done ? .secondary : .primary)
                .strikethrough(item.status == .done)
            Text(item.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: KiteloopTokens.Spacing.md)

            statusPill(item)
            // An item autopilot refuses to start looks exactly like one nobody
            // has got to yet, so it is marked here as well as in its Notes.
            if isRetired {
                pill("retired", color: .orange)
                    .help("Autopilot will not start this item — \(RetryCeiling.limit) attempts in a row started and produced no work. Re-groom it, or release it from this menu.")
            }
            estimateBadge(item)

            Menu {
                if canOpenDetail {
                    Button {
                        openDetail(item, isRetired: isRetired)
                    } label: {
                        // Named as what it opens now: the whole item, its runs
                        // included, rather than a history sheet.
                        Label("Open Item…", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                }
                if isRetired {
                    Button {
                        release(item)
                    } label: {
                        Label("Release for Autopilot", systemImage: "arrow.clockwise.circle")
                    }
                    Divider()
                }
                if let onRun {
                    Button { onRun(item) } label: {
                        Label("Run with Agent", systemImage: "play.fill")
                    }
                    .disabled(item.status == .done)
                    Divider()
                }
                Button {
                    scope(item)
                } label: {
                    Label("Scope with AI", systemImage: "sparkles")
                }
                if let estimate = metricStore.latestEstimate(itemID: item.id),
                   ItemSize(rawValue: estimate.estimatedSize) != item.size,
                   let size = ItemSize(rawValue: estimate.estimatedSize) {
                    Button("Apply estimated size (\(size.rawValue))") {
                        viewModel.updateItemSize(itemID: item.id, size: size)
                    }
                }
                Menu("Set Size") {
                    ForEach(ItemSize.allCases, id: \.self) { size in
                        Button(size.rawValue) { viewModel.updateItemSize(itemID: item.id, size: size) }
                            .disabled(item.size == size)
                    }
                }
                Divider()
                Menu("Set Status") {
                    ForEach(BacklogItemStatus.allCases, id: \.self) { status in
                        Button(status.displayName) { setStatus(item, status) }
                            .disabled(item.status == status)
                    }
                }
                Menu("Move to Epic") {
                    ForEach(otherEpicNames(excluding: item.id), id: \.self) { name in
                        Button(name) { viewModel.moveItem(itemID: item.id, toEpic: name) }
                    }
                }
                Divider()
                Button("Remove", role: .destructive) {
                    pendingRemoveItem = item
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, KiteloopTokens.Spacing.lg)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .contentShape(Rectangle())
        // The same thing the ⋯ menu offers, on the gesture a list row invites.
        .onTapGesture(count: 2) { openDetail(item, isRetired: isRetired) }
    }

    // MARK: - Item history

    /// Whether the detail view can be opened at all. It reads its run history
    /// from the metric index and takes its actions through the autopilot, so
    /// without both there is no view to show — and the menu entry is left out
    /// rather than offered and disabled, because nothing about the item's state
    /// is what would be missing.
    private var canOpenDetail: Bool { metricIndex != nil && autopilot != nil }

    /// Opens one item's history: its runs, its state changes, what git says
    /// about its branch right now, and the actions its state permits.
    private func openDetail(_ item: BacklogItem, isRetired: Bool) {
        guard let metricIndex, let autopilot else { return }
        detailModel = BacklogItemDetailViewModel(
            item: item,
            projectPath: projectPath,
            projectName: projectName,
            // Judged once for the whole list; asking again per item would walk
            // the run ledger a second time for an answer already in hand.
            isRetired: isRetired,
            backlog: viewModel,
            autopilot: autopilot,
            metricIndex: metricIndex,
            metricStore: metricStore,
            groomingLedger: groomingLedger,
            aiEditor: aiEditor)
    }

    /// Opens the page for an id the window asked this surface to show.
    ///
    /// Held rather than dropped while the backlog is still being read — see
    /// `openRequestKey`. Every other way out clears the request and says what
    /// happened, so a click can end in a page or in a named refusal, never in
    /// nothing.
    private func openRequestedItem(_ itemID: String) {
        guard let metricIndex, let autopilot else {
            openRequest.wrappedValue = nil
            onOpenFailed?("\(itemID) can't be opened here — this backlog has no run "
                          + "history attached, so there is no page to show.")
            return
        }
        // Still loading. The retry is the backlog landing, not another click.
        guard viewModel.backlogFile != nil else { return }
        guard let model = BacklogItemDetailViewModel.make(
            itemID: itemID,
            backlog: viewModel,
            autopilot: autopilot,
            metricIndex: metricIndex,
            metricStore: metricStore,
            groomingLedger: groomingLedger,
            aiEditor: aiEditor) else {
            openRequest.wrappedValue = nil
            onOpenFailed?("\(itemID) is no longer in \(projectName)'s backlog, "
                          + "so there is no item to open.")
            return
        }
        detailModel = model
        openRequest.wrappedValue = nil
    }

    /// Shows a scoping spinner, then the estimate (and recorded actual, if any).
    @ViewBuilder
    private func estimateBadge(_ item: BacklogItem) -> some View {
        if scopingEngine.scopingItemID == item.id {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                if let size = item.size {
                    pill(size.rawValue, color: .blue)
                }
                if let estimate = metricStore.latestEstimate(itemID: item.id) {
                    pill("~\(minutes(estimate.predictedDurationSeconds))", color: .purple)
                        .help("Estimated \(minutes(estimate.predictedDurationSeconds)) · \(Int(estimate.confidence * 100))% confidence\(estimate.rationale.isEmpty ? "" : " — \(estimate.rationale)")")
                }
                if let actual = metricStore.latestActual(itemID: item.id) {
                    pill("⏱\(minutes(actual.durationSeconds))", color: .green)
                        .help("Actual: \(minutes(actual.durationSeconds)), $\(String(format: "%.2f", actual.costUSD)), \(actual.reviewerRetries) rework loop(s)")
                }
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(KiteloopTokens.Opacity.medium), in: Capsule())
            .foregroundStyle(color)
    }

    private func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(1, m))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    // MARK: - Retry ceiling

    /// The items autopilot is currently refusing to start.
    ///
    /// Two passes, because the honest answer is expensive and almost always
    /// "none": one walk of the run ledger gives every item's no-work streak, and
    /// only an item over the ceiling is then judged in full — which costs a read
    /// of its detail file to fingerprint, and a look in the grooming ledger for a
    /// release. On a backlog where nothing is retired the second pass never runs.
    private func retiredItemIDs(in file: BacklogFile) -> Set<String> {
        let streaks = RetryCeiling.noWorkAttemptsByItem(projectPath: projectPath,
                                                        records: metricStore.records)
        guard streaks.contains(where: { $0.value >= RetryCeiling.limit }) else { return [] }
        var out: Set<String> = []
        for item in file.sections.flatMap(\.items) where (streaks[item.id] ?? 0) >= RetryCeiling.limit {
            let verdict = RetryCeiling.evaluate(
                itemID: item.id, projectPath: projectPath, records: metricStore.records,
                releasedAt: groomingLedger.latestRelease(itemID: item.id, projectPath: projectPath),
                specFingerprint: RetryCeiling.specFingerprint(item: item,
                                                              detail: viewModel.loadDetail(for: item)))
            if verdict.isRetired { out.insert(item.id) }
        }
        return out
    }

    /// Lets a retired item be picked up again, as it stands. Re-grooming the item
    /// does the same thing on its own; this is the way out for an item a human
    /// wants re-attempted without rewriting it.
    private func release(_ item: BacklogItem) {
        RetryCeilingRelease.apply(itemID: item.id, projectPath: projectPath,
                                  projectName: projectName, source: "backlog",
                                  ledger: groomingLedger, backlog: viewModel,
                                  records: metricStore.records)
    }

    private func scope(_ item: BacklogItem) {
        let detail = viewModel.loadDetail(for: item)
        let epic = viewModel.backlogFile?.sections.first { $0.items.contains { $0.id == item.id } }?.name
        Task {
            await scopingEngine.scope(item: item, detail: detail, epic: epic, projectPath: projectPath)
        }
    }

    @ViewBuilder
    private func addItemControl(_ epic: BacklogSection) -> some View {
        if addingItemEpic == epic.name {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                TextField("New item title", text: $newItemTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { commitNewItem(epic: epic.name) }
                Button("Add") { commitNewItem(epic: epic.name) }
                    .controlSize(.small)
                    .disabled(newItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { addingItemEpic = nil }
                    .controlSize(.small)
            }
            .padding(.horizontal, KiteloopTokens.Spacing.lg)
            .padding(.vertical, KiteloopTokens.Spacing.md)
        } else {
            Button {
                newItemTitle = ""
                addingItemEpic = epic.name
            } label: {
                Label("Add item", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, KiteloopTokens.Spacing.lg)
            .padding(.vertical, KiteloopTokens.Spacing.md)
        }
    }

    // MARK: - Empty states

    private var noBacklogState: some View {
        VStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: "checklist")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No backlog for this project yet")
                .font(.headline)
            Text("Create a BACKLOG.md to start planning epics and items.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Create BACKLOG.md") { viewModel.createStarterBacklog() }
                .buttonStyle(.borderedProminent)
            // The team-shaped alternative: the backlog on a `kiteloop/backlog`
            // branch of this repo's own remote — shared with whoever can push,
            // surviving every clone, never dirtying the working tree.
            if viewModel.canCreateBranchBacklog {
                Button("Create shared team backlog (git branch)") {
                    Task { await viewModel.createBranchBacklog() }
                }
                Text("Lives on a `kiteloop/backlog` branch of this repo — teammates who clone and open the project get it automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A backlog file with no sections in it. `PanelEmptyState`'s copy rules
    /// applied in place, in the shape `noBacklogState` above already uses: both
    /// states carry an action button, which the centred view has no room for, and
    /// they are alternatives to each other — a reader who sees one this week and
    /// the other next week should not see two different designs.
    private var emptyBacklogState: some View {
        let copy = PanelEmptyState.Copy.backlogEpics
        return VStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: copy.icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(copy.title)
                .font(.headline)
            Text(copy.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Add Epic") {
                showingAddEpic = true
                newEpicName = ""
            }
            .popover(isPresented: $showingAddEpic) { addEpicPopover }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("backlog-empty-state")
    }

    private func centeredMessage(icon: String, title: String, tint: Color) -> some View {
        VStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(tint)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var addEpicPopover: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            Text("New Epic").font(.headline)
            TextField("Epic name", text: $newEpicName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewEpic() }
            HStack {
                Spacer()
                Button("Cancel") { showingAddEpic = false }
                    .controlSize(.small)
                Button("Add") { commitNewEpic() }
                    .controlSize(.small)
                    .disabled(newEpicName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 260)
    }

    // MARK: - Status

    /// Icon and tint per status. Hues are kept distinct — `awaitingApproval` is
    /// orange to match the "needs you" badge in the project sidebar, which frees
    /// blue to mean "an agent is working on it" (`active`).
    private func statusStyle(_ status: BacklogItemStatus) -> (icon: String, tint: Color) {
        let style: (String, Color) = switch status {
        case .done: ("checkmark.circle.fill", .green)
        case .awaitingApproval: ("hand.raised.circle.fill", .orange)
        case .inReview: ("magnifyingglass.circle.fill", .purple)
        case .active: ("play.circle.fill", .blue)
        case .blocked: ("nosign", .red)
        case .draft: ("pencil.circle", .gray)
        case .ready: ("circle", .secondary)
        }
        return style
    }

    private func statusIcon(_ status: BacklogItemStatus) -> some View {
        let style = statusStyle(status)
        return Image(systemName: style.icon)
            .foregroundStyle(style.tint)
            .font(.system(size: 13))
            .help(status.displayName)
    }

    /// The icon alone can't say which stage an item sits in — spell it out,
    /// with the lane beside it for an open item: `now` runs ahead of `later`.
    private func statusPill(_ item: BacklogItem) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            if item.status != .done {
                pill(item.lane.rawValue, color: item.lane == .now ? .blue : .gray)
                    .help(item.lane == .now ? "Runs ahead of every later item" : "Runs after every now item")
            }
            pill(item.status.displayName, color: statusStyle(item.status).tint)
            waitingPill(item)
        }
    }

    /// Autopilot holds back an item whose `needs:` aren't all done; without
    /// this it reads exactly like one that runs next.
    @ViewBuilder
    private func waitingPill(_ item: BacklogItem) -> some View {
        let reasons = viewModel.unmetDependencies(for: item)
        if !reasons.isEmpty {
            pill("waiting", color: .orange)
                .help(reasons.joined(separator: "\n"))
        }
    }

    // MARK: - Actions

    private func toggleCollapse(_ name: String) {
        if collapsedEpics.contains(name) { collapsedEpics.remove(name) }
        else { collapsedEpics.insert(name) }
        collapseStore.save(collapsedEpics, projectPath: projectPath)
    }

    /// A refused rename leaves the field open with what was typed still in it:
    /// the view model has said why in its banner, and closing the field over
    /// that message would read as a save that worked.
    private func commitEpicRename(from oldName: String) {
        let outcome = viewModel.renameEpic(from: oldName, to: epicNameDraft)
        collapsedEpics = collapseStore.carryRename(outcome, from: oldName, to: epicNameDraft,
                                                   projectPath: projectPath)
        guard outcome == .applied else { return }
        editingEpicName = nil
    }

    /// As `commitEpicRename`: a refusal keeps the row's field open, draft intact.
    private func commitItemRename(itemID: String) {
        guard viewModel.renameItem(itemID: itemID, to: itemTitleDraft) == .applied else { return }
        editingItemID = nil
    }

    /// As `commitEpicRename`: a refusal keeps the popover open, draft intact.
    private func commitNewEpic() {
        guard viewModel.addEpic(name: newEpicName) == .applied else { return }
        newEpicName = ""
        showingAddEpic = false
    }

    private func commitNewItem(epic: String) {
        let title = newItemTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        // A refusal is named in `operationMessage`; the field stays open over
        // it with what was typed.
        guard viewModel.addItem(sectionName: epic, id: generatedItemID(), title: title, verify: nil)
            .didFile else { return }
        newItemTitle = ""
        addingItemEpic = nil
    }

    private func setStatus(_ item: BacklogItem, _ status: BacklogItemStatus) {
        if status == .done {
            viewModel.approve(itemID: item.id)
        } else if item.status == .blocked, status == .draft || status == .ready {
            // Keeps the reason it was blocked for as a Notes line.
            viewModel.unblock(itemID: item.id, to: status)
        } else {
            viewModel.updateItemStatus(itemID: item.id, newStatus: status)
        }
    }

    private func otherEpicNames(excluding itemID: String) -> [String] {
        guard let file = viewModel.backlogFile else { return [] }
        let currentEpic = file.sections.first { $0.items.contains { $0.id == itemID } }?.name
        return file.sections.map(\.name).filter { $0 != currentEpic }
    }

    private func generatedItemID() -> String {
        viewModel.nextGeneratedItemID()
    }
}

/// Which epics are collapsed, remembered per project in user defaults — so an
/// epic stays collapsed across a project switch and a relaunch. The defaults
/// are injectable so a test writes a suite of its own, not the app's domain.
struct CollapsedEpicsStore {
    var defaults: UserDefaults = .standard

    static func key(projectPath: String) -> String {
        "backlogCollapsedEpics.\(projectPath)"
    }

    func load(projectPath: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key(projectPath: projectPath)) ?? [])
    }

    func save(_ names: Set<String>, projectPath: String) {
        defaults.set(names.sorted(), forKey: Self.key(projectPath: projectPath))
    }

    /// Moves a collapsed epic's entry to its new name once the rename has been
    /// `.applied`; a refused rename leaves the saved set as it was. Returns the
    /// set as saved.
    @discardableResult
    func carryRename(_ outcome: BacklogViewModel.EpicEditOutcome, from oldName: String, to newName: String,
                     projectPath: String) -> Set<String> {
        var names = load(projectPath: projectPath)
        guard outcome == .applied, names.remove(oldName) != nil else { return names }
        names.insert(newName.trimmingCharacters(in: .whitespaces))
        save(names, projectPath: projectPath)
        return names
    }
}
