import KiteloopCore
import AppKit
import os.log
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let registry: ControlSessionRegistry
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DiagnosticsLogView()
                .tabItem { Label("Logs", systemImage: "doc.text") }
                .tag(0)
            DiagnosticsHealthView(registry: registry)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag(1)
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    /// Whether a new log line scrolls the Logs tab to the bottom. Only with
    /// Auto-scroll on, and only for a reader already at the bottom — the
    /// judgement the chat makes of its bubble list, with no find bar — so
    /// scrolling up to read an older line stays there while the app logs on.
    static func newLineScrolls(autoScroll: Bool, distanceFromBottom: CGFloat) -> Bool {
        autoScroll && ChatView.streamScrollAction(
            distanceFromBottom: distanceFromBottom,
            isSearching: false,
            hasMatches: false
        ) == .follow
    }

    /// What the Logs tab says in place of an empty list, or nil while it shows
    /// at least one line. Lines hidden by the filters and a log with no lines
    /// yet are different states: only the first is fixed by the controls.
    static func logEmptyState(totalCount: Int, shownCount: Int) -> PanelEmptyState.Copy? {
        guard shownCount == 0 else { return nil }
        if totalCount == 0 {
            return PanelEmptyState.Copy(
                icon: "doc.text",
                title: "The log is empty",
                message: "Lines appear here as Kiteloop logs them.",
                control: nil
            )
        }
        return PanelEmptyState.Copy(
            icon: "line.3.horizontal.decrease.circle",
            title: "No lines match the filters",
            message: "The log has lines the filters hide — pick All in the category menu, "
                + "turn on Info and Errors, or clear Search to show them.",
            control: "All"
        )
    }

    /// The Logs tab's footer count. The in-memory buffer keeps only the newest
    /// `capacity` lines, so once the log has filled it the caption says older
    /// lines are only in the file Reveal opens — judged on the total, since
    /// the filters do not change what was dropped.
    static func logFooterCaption(totalCount: Int, shownCount: Int, capacity: Int) -> String {
        let count = "\(shownCount) of \(totalCount) shown"
        guard totalCount >= capacity else { return count }
        let latest = capacity.formatted(.number.locale(Locale(identifier: "en_US")))
        return count + " — latest \(latest) lines only; older lines are in the log file (Reveal)"
    }
}

// MARK: - Logs Tab

private struct DiagnosticsLogView: View {
    @State private var entries: [KiteloopFileLogger.Entry] = []
    @State private var categories: [String] = []
    @State private var selectedCategory: String = "All"
    @State private var showInfo: Bool = true
    @State private var showErrors: Bool = true
    @State private var searchText: String = ""
    @State private var autoScroll: Bool = true
    /// The height of the list's window onto the rows, which the distance from
    /// the bottom is measured against.
    @State private var viewportHeight: CGFloat = 0
    /// How far the bottom of the row stack sits below the bottom of that
    /// window, as of the last time the list was scrolled.
    @State private var distanceFromBottom: CGFloat = 0
    /// What the stack's offset above the window was then, which is how a scroll
    /// is told from lines arriving.
    @State private var lastScrollOffset: CGFloat = 0

