import KiteloopCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @ObservedObject var statusLine: StatusLineService
    var otherAgents: [Agent] = []
    var onForwardToAgent: ((String, String) -> Void)? = nil
    @State private var isTranscriptMode = false
    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var lastCompletedDuration: Int?
    @State private var streamingStartDate: Date?
    @State private var gitBranch: String = ""

    /// The conversation the input bar is sitting under: the session and, within
    /// it, the branch. New Chat, another session and `/branch switch` each move
    /// it, so the recalled input history follows the messages on screen.
    private var conversationID: String {
        let session = viewModel.currentSession?.id.uuidString ?? "none"
        let branch = viewModel.conversationTree.activeBranchID?.uuidString ?? "main"
        return "\(session)/\(branch)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contextStrip
            Divider()
            if viewModel.conversationTree.branchCount > 0 {
                BranchBarView(
                    tree: viewModel.conversationTree,
                    isStreaming: viewModel.isStreaming,
                    onSwitchToMain: { viewModel.switchToMainBranch() },
                    onSwitchToBranch: { viewModel.switchToBranch(id: $0) },
                    onDeleteBranch: { viewModel.deleteBranch(id: $0) },
                    onRenameBranch: { viewModel.renameBranch(id: $0, to: $1) }
                )
                Divider()
            }
            if viewModel.isSearching {
                SearchBar(
                    query: $viewModel.searchQuery,
                    matchCount: viewModel.matchingMessageIDs.count,
                    unsearchedOlderMessageCount: viewModel.unsearchedOlderMessageCount,
                    currentIndex: viewModel.currentMatchIndex,
                    onNext: { viewModel.nextMatch() },
                    onPrevious: { viewModel.previousMatch() },
                    onDismiss: { viewModel.closeSearch() }
                )
                Divider()
            }
            MessageListContainer(
                viewModel: viewModel,
                isTranscriptMode: isTranscriptMode,
                isStreaming: viewModel.isStreaming,
                lastCompletedDuration: lastCompletedDuration,
                elapsedSeconds: elapsedSeconds
            )
            if !viewModel.agentTasks.isEmpty {
                AgentTaskPanelView(tasks: viewModel.agentTasks)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            BackgroundTasksStrip(tasks: viewModel.agentActivity.backgroundTasks)
            Divider()
            if viewModel.isProcessDead {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent process crashed.")
                            .foregroundStyle(.secondary)
                        if let reason = viewModel.lastRecoveryFailure {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Button("Restart Agent") {
                        Task { await viewModel.restart() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("restart-button")
                    .help("Restart the crashed agent process")
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            } else {
                InputBar(
                    text: $viewModel.inputText,
                    attachments: $viewModel.pendingAttachments,
                    isStreaming: viewModel.isStreaming,
                    queuedMessages: viewModel.queuedTypedMessages,
                    onTakeBackQueued: { viewModel.takeBackQueuedMessage(at: $0) },
                    messages: viewModel.messages,
                    onSend: { Task { await viewModel.send() } },
                    onStop: { viewModel.interrupt() },
                    onAttach: { pickAttachment() },
                    onAttachFiles: { urls in urls.forEach { viewModel.addAttachment(url: $0) } },
                    skillRegistry: viewModel.skillRegistry,
                    agentCatalogStore: viewModel.agentCatalogStore,
                    projectAgents: otherAgents,
                    conversationID: conversationID,
                    isSearchOpen: viewModel.isSearching,
                    runtime: viewModel.runtimeKind,
                    projectURL: viewModel.projectURL
                )
            }
            if !statusLine.statusText.isEmpty {
                HStack {
                    Text(statusLine.statusText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
        .background(
            Group {
                Button("") {
                    // The bar first: only the bubble list marks and scrolls to a
                    // match, so a bar left open over the transcript would count
                    // matches nothing could take you to.
                    viewModel.closeSearch()
                    isTranscriptMode.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()
                Button("") {
                    switch Self.findShortcutAction(
                        isTranscriptMode: isTranscriptMode,
                        isSearching: viewModel.isSearching
                    ) {
                    case .closeBar:
                        viewModel.closeSearch()
                    case .openBar:
                        viewModel.isSearching = true
                    case .leaveTranscriptAndOpenBar:
                        isTranscriptMode = false
                        viewModel.isSearching = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            }
        )
        .environment(\.projectRootPath, viewModel.projectURL.path)
        .task { detectProjectState() }
        .onAppear { seedContextWindowSize() }
        .onChange(of: viewModel.contextWindowSize) { _, _ in seedContextWindowSize() }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            // Session translocation — purge stale timer wards from the prior incantation.
            timerTask?.cancel()
            timerTask = nil
            streamingStartDate = nil
            elapsedSeconds = 0
            lastCompletedDuration = nil
        }
        .onChange(of: viewModel.isStreaming) { oldValue, streaming in
            if streaming {
                lastCompletedDuration = nil
                streamingStartDate = Date()
                elapsedSeconds = 0
                timerTask?.cancel()
                timerTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { break }
                        if let start = streamingStartDate {
                            elapsedSeconds = Int(Date().timeIntervalSince(start))
                        }
                    }
                }
            } else if oldValue {
                timerTask?.cancel()
                timerTask = nil
                if viewModel.lastDurationMs > 0 {
                    lastCompletedDuration = viewModel.lastDurationMs / 1000
                } else if let start = streamingStartDate {
                    lastCompletedDuration = max(1, Int(Date().timeIntervalSince(start)))
                }
                streamingStartDate = nil
                statusLine.updateSessionData(
                    model: viewModel.currentModel.isEmpty ? nil : viewModel.currentModel,
                    costUSD: viewModel.costUSD,
                    inputTokens: viewModel.lastInputTokens,
                    outputTokens: viewModel.lastOutputTokens,
                    cacheReadInputTokens: viewModel.cacheReadTokens,
                    cacheCreationInputTokens: viewModel.cacheCreationTokens,
                    contextWindowSize: viewModel.contextWindowSize
                )
                statusLine.refresh()
            }
            if !streaming { detectProjectState() }
        }
    }

    private func seedContextWindowSize() {
        let size = viewModel.contextWindowSize
        let model = viewModel.currentModel.isEmpty ? nil : viewModel.currentModel
        statusLine.updateSessionData(
            model: model ?? viewModel.agentModel,
            inputTokens: viewModel.lastInputTokens,
            outputTokens: viewModel.lastOutputTokens,
            cacheReadInputTokens: viewModel.cacheReadTokens,
            cacheCreationInputTokens: viewModel.cacheCreationTokens,
            contextWindowSize: size
        )
        statusLine.refresh()
    }

    private func detectProjectState() {
        let projectURL = viewModel.projectURL
        Task.detached {
            let branch = await Self.runGitBranch(at: projectURL)
            await MainActor.run { [branch] in
                gitBranch = Self.branchChipName(detected: branch, showing: gitBranch)
            }
        }
    }

    /// What the header's branch chip shows once a detection comes back. The
    /// reading wins outright, empty included: an empty one means a detached HEAD
    /// or a folder that is no repo, and the chip is hidden rather than left
    /// naming a branch the project has already left.
    static func branchChipName(detected: String, showing: String) -> String {
        detected
    }

    /// What Cmd-F does to the chat. Three answers, because the bar can only work
    /// over the bubble list: it is the one branch that marks the current match
    /// and scrolls to it, while the transcript and the empty state draw neither.
    enum FindShortcutAction: Equatable {
        /// Cmd-F over an open bar shuts it, the same as its x button and Esc.
        case closeBar
        /// The bubble list is already on screen, so the bar can act at once.
        case openBar
        /// Transcript mode is left first, so the bar opens over a view that can
        /// mark and scroll to what it finds.
        case leaveTranscriptAndOpenBar
    }

    /// Whether a chat is drawn the way Claude Code draws a session in the
    /// terminal: every chat whose replies come from one agent. A chat holding
    /// replies from several — a teammate's forwarded message among them — keeps
    /// the bubbles, which name who said what.
    static func usesTerminalLook(for messages: [Message]) -> Bool {
        let agents = Set(messages.compactMap { message -> String? in
            if case .agent(let id) = message.sender { return id }
            return nil
        })
        return agents.count <= 1
    }

    static func findShortcutAction(isTranscriptMode: Bool, isSearching: Bool) -> FindShortcutAction {
        if isSearching { return .closeBar }
        return isTranscriptMode ? .leaveTranscriptAndOpenBar : .openBar
    }

    /// What a chunk arriving during a turn, or the per-second tick that runs for
    /// the whole of it, does to the bubble list's scroll position. The stream is
    /// followed only for a reader who is already at the bottom, so scrolling up
    /// to read something earlier stays there for the rest of the turn.
    enum StreamScrollAction: Equatable {
        /// An open bar with matches parks the view on its match, whatever the
        /// distance from the bottom — the precedence the list already had.
        case holdOnMatch
        /// The reader is at the bottom, so the newest message stays pinned.
        case follow
        /// The reader scrolled up: nothing moves the view until they come back.
        case stayPut
    }

    /// How far short of the bottom still counts as the bottom — a point or two,
    /// the judgement `TranscriptView.Coordinator.apply` already makes of its own
    /// scroll view.
    static let atBottomTolerance: CGFloat = 2

    static func streamScrollAction(
        distanceFromBottom: CGFloat,
        isSearching: Bool,
        hasMatches: Bool
    ) -> StreamScrollAction {
        if isSearching && hasMatches { return .holdOnMatch }
        return distanceFromBottom <= atBottomTolerance ? .follow : .stayPut
    }

    /// What the bubble list's floating button over its bottom edge shows: a
    /// reader who scrolled away from the bottom gets a way back, and is told
    /// when the agent kept talking below them.
    enum JumpToLatest: Equatable {
        /// The reader is at the bottom — there is nowhere to jump to.
        case hidden
        /// The reader scrolled up and nothing arrived since.
        case jump
        /// The reader scrolled up and messages arrived below them since.
        case newMessages
    }

    static func jumpToLatest(distanceFromBottom: CGFloat, messagesArrivedWhileAway: Bool) -> JumpToLatest {
        if distanceFromBottom <= atBottomTolerance { return .hidden }
        return messagesArrivedWhileAway ? .newMessages : .jump
    }

    /// The distance from the bottom a scrolled list keeps once its stack reports
    /// a new position — `offset` above the window and `distanceFromBottom` below
    /// it, against the `lastOffset` and `recorded` distance kept before.
    ///
    /// Only a scroll of the list itself moves the recorded distance: content
    /// arriving pushes the bottom further below the window without the reader
    /// having moved, and that must not read as their having scrolled away from
    /// the stream. So a new distance is taken when the reader is at the bottom
    /// or has just scrolled up; anything else keeps the one recorded. The chat's
    /// bubble list and the autopilot transcript panes both judge it here.
    static func recordedDistance(offset: CGFloat, distanceFromBottom: CGFloat,
                                 lastOffset: CGFloat, recorded: CGFloat) -> CGFloat {
        let scrolledUp = offset < lastOffset
        return distanceFromBottom <= atBottomTolerance || scrolledUp ? distanceFromBottom : recorded
    }

    static func runGitBranch(at url: URL) async -> String {
        await Task.detached {
            // `branch --show-current` (not `rev-parse --abbrev-ref HEAD`): on a repo
            // with no commits yet it still reports the branch name, where rev-parse
            // prints the literal "HEAD" and exits 128. It prints nothing on a
            // detached HEAD, which the header renders as no chip at all.
            let result = SubprocessOutput.git(["-C", url.path(percentEncoded: false), "branch", "--show-current"])
            guard result.status == 0 else { return "" }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(viewModel.isStreaming ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(viewModel.agentName)
                .font(.headline)

            if viewModel.isAside {
                Text("aside")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("A temporary fork of another agent's session. It isn't part of the team and won't survive a restart.")
            }

            if let unattended = viewModel.unattendedIndicator {
                UnattendedIndicator(model: unattended)
            }

            Divider()
                .frame(height: 16)

            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.projectURL.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !gitBranch.isEmpty {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


            if viewModel.contextWindowSize != nil, let contextPct = statusLine.contextWindowPercent {
                Text("\(Int(contextPct))%")
                    .font(.caption2)
                    .foregroundStyle(contextPct > 80 ? .red : contextPct > 50 ? .orange : .secondary)
                    .help("Context window usage")
            }

            Spacer()

            if let session = viewModel.currentSession, !session.isUntitled {
                Text(session.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                viewModel.closeSearch()
                isTranscriptMode.toggle()
            } label: {
                Image(systemName: isTranscriptMode ? "text.justify" : "text.bubble")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isTranscriptMode ? .blue : .secondary)
            .help(isTranscriptMode ? "Bubble View (⇧⌘T)" : "Transcript View (⇧⌘T)")
            .accessibilityIdentifier("chat-transcript-toggle-button")

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var contextStrip: some View {
        HStack(spacing: 6) {
            ContextChip(label: Self.modelChipLabel(viewModel.agentModel), icon: "cpu")
            ContextChip(label: Self.permissionModeChipLabel(viewModel.agentPermissionMode), icon: "lock.shield")
            if !viewModel.agentMCPServers.isEmpty {
                ContextChip(label: viewModel.agentMCPServers.joined(separator: ", "), icon: "puzzlepiece.extension")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The strip's model chip, named as the sidebar and the info popover name the
    /// model; a model the catalog does not know is shown as stored.
    static func modelChipLabel(_ model: String) -> String {
        model.isEmpty ? "model" : ModelCatalog.displayName(for: model)
    }

    /// The strip's mode chip, named as `/mode` and the Edit Agent sheet name the
    /// mode; a mode the app does not know is shown as stored.
    static func permissionModeChipLabel(_ mode: String) -> String {
        SettingNames.permissionMode(mode)
    }

    private func lastAgentText() -> String {
        viewModel.messages.reversed().compactMap { msg in
            if case .agent = msg.sender, case .text(let t) = msg.content { return t }
            return nil
        }.first ?? ""
    }

    /// What the paperclip lets you pick: every text and image file, the same
    /// files a drop attaches — `ChatAttachment.read(contentsOf:)` sends text as
    /// text, converts HEIC, TIFF and BMP to PNG and passes SVG through.
    static let attachableContentTypes: [UTType] = [.text, .image]

    private func pickAttachment() {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "attach files to chat")
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.attachableContentTypes
        panel.message = "Select files to attach"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            viewModel.addAttachment(url: url)
        }
    }

    /// Whether the message list draws `message` — the list's own rule, reachable
    /// from outside the file.
    static func shouldDisplay(_ message: Message) -> Bool {
        MessageListContainer.shouldDisplay(message)
    }

    /// The marker above a message that starts a new calendar day — "Today",
    /// "Yesterday" or its date — or nil when the message before it was sent the
    /// same day.
    static func dayMarkerLabel(
        for date: Date,
        previous: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        if let previous, calendar.isDate(previous, inSameDayAs: date) { return nil }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let style = Date.FormatStyle(
            date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone
        )
        return style.format(date)
    }
}

/// A caption between thin rules marking where a calendar day starts in the
/// message list; draws nothing without a label.
private struct DayMarker: View {
    let label: String?

    var body: some View {
        if let label {
            HStack(spacing: 8) {
                line
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                line
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
    }
}

/// Where the message stack sits in the scroll view's window onto it: how far
/// above the top of the window it starts, and how far below the bottom of it
/// the conversation ends.
private struct MessageListScroll: Equatable {
    var offset: CGFloat
    var distanceFromBottom: CGFloat
}

/// Where the reader was left in the message list, kept as one value so a
/// scroll writes the view's state once, and only when something moved.
struct MessageListPosition: Equatable {
    /// The stack's offset above the window as of the last scroll, which is how
    /// a scroll is told from content growing.
    var lastOffset: CGFloat = 0
    /// How far the bottom of the stack sits below the bottom of the window.
    var distanceFromBottom: CGFloat = 0
    /// How many messages the list held when the reader, scrolled up, first let
    /// one arrive below them; `nil` while they are at the bottom.
    var messageCountWhenLeft: Int?

    /// The position once the stack reports where it now sits: the distance
    /// `ChatView.recordedDistance` keeps, and — back at the bottom — no count
    /// of messages from when the reader left.
    func recording(offset: CGFloat, distanceFromBottom reported: CGFloat) -> MessageListPosition {
        var next = self
        next.distanceFromBottom = ChatView.recordedDistance(
            offset: offset, distanceFromBottom: reported, lastOffset: lastOffset, recorded: distanceFromBottom)
        next.lastOffset = offset
        if next.distanceFromBottom <= ChatView.atBottomTolerance { next.messageCountWhenLeft = nil }
        return next
    }
}

// MARK: - MessageListContainer (isolates message observation from InputBar)

struct MessageListContainer: View {
    @Bindable var viewModel: ChatViewModel
    let isTranscriptMode: Bool
    let isStreaming: Bool
    let lastCompletedDuration: Int?
    let elapsedSeconds: Int

    init(viewModel: ChatViewModel, isTranscriptMode: Bool, isStreaming: Bool,
         lastCompletedDuration: Int?, elapsedSeconds: Int) {
        self.viewModel = viewModel
        self.isTranscriptMode = isTranscriptMode
        self.isStreaming = isStreaming
        self.lastCompletedDuration = lastCompletedDuration
        self.elapsedSeconds = elapsedSeconds
    }

    /// The height of the scroll view's window onto the list, which the distance
    /// from the bottom is measured against.
    @State private var viewportHeight: CGFloat = 0
    /// Where the reader is in the list — see `MessageListPosition`.
    @State private var position = MessageListPosition()

    /// The scroll view's own frame, which the message stack's position is read
    /// against: in it the stack's `maxY` is the bottom of the conversation and
    /// the viewport's height is the bottom of the window onto it.
    private static let scrollSpace = "message-list-scroll"

    var body: some View {
        // Ahead of the mode switch, because both modes render an empty chat as
        // blank space — the bubble list draws no rows, the transcript draws an
        // empty text view. A chat nobody has spoken in yet is the first thing a
        // new agent shows you, so it says how to speak in it instead.
        //
        // Not while a turn is in flight: an agent triggered by a handoff starts
        // streaming before its first message lands, and "No messages yet" over a
        // working agent is worse than the blank it replaced.
        if viewModel.messages.isEmpty && !isStreaming {
            PanelEmptyState(.chatMessages)
                .accessibilityIdentifier("chat-empty-state")
        } else if isTranscriptMode {
            TranscriptView(messages: viewModel.messages)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        let resultsByCallID = Dictionary(
                            viewModel.messages.compactMap { message -> (String, Message.ToolResult)? in
                                guard case .toolResult(let result) = message.content else { return nil }
                                return (result.toolCallID, result)
                            },
                            uniquingKeysWith: { _, last in last }
                        )
                        let lastAgentTextID = viewModel.messages.last(where: {
                            if case .text = $0.content, case .agent = $0.sender { return $0.parentToolUseID == nil }
                            return false
                        })?.id
                        let dayMarkers = Self.dayMarkers(for: viewModel.messages.filter { Self.shouldDisplay($0) })
                        let terminal = ChatView.usesTerminalLook(for: viewModel.messages)
                        let children = SubagentChild.byParent(in: viewModel.messages, results: resultsByCallID)
                        ForEach(viewModel.messages.filter { Self.shouldDisplay($0) }) { message in
                            DayMarker(label: dayMarkers[message.id])
                            row(for: message,
                                results: resultsByCallID,
                                children: children,
                                showsCursor: isStreaming && message.id == lastAgentTextID,
                                terminal: terminal)
                            .modifier(SearchMatchMarker(
                                isMarked: viewModel.isSearching && message.id == viewModel.currentMatchID
                            ))
                        }

                        if isStreaming {
                            streamingIndicator
                                .id("streaming-indicator")
                        } else if lastCompletedDuration != nil && !viewModel.messages.isEmpty {
                            completionSummary
                                .id("completion-summary")
                        }
                    }
                    .padding(.vertical, 8)
                    .background(
                        GeometryReader { stack in
                            let frame = stack.frame(in: .named(Self.scrollSpace))
                            Color.clear.onChange(of: MessageListScroll(
                                offset: -frame.minY,
                                distanceFromBottom: frame.maxY - viewportHeight
                            )) { _, scroll in
                                record(scroll)
                            }
                        }
                    )
                }
                .accessibilityIdentifier("message-list")
                .coordinateSpace(.named(Self.scrollSpace))
                .overlay(alignment: .bottom) {
                    jumpToLatestButton(proxy: proxy)
                }
                .background(
                    GeometryReader { viewport in
                        Color.clear.onChange(of: viewport.size.height, initial: true) { _, height in
                            viewportHeight = height
                        }
                    }
                )
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.messages.count) { oldCount, _ in
                    if viewModel.isSearching { viewModel.refreshSearch() }
                    let action = ChatView.streamScrollAction(
                        distanceFromBottom: position.distanceFromBottom,
                        isSearching: viewModel.isSearching,
                        hasMatches: !viewModel.matchingMessageIDs.isEmpty
                    )
                    if action == .stayPut && position.messageCountWhenLeft == nil { position.messageCountWhenLeft = oldCount }
                    guard action == .follow else { return }
                    withAnimation(KiteloopTokens.Anim.messageAppear) {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.conversationTree.activeBranchID) { _, _ in
                    if viewModel.isSearching { viewModel.refreshSearch() }
                }
                .onChange(of: viewModel.currentSession?.id) { _, _ in
                    if viewModel.isSearching { viewModel.refreshSearch() }
                }
                .onChange(of: elapsedSeconds) { _, _ in
                    guard isStreaming, ChatView.streamScrollAction(
                        distanceFromBottom: position.distanceFromBottom,
                        isSearching: viewModel.isSearching,
                        hasMatches: !viewModel.matchingMessageIDs.isEmpty
                    ) == .follow else { return }
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.performSearch()
                    if let current = viewModel.currentMatchID {
                        withAnimation {
                            proxy.scrollTo(current, anchor: .center)
                        }
                    }
                }
                .onChange(of: viewModel.currentMatchIndex) { _, _ in
                    if let current = viewModel.currentMatchID {
                        withAnimation {
                            proxy.scrollTo(current, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// The day marker drawn above each displayed message that starts a
    /// calendar day, keyed by the message it goes above.
    private static func dayMarkers(for displayed: [Message]) -> [UUID: String] {
        var markers: [UUID: String] = [:]
        let now = Date()
        var previous: Date?
        for message in displayed {
            markers[message.id] = ChatView.dayMarkerLabel(
                for: message.timestamp, previous: previous, now: now, calendar: .current, locale: .current
            )
            previous = message.timestamp
        }
        return markers
    }

    static func shouldDisplay(_ message: Message) -> Bool {
        switch message.content {
        case .toolResult:
            return false
        case .toolCall, .text, .thinking:
            // A subagent's call, text and thinking are drawn under the `Agent`
            // call that made them.
            return ToolCallNesting.isTopLevel(message)
        case .approval(let req):
            // A question stays where it was asked, marked answered; a decided
            // permission request leaves the chat.
            return req.tool == "ask_human" || req.status == .pending
        default:
            return true
        }
    }

    @AppStorage("playfulStatusVerbs") private var playfulStatusVerbs = true

    /// Action-sports verbs for the live ticker — the app is named after a
    /// kite trick, so the theme is on brand. Facts (tool, file, time, cost)
    /// always render next to the verb; the verb is flavor, never information.
    private static let statusVerbs = [
        "Carving", "Sending it", "Dropping in", "Catching air", "Looping",
        "Boosting", "Gliding", "Trimming", "Jibing", "Tacking",
        "Edging", "Pumping", "Charging", "Reading the wind", "Riding the line",
        "Threading the lines", "Hiking out", "Popping off", "Landing clean", "Flowing"
    ]

    private var currentVerb: String {
        guard playfulStatusVerbs else { return "Working" }
        // Rotate every 5 seconds; offset by session so parallel agents differ.
        let index = (elapsedSeconds / 5 + abs(viewModel.agentID.hashValue)) % Self.statusVerbs.count
        return Self.statusVerbs[index]
    }

    /// One message's row. The interactive cards are the same in either look;
    /// everything else is drawn terminal-style or as a bubble.
    @ViewBuilder
    func row(for message: Message, results: [String: Message.ToolResult], children: [String: [SubagentChild]],
             showsCursor: Bool, terminal: Bool) -> some View {
        if case .approval(let req) = message.content, req.tool == "ask_human" {
            AskHumanBubble(
                request: req,
                isAnswerable: viewModel.pendingHumanToolCallID == req.id
            ) { answer in
                Task { await viewModel.respondToHuman(requestID: req.id, answer: answer) }
            }
            .id(message.id)
        } else if case .plan(let plan) = message.content {
            PlanCard(plan: plan) { answer, feedback in
                Task { await viewModel.answerPlan(messageID: message.id, with: answer, feedback: feedback) }
            }
            .id(message.id)
        } else if case .mcpAuthRequest(let req) = message.content {
            MCPAuthorizationCard(
                request: req,
                isAnswerable: viewModel.pendingMCPAuthRequestID == req.toolCallID
            ) { envValues in
                Task { await viewModel.authorizeMCPServer(requestID: req.id, envValues: envValues) }
            } onDeny: {
                viewModel.denyMCPServer(requestID: req.id)
            }
            .id(message.id)
        } else {
            contentRow(for: message, results: results, children: children, showsCursor: showsCursor, terminal: terminal)
                .overlay(alignment: .topTrailing) { branchMark(for: message) }
                .contextMenu {
                    Button("Branch from Here") { viewModel.branchFromMessage(id: message.id) }
                    ForEach(viewModel.branchesForked(at: message.id)) { branch in
                        Button("Switch to Branch \(branch.name)") { viewModel.switchToBranch(id: branch.id) }
                    }
                }
                .id(message.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    /// The branch symbol and how many branches were made from `message`, not
    /// counting the one being shown; nothing when there are none.
    @ViewBuilder
    private func branchMark(for message: Message) -> some View {
        let count = viewModel.branchesForked(at: message.id).count
        if count > 0 {
            Label("\(count)", systemImage: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
                .background(.background, in: Capsule())
                .help(count == 1 ? "1 branch was made from this message" : "\(count) branches were made from this message")
        }
    }

    @ViewBuilder
    private func contentRow(for message: Message, results: [String: Message.ToolResult], children: [String: [SubagentChild]],
                            showsCursor: Bool, terminal: Bool) -> some View {
        switch (message.content, terminal) {
        case (.toolCall(let call), true):
            TerminalToolCallRow(toolCall: call, result: results[call.id],
                                task: viewModel.task(forCall: call), children: children[call.id] ?? [])
        case (.toolCall(let call), false):
            ToolCallView(toolCall: call, result: results[call.id],
                         task: viewModel.task(forCall: call), children: children[call.id] ?? [])
        case (_, true):
            TerminalMessageRow(message: message, showStreamingCursor: showsCursor,
                               onBranchFromHere: { viewModel.branchFromMessage(id: message.id) })
        case (_, false):
            MessageBubble(message: message, showStreamingCursor: showsCursor, senderName: viewModel.displayName(forAgentID:),
                          onBranchFromHere: { viewModel.branchFromMessage(id: message.id) })
        }
    }

    private var streamingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            HStack(spacing: 6) {
                PulsingDots()
                    .frame(width: 24, height: 12)
                Text("\(currentVerb)…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                if let activity = viewModel.currentActivity {
                    Text("·")
                    Text(activity)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        // The command the label stands in for, kept within reach
                        // rather than traded away for the sentence.
                        .help(viewModel.currentActivityDetail ?? activity)
                }
                Text("·")
                Text(formatDuration(elapsedSeconds))
                    .font(.system(.caption, design: .monospaced))
                if viewModel.lastInputTokens > 0 {
                    Text("·")
                    Text("\u{2191}\(formatTokens(viewModel.lastInputTokens)) \u{2193}\(formatTokens(viewModel.lastOutputTokens))")
                        .font(.system(.caption, design: .monospaced))
                }
                if viewModel.costUSD > 0 {
                    Text("·")
                    Text(String(format: "$%.4f", viewModel.costUSD))
                        .font(.system(.caption, design: .monospaced))
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.3), value: currentVerb)
        }
    }

    private var completionSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            if let duration = lastCompletedDuration {
                Text(formatDuration(duration))
                    .font(.system(.caption, design: .monospaced))
            }
            if viewModel.lastInputTokens > 0 {
                Text("·")
                Text("\u{2191}\(formatTokens(viewModel.lastInputTokens)) \u{2193}\(formatTokens(viewModel.lastOutputTokens))")
                    .font(.system(.caption, design: .monospaced))
            }
            if viewModel.lastTurnCostUSD > 0 {
                Text("·")
                Text(String(format: "$%.4f", viewModel.lastTurnCostUSD))
                    .font(.system(.caption, design: .monospaced))
                    .help(String(format: "This turn's cost. Session total: $%.4f", viewModel.costUSD))
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Takes down where the reader is from the stack's geometry — which distance
    /// is kept is `ChatView.recordedDistance`'s judgement.
    private func record(_ scroll: MessageListScroll) {
        let next = position.recording(offset: scroll.offset, distanceFromBottom: scroll.distanceFromBottom)
        if next != position { position = next }
    }

    /// The floating way back to the newest message, drawn over the bottom of
    /// the list while `ChatView.jumpToLatest` says the reader is away from it.
    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        let arrived = position.messageCountWhenLeft.map { viewModel.messages.count > $0 } ?? false
        let state = ChatView.jumpToLatest(distanceFromBottom: position.distanceFromBottom, messagesArrivedWhileAway: arrived)
        if state != .hidden {
            Button {
                scrollToBottom(proxy: proxy)
            } label: {
                Label(state == .newMessages ? "New messages" : "Jump to latest", systemImage: "arrow.down")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .help("Scroll to the latest message")
            .accessibilityIdentifier("jump-to-latest-button")
            .transition(.opacity)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let targetID: AnyHashable
        if isStreaming {
            targetID = "streaming-indicator"
        } else if lastCompletedDuration != nil {
            targetID = "completion-summary"
        } else if let last = viewModel.messages.last {
            targetID = last.id
        } else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(targetID, anchor: .bottom)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        DurationPhrase.phrase(TimeInterval(seconds))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - SearchMatchMarker

/// Draws a rounded outline around the message the find bar's counter is on, so
/// Next and Previous land somewhere visible rather than on another identical
/// row. Applied once around every kind of row; nothing is drawn when the bar is
/// shut, since the row is then never the marked one.
private struct SearchMatchMarker: ViewModifier {
    let isMarked: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isMarked {
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md)
                    .strokeBorder(Color.accentColor, lineWidth: KiteloopTokens.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md)
                            .fill(Color.accentColor.opacity(KiteloopTokens.Opacity.light))
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - PulsingDots

private struct ContextChip: View {
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct PulsingDots: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(dotScale(for: i))
                    .opacity(dotOpacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dotScale(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.15
        return phase == 1 ? 1.0 + offset * 0.3 : 0.7 + offset * 0.1
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.1
        return phase == 1 ? 1.0 - offset : 0.4 + offset
    }
}
