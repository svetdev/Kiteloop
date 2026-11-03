import KiteloopCore
import SwiftUI

struct InputBar: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    let isStreaming: Bool
    /// The messages you typed that wait for the current turn, oldest first.
    let queuedMessages: [String]
    /// Takes the queued message at an index in `queuedMessages` back into the input box.
    let onTakeBackQueued: (Int) -> Void
    let messages: [Message]
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttach: () -> Void
    /// Attaches each file dropped or pasted onto the input, or says why not.
    let onAttachFiles: ([URL]) -> Void
    let skillRegistry: SkillRegistry?
    let agentCatalogStore: AgentCatalogStore?
    let projectAgents: [Agent]
    /// Which conversation `messages` belongs to — the session and the active
    /// branch. When it changes the conversation under the bar has been swapped
    /// out, and the recalled history belongs to the one now on screen.
    let conversationID: String?
    /// Whether the chat's find bar is open. While it is, Esc belongs to the
    /// find bar and the stop button carries no shortcut.
    let isSearchOpen: Bool
    /// The runtime of the agent this bar talks to — the slash popover leaves out
    /// the commands that only refuse on it.
    let runtime: RuntimeKind
    /// The folder the chat's agent runs in: Tab completes a relative path from
    /// here, not from the app's own working directory (`/` for an app opened
    /// from Finder).
    let projectURL: URL?

    @State private var localText: String = ""
    @State private var textHeight: CGFloat = 20
    @State private var slashMatches: [Skill] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var mentionMatches: [MentionCandidate] = []
    @State private var mentionSelectedIndex: Int = 0
    /// The `/` token the command popover was last dismissed on, and the `@` token
    /// the mention popover was last dismissed on — `nil` when neither was.
    @State private var dismissedSlashToken: String?
    @State private var dismissedMentionToken: String?
    @State private var inputHistory: [String] = []
    @State private var historyIndex: Int = -1
    @State private var draftText: String = ""
    @State private var isSearchingHistory: Bool = false
    @State private var historySearchQuery: String = ""
    @State private var historySearchMatch: String?
    @State private var inputFocusRequest: Int = 0
    @FocusState private var isHistorySearchFocused: Bool

    init(
        text: Binding<String>,
        attachments: Binding<[ChatAttachment]>,
        isStreaming: Bool,
        queuedMessages: [String] = [],
        onTakeBackQueued: @escaping (Int) -> Void = { _ in },
        messages: [Message] = [],
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onAttach: @escaping () -> Void,
        onAttachFiles: @escaping ([URL]) -> Void = { _ in },
        skillRegistry: SkillRegistry? = nil,
        agentCatalogStore: AgentCatalogStore? = nil,
        projectAgents: [Agent] = [],
        conversationID: String? = nil,
        isSearchOpen: Bool = false,
        runtime: RuntimeKind = .claude,
        projectURL: URL? = nil
    ) {
        self.projectURL = projectURL
        self._text = text
        self._attachments = attachments
        self.isStreaming = isStreaming
        self.queuedMessages = queuedMessages
        self.onTakeBackQueued = onTakeBackQueued
        self.messages = messages
        self.onSend = onSend
        self.onStop = onStop
        self.onAttach = onAttach
        self.onAttachFiles = onAttachFiles
        self.skillRegistry = skillRegistry
        self.agentCatalogStore = agentCatalogStore
        self.projectAgents = projectAgents
        self.conversationID = conversationID
        self.isSearchOpen = isSearchOpen
        self.runtime = runtime
    }

    /// Esc stops the turn, but only while the find bar is shut: with it open Esc
    /// closes that bar, and the stop button stands down so exactly one view owns
    /// the key. The button itself stays on screen and clickable either way.
    static func stopShortcut(isSearchOpen: Bool) -> KeyboardShortcut? {
        isSearchOpen ? nil : KeyboardShortcut(.escape, modifiers: [])
    }

    /// What Up recalls: the text of the human messages in `messages`, oldest
    /// first. An agent or system message, or a human one that is not text —
    /// a pasted image — was never typed into this field, so it is skipped.
    static func sentHistory(from messages: [Message]) -> [String] {
        messages
            .filter { $0.sender == .human }
            .compactMap { guard case .text(let t) = $0.content else { return nil }; return t }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                attachmentPreview
                Divider()
            }

            if Self.showsQueuedStrip(isStreaming: isStreaming, queuedMessages: queuedMessages) {
                queuedHint
                Divider()
            }

            if isSearchingHistory {
                historySearchBar
                Divider()
            }

            HStack(spacing: 8) {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach file")
                .accessibilityIdentifier("attach-button")

                ExpandingTextInput(text: $localText, textHeight: $textHeight, onSubmit: {
                    submitInput()
                }, onKeyAction: handleKeyAction, onAttachments: { pasted in
                    attachments.append(contentsOf: pasted)
                }, onFileURLs: onAttachFiles, focusRequest: inputFocusRequest)
                .accessibilityIdentifier("input-text-field")
                .frame(height: textHeight + 12)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                )
                .animation(.easeOut(duration: 0.15), value: textHeight)
                .onChange(of: text) { _, newValue in
                    if localText != newValue { localText = newValue }
                }
                .onChange(of: localText) { _, newValue in
                    // The draft lives in the view model, so it outlives this
                    // bar when another agent is selected and back.
                    if text != newValue { text = newValue }
                    updateSlashMatches(for: newValue)
                    updateMentionMatches(for: newValue)
                }
                .popover(isPresented: Binding(
                    get: { !slashMatches.isEmpty },
                    set: { if !$0 { dismissSlashPopover() } }
                ), arrowEdge: .top) {
                    SlashCommandPopover(
                        skills: slashMatches,
                        selectedIndex: slashSelectedIndex,
                        onSelect: { skill in
                            localText = "/\(skill.name) "
                            slashMatches = []
                        }
                    )
                }
                .popover(isPresented: Binding(
                    get: { !mentionMatches.isEmpty },
                    set: { if !$0 { dismissMentionPopover() } }
                ), arrowEdge: .top) {
                    MentionPopover(
                        entries: mentionMatches,
                        selectedIndex: mentionSelectedIndex,
                        onSelect: { entry in
                            insertMention(entry.handle)
                            mentionMatches = []
                        }
                    )
                }
                .onAppear {
                    localText = text
                    inputHistory = Self.sentHistory(from: messages)
                }
                .onChange(of: conversationID) { _, _ in
                    // A new chat, another session, another branch: browsing
                    // starts again at the newest message of what is on screen.
                    inputHistory = Self.sentHistory(from: messages)
                    historyIndex = -1
                    draftText = ""
                }

                if isStreaming {
                    Button {
                        submitInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("queue-button")
                    .disabled(localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Queue message (sends after current turn)")

                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("stop-button")
                    .keyboardShortcut(Self.stopShortcut(isSearchOpen: isSearchOpen))
                    .help("Stop the current turn (Esc)")
                } else {
                    Button {
                        submitInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityIdentifier("send-button")
                    .disabled(localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (⌘↵)")
                }
            }
            .padding(12)
        }
        .background(.bar)
        .onChange(of: isSearchingHistory) { _, isSearching in
            if isSearching { isHistorySearchFocused = true }
        }
    }

    private func submitInput() {
        expandBangSyntax()
        let trimmed = localText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if !trimmed.isEmpty {
            inputHistory.append(localText)
        }
        historyIndex = -1
        draftText = ""
        text = localText
        onSend()
    }

    /// The queued strip shows while a turn runs and you have typed something
    /// that waits for it; what the app or a teammate queued is not counted.
    static func showsQueuedStrip(isStreaming: Bool, queuedMessages: [String]) -> Bool {
        isStreaming && !queuedMessages.isEmpty
    }

    /// One line of a queued message: its first line, trimmed.
    static func queuedPreview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private var queuedHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(queuedMessages.count == 1
                 ? "1 message queued — will send after current turn"
                 : "\(queuedMessages.count) messages queued — will send after current turn")
                .font(.caption)
            ForEach(Array(queuedMessages.enumerated()), id: \.offset) { index, message in
                queuedRow(index: index, message: message)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func queuedRow(index: Int, message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(Self.queuedPreview(message))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button { onTakeBackQueued(index) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Take this message back into the input box")
            .accessibilityLabel("Take back queued message")
        }
    }

    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func attachmentThumbnail(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 4) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "doc")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 80)

            Button {
                withAnimation { attachments.removeAll { $0.id == attachment.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }

    // MARK: - Key Action Handling

    private func handleKeyAction(_ action: InputKeyAction) -> Bool {
        if !slashMatches.isEmpty, let handled = handleSlashPopoverKey(action) { return handled }
        if !mentionMatches.isEmpty, let handled = handleMentionPopoverKey(action) { return handled }
        return handleInputKey(action)
    }

    /// The slash-command popover's answer to `action`, or nil for a key it lets through.
    private func handleSlashPopoverKey(_ action: InputKeyAction) -> Bool? {
        switch action {
        case .historyUp:
            slashSelectedIndex = max(0, slashSelectedIndex - 1)
        case .historyDown:
            slashSelectedIndex = min(slashMatches.count - 1, slashSelectedIndex + 1)
        case .popoverConfirm:
            let skill = slashMatches[slashSelectedIndex]
            localText = "/\(skill.name) "
            slashMatches = []
        case .popoverDismiss:
            dismissSlashPopover()
        case .reverseSearch, .tabComplete:
            return nil
        }
        return true
    }

    /// The mention popover's answer to `action`, or nil for a key it lets through.
    private func handleMentionPopoverKey(_ action: InputKeyAction) -> Bool? {
        switch action {
        case .historyUp:
            mentionSelectedIndex = max(0, mentionSelectedIndex - 1)
        case .historyDown:
            mentionSelectedIndex = min(mentionMatches.count - 1, mentionSelectedIndex + 1)
        case .popoverConfirm:
            insertMention(mentionMatches[mentionSelectedIndex].handle)
            mentionMatches = []
        case .popoverDismiss:
            dismissMentionPopover()
        case .reverseSearch, .tabComplete:
            return nil
        }
        return true
    }

    /// `action` with no popover open: history, reverse search, path completion.
    private func handleInputKey(_ action: InputKeyAction) -> Bool {
        switch action {
        case .historyUp:
            return stepHistoryBack()
        case .historyDown:
            return stepHistoryForward()
        case .reverseSearch:
            isSearchingHistory = true
            historySearchQuery = ""
            historySearchMatch = nil
            return true
        case .tabComplete:
            return completeFilePath()
        case .popoverConfirm, .popoverDismiss:
            return false
        }
    }

    /// Up arrow: recall the previous sent message, keeping the draft to come back to.
    private func stepHistoryBack() -> Bool {
        guard !inputHistory.isEmpty else { return false }
        if historyIndex == -1 { draftText = localText }
        historyIndex = min(historyIndex + 1, inputHistory.count - 1)
        localText = inputHistory[inputHistory.count - 1 - historyIndex]
        return true
    }

    /// Down arrow: step toward newer history, ending back at the draft.
    private func stepHistoryForward() -> Bool {
        guard historyIndex >= 0 else { return false }
        historyIndex -= 1
        localText = historyIndex < 0 ? draftText : inputHistory[inputHistory.count - 1 - historyIndex]
        return true
    }

    // MARK: - Popover Dismissal

    /// Whether a popover dismissed on `dismissed` is still dismissed while the
    /// token under the cursor is `token`. It stays shut while one of the two is a
    /// prefix of the other, so typing on inside the token it was dismissed on, or
    /// backspacing within that token, keeps it shut; a token that diverges from
    /// it — or no token at all — opens it again, as does a popover never dismissed.
    static func isPopoverStillDismissed(token: String, dismissedOn dismissed: String?) -> Bool {
        guard let dismissed, !token.isEmpty else { return false }
        return token.hasPrefix(dismissed) || dismissed.hasPrefix(token)
    }

    /// Closes the command popover, remembering the `/` token it was dismissed on.
    private func dismissSlashPopover() {
        dismissedSlashToken = localText
        slashMatches = []
    }

    /// Closes the mention popover, remembering the `@` token it was dismissed on.
    private func dismissMentionPopover() {
        dismissedMentionToken = localText.lastIndex(of: "@").map { String(localText[$0...]) }
        mentionMatches = []
    }

    /// Whether the command popover stays shut for `token`, forgetting the dismissal
    /// once the token has moved off the one it was dismissed on.
    private func slashPopoverStaysDismissed(for token: String) -> Bool {
        if Self.isPopoverStillDismissed(token: token, dismissedOn: dismissedSlashToken) { return true }
        dismissedSlashToken = nil
        return false
    }

    /// Whether the mention popover stays shut for `token`, forgetting the dismissal
    /// once the token has moved off the one it was dismissed on.
    private func mentionPopoverStaysDismissed(for token: String) -> Bool {
        if Self.isPopoverStillDismissed(token: token, dismissedOn: dismissedMentionToken) { return true }
        dismissedMentionToken = nil
        return false
    }

    // MARK: - Reverse History Search

    private var historySearchBar: some View {
        HStack(spacing: 6) {
            Text("(reverse-i-search)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: $historySearchQuery)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($isHistorySearchFocused)
                .accessibilityIdentifier("history-search-field")
                .onSubmit { closeHistorySearch(accepting: historySearchMatch) }
                .onExitCommand { closeHistorySearch(accepting: nil) }
                .onChange(of: historySearchQuery) { _, query in
                    historySearchMatch = inputHistory.last(where: {
                        $0.localizedCaseInsensitiveContains(query)
                    })
                }
            if let match = historySearchMatch {
                Text(match)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !historySearchQuery.isEmpty {
                Text("no match")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The one way the history search closes — Enter with the match, Esc with nil.
    /// The cursor goes back to the message field either way.
    private func closeHistorySearch(accepting match: String?) {
        if let match {
            localText = match
        }
        isSearchingHistory = false
        isHistorySearchFocused = false
        inputFocusRequest += 1
    }

    // MARK: - Bang Expansion

    private func expandBangSyntax() {
        localText = Self.expandingBangSyntax(in: localText, lastMessage: inputHistory.last)
    }

    /// The text to send for `text`: the whole message `!!` becomes `lastMessage`,
    /// and each `!$` standing alone between whitespace, outside backticks, becomes
    /// its last word. Any other `!$` — in a word, a regex, a path — is left as typed.
    static func expandingBangSyntax(in text: String, lastMessage: String?) -> String {
        guard let last = lastMessage else { return text }
        if text == "!!" { return last }
        let lastWord = last.split(separator: " ").last.map(String.init) ?? last
        let chars = Array(text)
        var result = ""
        var inBackticks = false
        var i = 0
        while i < chars.count {
            if chars[i] == "`" { inBackticks.toggle() }
            if !inBackticks && isStandaloneBangDollar(chars, at: i) {
                result += lastWord
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    private static func isStandaloneBangDollar(_ chars: [Character], at i: Int) -> Bool {
        guard chars[i...].starts(with: ["!", "$"]) else { return false }
        let before = i == 0 || chars[i - 1].isWhitespace
        let after = i + 2 == chars.count || chars[i + 2].isWhitespace
        return before && after
    }

    // MARK: - File Path Completion

    private func completeFilePath() -> Bool {
        var words = localText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let lastWord = words.last,
              let completed = Self.completingFilePath(lastWord, relativeTo: projectURL) else { return false }
        words[words.count - 1] = completed
        localText = words.joined(separator: " ")
        return true
    }

    /// The path-like `word` completed, in the form it was typed — relative
    /// stays relative, `~/` keeps its tilde — or nil when it names nothing to
    /// list, so Tab falls through. A word with nothing more to add comes back
    /// unchanged. A relative word is looked up under `base`; `/` and `~/`
    /// words, or any word with no base, as they are.
    ///
    /// Several matches extend to their longest common prefix (bash-style). A
    /// disambiguation popover is intentionally omitted — repeated Tab narrows
    /// the prefix, which is sufficient for path entry here.
    static func completingFilePath(_ word: String, relativeTo base: URL?) -> String? {
        guard isPathLike(word) else { return nil }
        let root = relativeRoot(for: word, base: base)
        guard let listing = pathListing(for: (root ?? "") + word) else { return nil }
        guard let completed = completion(in: listing) else { return word }
        guard let root else { return collapsingTilde(in: completed, like: word) }
        return completed.hasPrefix(root) ? String(completed.dropFirst(root.count)) : completed
    }

    /// `base` as a directory prefix ending in `/`, for a word that is relative
    /// to it; nil for an absolute or `~/` word, or with no base.
    private static func relativeRoot(for word: String, base: URL?) -> String? {
        guard let base, !word.hasPrefix("/"), !word.hasPrefix("~") else { return nil }
        let path = base.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// A directory and the entries in it that start with the token's last component.
    struct PathListing {
        let dirPath: String
        let prefix: String
        let matches: [String]
    }

    private static func isPathLike(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("./") || word.contains("/")
    }

    /// Nil when the directory cannot be read or nothing in it matches.
    static func pathListing(for word: String) -> PathListing? {
        let expanded = (word as NSString).expandingTildeInPath
        let dirPath: String
        let prefix: String
        // The word as typed: expanding the tilde also drops a trailing slash,
        // which would read `dir/` as the prefix `dir` in its parent.
        if word.hasSuffix("/") {
            dirPath = expanded
            prefix = ""
        } else {
            dirPath = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return nil }
        let matches = prefix.isEmpty ? entries : entries.filter { $0.hasPrefix(prefix) }
        guard !matches.isEmpty else { return nil }
        return PathListing(dirPath: dirPath, prefix: prefix, matches: matches)
    }

    /// The full path of a single match (a directory gets its trailing `/`), or the
    /// longest common prefix of several — nil when that extends nothing.
    static func completion(in listing: PathListing) -> String? {
        if listing.matches.count == 1 {
            var fullPath = (listing.dirPath as NSString).appendingPathComponent(listing.matches[0])
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                fullPath += "/"
            }
            return fullPath
        }
        let common = longestCommonPrefix(listing.matches)
        guard common.count > listing.prefix.count else { return nil }
        return (listing.dirPath as NSString).appendingPathComponent(common)
    }

    /// Re-collapse ~ if the original used it.
    private static func collapsingTilde(in path: String, like word: String) -> String {
        guard word.hasPrefix("~/") else { return path }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    // MARK: - Slash Command Detection

    private func updateSlashMatches(for text: String) {
        guard text.hasPrefix("/"), !text.contains(" "),
              !slashPopoverStaysDismissed(for: text) else {
            slashMatches = []
            return
        }
        let prefix = String(text.dropFirst())
        Task {
            let matches = await skillRegistry?.skillsMatching(prefix: prefix) ?? []
            // The text moved on while the lookup ran, or the popover was dismissed
            // under it: either way its answer is not to be drawn.
            guard localText.hasPrefix("/" + prefix), !localText.contains(" "),
                  !Self.isPopoverStillDismissed(token: localText, dismissedOn: dismissedSlashToken) else { return }
            slashMatches = SlashCommandPopover.drawnSkills(
                from: SlashCommandPopover.mergedMatches(prefix: prefix, skills: matches, runtime: runtime))
            slashSelectedIndex = 0
        }
    }

    // MARK: - Mention Detection

    private func updateMentionMatches(for text: String) {
        guard let atIndex = text.lastIndex(of: "@"), !mentionPopoverStaysDismissed(for: String(text[atIndex...])) else {
            mentionMatches = []
            return
        }
        if atIndex != text.startIndex {
            let before = text[text.index(before: atIndex)]
            if before.isLetter || before.isNumber {
                mentionMatches = []
                return
            }
        }
        let afterAt = String(text[text.index(after: atIndex)...])
        guard !afterAt.contains(" ") else {
            mentionMatches = []
            return
        }

        let lower = afterAt.lowercased()
        var results: [MentionCandidate] = []
        var seenHandles: Set<String> = []

        // Active project agents — match on name handle or group
        for agent in projectAgents {
            let handle = agent.name.lowercased().replacingOccurrences(of: " ", with: "-")
            let matchesHandle = handle.hasPrefix(lower)
            let matchesGroup = agent.group?.lowercased().hasPrefix(lower) ?? false
            if matchesHandle || matchesGroup {
                let entry = MentionCandidate(
                    handle: handle,
                    description: (agent.group.map { "[\($0)] " } ?? "") + String(agent.systemPrompt.prefix(60))
                )
                results.append(entry)
                seenHandles.insert(handle)
            }
        }

        // Task specialists from catalog (skip duplicates already matched from project agents)
        let catalogMatches = agentCatalogStore?.search(prefix: afterAt) ?? []
        for template in catalogMatches {
            let handle = agentCatalogStore?.templateHandle(for: template) ?? template.name.lowercased()
            guard !seenHandles.contains(handle) else { continue }
            results.append(MentionCandidate(
                handle: handle,
                description: template.description
            ))
            seenHandles.insert(handle)
        }

        mentionMatches = Array(results.prefix(8))
        mentionSelectedIndex = 0
    }

    private func insertMention(_ handle: String) {
        if let atIndex = localText.lastIndex(of: "@") {
            localText = String(localText[..<atIndex]) + "@\(handle) "
        }
    }
}

// MARK: - MentionPopover

/// One row of the @-mention popover: a project agent or a catalog template.
private struct MentionCandidate: Identifiable {
    var id: String { handle }
    let handle: String
    let description: String
}

private struct MentionPopover: View {
    let entries: [MentionCandidate]
    let selectedIndex: Int
    let onSelect: (MentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Button {
                    onSelect(entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.blue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(entry.handle)")
                                .font(.body.monospaced())
                            if !entry.description.isEmpty {
                                Text(entry.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == selectedIndex ? Color.accentColor.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 220)
        .padding(.vertical, 4)
    }
}