    /// The list's own frame, which the row stack's position is read against.
    private static let scrollSpace = "diagnostics-log-scroll"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let copy = DiagnosticsView.logEmptyState(totalCount: entries.count, shownCount: filtered.count) {
                logEmptyState(copy)
            } else {
                logList
            }
            Divider()
            footer
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: KiteloopFileLogger.bufferDidChange)) { _ in
            refresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedCategory) {
                Text("All").tag("All")
                ForEach(categories, id: \.self) { cat in
                    Text(cat).tag(cat)
                }
            }
            .frame(width: 180)

            Toggle("Info", isOn: $showInfo)
            Toggle("Errors", isOn: $showErrors)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)

            Button("Copy") { copyVisible() }
                .disabled(filtered.isEmpty)
            Button("Reveal") { revealLog() }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack {
            Text(DiagnosticsView.logFooterCaption(
                totalCount: entries.count,
                shownCount: filtered.count,
                capacity: KiteloopFileLogger.shared.bufferCapacity
            ))
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            if let url = KiteloopFileLogger.shared.currentLogFileURL() {
                Text(url.path)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var filtered: [KiteloopFileLogger.Entry] {
        entries.filter { entry in
            if selectedCategory != "All", entry.category != selectedCategory { return false }
            let isError = entry.level == .error || entry.level == .fault
            if isError, !showErrors { return false }
            if !isError, !showInfo { return false }
            if !searchText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.category.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGRect.self) { stack in
                    stack.frame(in: .named(Self.scrollSpace))
                } action: { frame in
                    record(stackFrame: frame)
                }
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: entries.last?.id) { _, _ in
                guard DiagnosticsView.newLineScrolls(autoScroll: autoScroll, distanceFromBottom: distanceFromBottom),
                      let last = filtered.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: autoScroll) { _, isOn in
                guard isOn, let last = filtered.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func logEmptyState(_ copy: PanelEmptyState.Copy) -> some View {
        PanelEmptyState(copy)
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// Takes the row stack's frame in the list's window, reported on every
    /// change. Only a scroll of the list itself moves the recorded distance: a
    /// line arriving pushes the bottom further below the window without the
    /// reader having moved. The chat's judgement, `ChatView.recordedDistance`.
    private func record(stackFrame frame: CGRect) {
        let offset = -frame.minY
        let distance = ChatView.recordedDistance(
            offset: offset, distanceFromBottom: frame.maxY - viewportHeight,
            lastOffset: lastScrollOffset, recorded: distanceFromBottom)
        if offset != lastScrollOffset { lastScrollOffset = offset }
        if distance != distanceFromBottom { distanceFromBottom = distance }
    }

    private func row(_ entry: KiteloopFileLogger.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(KiteloopFileLogger.timestamp(for: entry.timestamp, timeZone: .current))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(entry.levelTag)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 44, alignment: .leading)
            Text(entry.category)
                .foregroundStyle(.blue)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    private func color(for level: OSLogType) -> Color {
        switch level {
        case .error, .fault: return .red
        case .debug: return .gray
        default: return .secondary
        }
    }

    private func refresh() {
        entries = KiteloopFileLogger.shared.snapshot()
        categories = KiteloopFileLogger.shared.categories()
    }

    private func copyVisible() {
        let text = filtered.map { entry in
            KiteloopFileLogger.logLine(for: entry, timeZone: .current)
        }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func revealLog() {
        guard let url = KiteloopFileLogger.shared.currentLogFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Health Tab

private struct DiagnosticsHealthView: View {
    let registry: ControlSessionRegistry
    @State private var snapshot = HealthMonitor.Snapshot(
        processMemoryMB: nil, activeSubprocessCount: 0, mainThreadLatencyMs: 0,
        hitches: [], agentWorking: 0, agentIdle: 0, agentCrashed: 0
    )
    @State private var tools: [ToolReachability.ProjectReport] = []
    @State private var ticks = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// The tool rows read every item's detail file and stat every executable,
    /// so they refresh on this many gauge ticks rather than on each one.
    private static let toolRefreshTicks = 10

    var body: some View {
        VStack(spacing: 0) {
            gauges
            Divider()
            agentSummary
            Divider()
            hitchLog
            Divider()
            toolList
        }
        .onAppear { refresh(); refreshTools() }
        .onReceive(timer) { _ in
            refresh()
            ticks += 1
            if ticks % Self.toolRefreshTicks == 0 { refreshTools() }
        }
    }

    /// Per open project, the tools its verify commands run and where each
    /// resolved, then the build exports its verifies and spawns run with —
    /// the same rows `GET /v1/health` carries as `tools` and `exports`.
    private var toolList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verify tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if tools.isEmpty {
                        emptyCaption("Verify tools are listed here once a project is open.")
                    }
                    ForEach(tools, id: \.path) { report in
                        Text(report.project).font(.caption.bold())
                        ForEach(report.tools, id: \.name) { row in
                            ToolRowView(row: row)
                        }
                        ForEach(report.exports, id: \.name) { export in
                            ExportRowView(export: export)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func refreshTools() {
        tools = registry.openProjects.map { $0.session.toolReachability() }
    }

    private var gauges: some View {
        HStack(spacing: 16) {
            GaugeCard(
                title: "Memory",
                value: snapshot.memoryGauge.text,
                color: memoryColor(snapshot.memoryGauge.level)
            )
            GaugeCard(
                title: "Subprocesses",
                value: "\(snapshot.activeSubprocessCount)",
                color: .blue
            )
            GaugeCard(
                title: "Main Thread",
                value: snapshot.latencyGauge.text,
                color: latencyColor(snapshot.latencyGauge.level)
            )
        }
        .padding()
    }

    private func memoryColor(_ level: HealthMonitor.Snapshot.MemoryGauge.Level) -> Color {
        switch level {
        case .healthy: return .green
        case .high: return .orange
        case .unknown: return .secondary
        }
    }

    private func latencyColor(_ level: HealthMonitor.Snapshot.LatencyGauge.Level) -> Color {
        switch level {
        case .healthy: return .green
        case .degraded: return .red
        }
    }

    private var agentSummary: some View {
        HStack(spacing: 12) {
            StatePill(label: "Working", count: snapshot.agentWorking, color: .orange)
            StatePill(label: "Idle", count: snapshot.agentIdle, color: .green)
            StatePill(label: "Crashed", count: snapshot.agentCrashed, color: .red)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var hitchLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Main Thread Hitches (>\(Int(200))ms)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.hitches.count) recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if snapshot.hitches.isEmpty {
                        emptyCaption("Main-thread stalls are listed here as they happen.")
                            .padding(8)
                    }
                    ForEach(snapshot.hitches.reversed()) { hitch in
                        HStack(spacing: 8) {
                            Text(KiteloopFileLogger.timestamp(for: hitch.timestamp, timeZone: .current))
                                .frame(width: 92, alignment: .leading)
                            Text(String(format: "%.0f ms", hitch.durationMs))
                                .foregroundStyle(hitch.durationMs > 1000 ? .red : .orange)
                                .frame(width: 80, alignment: .trailing)
                            hitchBar(hitch.durationMs)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func emptyCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func hitchBar(_ ms: Double) -> some View {
        let width = min(ms / 2000 * 200, 200)
        return RoundedRectangle(cornerRadius: 2)
            .fill(ms > 1000 ? Color.red.opacity(0.6) : Color.orange.opacity(0.6))
            .frame(width: max(width, 4), height: 10)
    }

    private func refresh() {
        snapshot = HealthMonitor.shared.snapshot()
    }
}

// MARK: - Components

/// One tool: its name, and where it resolved or "not found" with the searched
/// directories behind a tooltip.
private struct ToolRowView: View {
    let row: ToolReachability.Row

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name)
                .frame(width: 140, alignment: .leading)
            if let path = row.path {
                Text(path).foregroundStyle(.secondary)
            } else {
                Text("not found")
                    .foregroundStyle(.red)
                    .help("Searched: " + row.searched.joined(separator: ":"))
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// One build export: the variable and the value every verify and spawn on the
/// project's behalf gets — a `CARGO_TARGET_DIR` shared across item worktrees.
private struct ExportRowView: View {
    let export: BuildEnvironment.Export

    var body: some View {
        HStack(spacing: 8) {
            Text(export.name)
                .frame(width: 140, alignment: .leading)
            Text("= " + export.value).foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
    }
}

private struct GaugeCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatePill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }
}
