import KiteloopCore
import SwiftUI
import AppKit

/// The in-app web preview pane: a locked-down WebKit view for observing rendered
/// output (local dev servers / files by default; real sites behind a gate), with
/// a one-way "send screenshot to the current agent" action. Shown inline beside
/// the chat, or popped out into its own resizable window.
struct WebPreviewPanel: View {
    @Bindable var viewModel: WebPreviewViewModel
    /// When set, shows a "pop out" button that detaches the pane into a window.
    /// nil in the detached window itself.
    var onPopOut: (() -> Void)? = nil

    @State private var headText: String?
    @State private var isFinding = false
    @State private var findText = ""
    @State private var isShowingConsole = false
    @State private var consoleThreshold = WebPreviewViewModel.ConsoleThreshold.all
    /// The height of the Console list's window onto its lines.
    @State private var consoleViewportHeight: CGFloat = 0
    /// How far the last Console line sits below that window, as of the last
    /// time the list was scrolled.
    @State private var consoleDistanceFromBottom: CGFloat = 0
    /// The line stack's offset above the window then, which tells a scroll
    /// from lines arriving.
    @State private var consoleLastScrollOffset: CGFloat = 0
    @FocusState private var isFindFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let message = viewModel.blockedMessage {
                banner(message, systemImage: "hand.raised.fill", tint: .orange,
                       identifier: "web-preview-blocked-banner") {
                    if viewModel.refusedURL != nil, viewModel.mode == .trusted {
                        Button("Load in External") { viewModel.loadRefusedInExternal() }
                            .controlSize(.small)
                            .accessibilityIdentifier("web-preview-load-in-external")
                    }
                }
            }
            // Red against the refusal's orange: a page the gate turned away and
            // a page that broke are different news, and a blank pane with no
            // word at all was the third thing this replaces.
            if let failure = viewModel.loadFailure {
                banner(failure, systemImage: "exclamationmark.triangle.fill", tint: .red,
                       identifier: "web-preview-failure-banner")
            }
            if let pending = viewModel.pendingExternalURL {
                confirmGate(host: pending.host ?? pending.absoluteString)
            }
            WebView(webView: viewModel.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sheet(item: Binding(
                    get: { viewModel.pendingPageDialog },
                    set: { if $0 == nil { viewModel.answerPageDialog(.dismissed) } }
                )) { dialog in
                    WebPageDialogSheet(dialog: dialog) { viewModel.answerPageDialog($0) }
                }
            Divider()
            if isFinding {
                findRow
                Divider()
            }
            actionRow
        }
        .background(.background)
        .sheet(isPresented: Binding(get: { headText != nil }, set: { if !$0 { headText = nil } })) {
            headSheet(headText ?? "")
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Button { viewModel.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!viewModel.canGoBack)
            Button { viewModel.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!viewModel.canGoForward)
            if viewModel.isLoading {
                Button { viewModel.stopLoading() } label: { Image(systemName: "xmark") }
                    .help("Stop loading this page")
            } else {
                Button { viewModel.reload() } label: { Image(systemName: "arrow.clockwise") }
            }

            TextField(placeholder, text: $viewModel.urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { viewModel.load(viewModel.urlText, source: .user) }
                .accessibilityIdentifier("web-preview-url-field")

            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }

            zoomControls

            Picker("", selection: Binding(
                get: { viewModel.mode },
                set: { viewModel.setMode($0) }
            )) {
                Text("Trusted").tag(WebPreviewMode.trusted)
                Text("External").tag(WebPreviewMode.external)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Trusted: local content only. External: real sites (agent loads are gated).")
            .accessibilityIdentifier("web-preview-mode-picker")

            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open in a separate window")
                .accessibilityIdentifier("web-preview-pop-out")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
    }

    /// Cmd-0 is not the reset here: MainWindow binds it to the Navigator.
    private var zoomControls: some View {
        HStack(spacing: KiteloopTokens.Spacing.xs) {
            Button { viewModel.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!viewModel.canZoomOut)
                .help("Zoom out")
                .accessibilityIdentifier("web-preview-zoom-out")
            Button { viewModel.resetZoom() } label: {
                Text("\(viewModel.zoomPercent)%")
                    .font(.system(.caption, design: .monospaced))
            }
            .help("Reset zoom to 100%")
            .accessibilityIdentifier("web-preview-zoom-reset")
            Button { viewModel.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!viewModel.canZoomIn)
                .help("Zoom in")
                .accessibilityIdentifier("web-preview-zoom-in")
        }
    }

    private var placeholder: String {
        viewModel.mode == .trusted ? "http://localhost:3000  or  /path/to/file.html" : "example.com"
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Button {
                Task { await viewModel.sendScreenshotToAgent() }
            } label: {
                Label(viewModel.currentAgentName.map { "Send screenshot to \($0)" } ?? "Send screenshot", systemImage: "camera.viewfinder")
            }
            .disabled(viewModel.currentAgentName == nil || viewModel.currentURL == nil)
            .help(viewModel.currentAgentName == nil ? "Select an agent to send a screenshot to" : "Attach a screenshot of this page to the agent's next message")
            .accessibilityIdentifier("web-preview-send-screenshot")

            Button {
                Task { await viewModel.copyScreenshot() }
            } label: {
                Label("Copy Screenshot", systemImage: "doc.on.clipboard")
            }
            .disabled(viewModel.currentURL == nil)
            .help("Copy a PNG of this page to the clipboard")
            .accessibilityIdentifier("web-preview-copy-screenshot")

            Button {
                Task {
                    let outcome: Result<String, Error>
                    do { outcome = .success(try await viewModel.readHead()) } catch { outcome = .failure(error) }
                    headText = Self.headSheetText(outcome, pageURL: viewModel.currentURL)
                }
            } label: {
                Label("Inspect head", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(viewModel.currentURL == nil)
            .help("Read the page's <head> (meta / Open Graph / JSON-LD)")

            Button { viewModel.openInBrowser() } label: {
                Label("Open in Browser", systemImage: "arrow.up.right.square")
            }
            .disabled(!viewModel.canOpenInBrowser)
            .help("Open this page in your default browser")
            .accessibilityIdentifier("web-preview-open-in-browser")

            Button { toggleFind() } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .disabled(viewModel.currentURL == nil)
            .help("Find text on this page")
            .accessibilityIdentifier("web-preview-find")

            consoleButton

            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
    }

    // MARK: - Console

    private var consoleButton: some View {
        Button { isShowingConsole = true } label: {
            Label(Self.consoleButtonTitle(errorCount: viewModel.consoleErrorCount), systemImage: "terminal")
        }
        .disabled(viewModel.currentURL == nil)
        .help("Show what this page wrote to its console, and its uncaught errors")
        .accessibilityIdentifier("web-preview-console")
        .sheet(isPresented: $isShowingConsole) { consoleSheet }
    }

    /// "Console", with the page's error count beside it once it has logged any.
    static func consoleButtonTitle(errorCount: Int) -> String {
        errorCount > 0 ? "Console (\(errorCount))" : "Console"
    }

    /// The line drawn above the Console list once earlier lines were dropped
    /// — the same one Copy All starts with — or nil when none were.
    static func consoleDroppedTitle(droppedCount: Int) -> String? {
        WebPreviewViewModel.consoleDroppedLine(count: droppedCount)
    }

    /// A line the Console list draws above the page's own lines, in grey.
    struct ConsoleNotice: Identifiable, Equatable {
        let id: String
        let text: String
    }

    /// What the Console list says above its lines: that the page logged nothing,
    /// or nothing at the chosen level, and that earlier lines were dropped.
    static func consoleNotices(entries: [WebConsoleEntry], shown: [WebConsoleEntry],
                               droppedCount: Int) -> [ConsoleNotice] {
        var notices: [ConsoleNotice] = []
        if entries.isEmpty {
            notices.append(ConsoleNotice(id: "web-preview-console-empty",
                                         text: "This page has written nothing to its console."))
        } else if shown.isEmpty {
            notices.append(ConsoleNotice(id: "web-preview-console-empty",
                                         text: "Nothing at this level was logged."))
        }
        if let dropped = consoleDroppedTitle(droppedCount: droppedCount) {
            notices.append(ConsoleNotice(id: "web-preview-console-dropped", text: dropped))
        }
        return notices
    }

    /// Whether a line the page logs scrolls the open Console. The chat's
    /// judgement with no find bar: follow only a reader already at the bottom,
    /// so one who scrolled up to read an earlier line stays there.
    static func consoleScrollAction(distanceFromBottom: CGFloat) -> ChatView.StreamScrollAction {
        ChatView.streamScrollAction(
            distanceFromBottom: distanceFromBottom,
            isSearching: false,
            hasMatches: false
        )
    }

    /// What the open Console follows on: the newest line's id, nil when the
    /// list is empty. Not the count — once the list holds its 200, each new
    /// line pushes one off the front and the count stays put.
    static func consoleFollowKey(for entries: [WebConsoleEntry]) -> UUID? {
        entries.last?.id
    }

    private var consoleSheet: some View {
        let shown = WebPreviewViewModel.consoleEntries(viewModel.consoleEntries, at: consoleThreshold)
        return VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Picker("Level", selection: $consoleThreshold) {
                    ForEach(WebPreviewViewModel.ConsoleThreshold.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("web-preview-console-level")
                Button("Clear") { viewModel.clearConsole() }
                    .accessibilityIdentifier("web-preview-console-clear")
                Button("Copy All") { viewModel.copyConsole(threshold: consoleThreshold) }
                    .disabled(shown.isEmpty)
                    .accessibilityIdentifier("web-preview-console-copy")
                Button("Done") { isShowingConsole = false }.keyboardShortcut(.defaultAction)
            }
            consoleList(shown)
        }
        .padding()
        .frame(width: 560, height: 480)
    }

    /// Opens on the newest line and lands on it again when the level changes.
    /// A line arriving follows it only for a reader at the bottom.
    private func consoleList(_ shown: [WebConsoleEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                    ForEach(Self.consoleNotices(entries: viewModel.consoleEntries, shown: shown,
                                                droppedCount: viewModel.consoleDroppedCount)) { notice in
                        Text(notice.text).foregroundStyle(.secondary).accessibilityIdentifier(notice.id)
                    }
                    ForEach(shown) { consoleLine($0).id($0.id) }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(consoleStackProbe)
            }
            .coordinateSpace(.named(Self.consoleScrollSpace))
            .background(consoleViewportProbe)
            .accessibilityIdentifier("web-preview-console-list")
            .onAppear { scrollToNewest(of: shown, with: proxy) }
            .onChange(of: consoleThreshold) { _, threshold in
                scrollToNewest(of: WebPreviewViewModel.consoleEntries(viewModel.consoleEntries, at: threshold), with: proxy)
            }
            .onChange(of: Self.consoleFollowKey(for: viewModel.consoleEntries)) { _, _ in
                guard Self.consoleScrollAction(distanceFromBottom: consoleDistanceFromBottom) == .follow else { return }
                scrollToNewest(of: shown, with: proxy)
            }
        }
    }

    private func scrollToNewest(of shown: [WebConsoleEntry], with proxy: ScrollViewProxy) {
        guard let last = shown.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    /// The Console list's own frame, which the line stack is read against.
    private static let consoleScrollSpace = "web-preview-console-scroll"

    /// Where the line stack sits in the list's window, reported on every change
    /// so the list knows whether its reader is still at the bottom.
    private var consoleStackProbe: some View {
        GeometryReader { stack in
            Color.clear.onChange(of: stack.frame(in: .named(Self.consoleScrollSpace))) { _, frame in
                recordConsoleScroll(offset: -frame.minY, distanceFromBottom: frame.maxY - consoleViewportHeight)
            }
        }
    }

    private var consoleViewportProbe: some View {
        GeometryReader { viewport in
            Color.clear.onChange(of: viewport.size.height, initial: true) { _, height in
                consoleViewportHeight = height
            }
        }
    }

    /// Only a scroll of the list moves the recorded distance: a line arriving
    /// pushes the bottom further down without the reader having moved.
    private func recordConsoleScroll(offset: CGFloat, distanceFromBottom: CGFloat) {
        let distance = ChatView.recordedDistance(
            offset: offset, distanceFromBottom: distanceFromBottom,
            lastOffset: consoleLastScrollOffset, recorded: consoleDistanceFromBottom)
        if offset != consoleLastScrollOffset { consoleLastScrollOffset = offset }
        if distance != consoleDistanceFromBottom { consoleDistanceFromBottom = distance }
    }

    private func consoleLine(_ entry: WebConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.sm) {
            Text(entry.time.formatted(.dateTime.hour().minute().second())).foregroundStyle(.secondary)
            Text(entry.level.rawValue)
            Text(entry.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Self.consoleColor(for: entry.level))
    }

    private static func consoleColor(for level: WebConsoleEntry.Level) -> Color {
        switch level {
        case .error: Color.red
        case .warn: Color.orange
        default: Color.primary
        }
    }

    // MARK: - Find row

    /// Cmd-F is not bound here: the chat beside the pane owns it for its find bar.
    private var findRow: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            TextField("Find on page", text: $findText)
                .textFieldStyle(.roundedBorder)
                .focused($isFindFieldFocused)
                .onSubmit { respond(to: .returnKey) }
                .onChange(of: findText) { _, _ in
                    Task { await viewModel.find("") }
                }
                .onExitCommand { respond(to: .escape) }
                .accessibilityIdentifier("web-preview-find-field")
            Button { search(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match")
                .accessibilityIdentifier("web-preview-find-previous")
            Button { search(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next match")
                .accessibilityIdentifier("web-preview-find-next")
            if viewModel.findNotFound {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("web-preview-find-not-found")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .background {
            // Present only while the field has focus, so Shift-Return typed
            // into the chat input beside the pane is never caught here.
            if isFindFieldFocused {
                Button("") { respond(to: .shiftReturn) }
                    .keyboardShortcut(.return, modifiers: .shift)
                    .hidden()
            }
        }
        .onAppear { isFindFieldFocused = true }
    }

    /// The keys the find field answers to while the row is open.
    enum FindKey {
        case returnKey
        case shiftReturn
        case escape
    }

    enum FindKeyAction: Equatable {
        case next
        case previous
        case close
    }

    static func findKeyAction(for key: FindKey) -> FindKeyAction {
        switch key {
        case .returnKey: return .next
        case .shiftReturn: return .previous
        case .escape: return .close
        }
    }

    private func respond(to key: FindKey) {
        switch Self.findKeyAction(for: key) {
        case .next: search(backwards: false)
        case .previous: search(backwards: true)
        case .close: toggleFind()
        }
    }

    private func search(backwards: Bool) {
        Task { await viewModel.find(findText, backwards: backwards) }
    }

    /// Closing the row also clears "Not found", so it does not greet the next open.
    private func toggleFind() {
        isFinding.toggle()
        if !isFinding { Task { await viewModel.find("") } }
    }

    /// What the Inspect head sheet shows: the markup, a sentence for a head
    /// that really is empty, or — for a read that failed — which page could not
    /// be read and why.
    static func headSheetText(_ outcome: Result<String, Error>, pageURL: URL?) -> String {
        let page = pageURL?.absoluteString ?? "this page"
        switch outcome {
        case .success(let markup) where markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "The <head> of \(page) is empty — it holds no meta, Open Graph or JSON-LD tags."
        case .success(let markup):
            return markup
        case .failure(let error):
            return "Could not read the <head> of \(page): \(error.localizedDescription)"
        }
    }

    // MARK: - Gate + banners

    private func confirmGate(host: String) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("Load external site “\(host)”?")
                .font(.callout)
            Spacer()
            Button("Cancel") { viewModel.cancelPendingExternal() }
                .controlSize(.small)
            Button("Load") { viewModel.confirmPendingExternal() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
        .background(Color.orange.opacity(KiteloopTokens.Opacity.light))
    }

    private func banner(
        _ text: String, systemImage: String, tint: Color, identifier: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
            Spacer()
            action()
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xs)
        .background(tint.opacity(KiteloopTokens.Opacity.light))
    }

    private func headSheet(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            HStack {
                Text("Page <head>").font(.headline)
                Spacer()
                Button("Done") { headText = nil }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
    }
}

/// A page's `alert`, `confirm` or `prompt`: OK alone for an alert, OK and
/// Cancel for a confirm, and a text field above them for a prompt.
private struct WebPageDialogSheet: View {
    let dialog: WebPageDialog
    let answer: (WebPageDialogReply) -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text(dialog.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("web-preview-page-dialog-message")
            if dialog.kind == .prompt {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { answer(.ok(text: text)) }
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button("Cancel") { answer(.dismissed) }.keyboardShortcut(.cancelAction)
                }
                Button("OK") { answer(.ok(text: dialog.kind == .prompt ? text : nil)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear { text = dialog.defaultText ?? "" }
    }
}

/// A detached Web Preview window the manager is holding: bring it forward, or
/// tear it down. `AppKitWebPreviewWindowPresenter` builds the real one; a test
/// installs its own so it can drive the manager without an `NSWindow`.
@MainActor
protocol WebPreviewDetachedWindowHosting: AnyObject {
    func focus()
    func close()
}

/// Builds the detached window. The seam exists so `WebPreviewWindowManager` can
/// be exercised without AppKit; the default is the construction the app uses.
@MainActor
protocol WebPreviewWindowPresenting {
    /// Shows a window hosting the panel. `onClose` runs when that window goes
    /// away for any reason, the human closing it included.
    func present(viewModel: WebPreviewViewModel,
                 onClose: @escaping @MainActor () -> Void) -> WebPreviewDetachedWindowHosting
}

/// The shipping presenter: an `NSHostingController` on `WebPreviewPanel` in a
/// plain resizable window.
@MainActor
struct AppKitWebPreviewWindowPresenter: WebPreviewWindowPresenting {
    func present(viewModel: WebPreviewViewModel,
                 onClose: @escaping @MainActor () -> Void) -> WebPreviewDetachedWindowHosting {
        let hosting = NSHostingController(rootView: WebPreviewPanel(viewModel: viewModel))
        let win = NSWindow(contentViewController: hosting)
        followWindowTitle(of: viewModel, in: win)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        Self.place(win, frameAutosaveName: "WebPreviewWindow")
        win.makeKeyAndOrderFront(nil)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onClose() }
        }
        return AppKitDetachedWebPreviewWindow(window: win, observer: observer)
    }

    /// Autosaves the window's frame under `frameAutosaveName` and restores the
    /// frame last saved there; 900×700, centred, only when none has been saved.
    static func place(_ window: NSWindow, frameAutosaveName: String) {
        window.setFrameAutosaveName(frameAutosaveName)
        if window.setFrameUsingName(frameAutosaveName) { return }
        window.setContentSize(NSSize(width: 900, height: 700))
        window.center()
    }

    /// Sets the window's title from the view model and re-arms after each
    /// change. Both are held weakly, so a closed window is not kept alive.
    private func followWindowTitle(of viewModel: WebPreviewViewModel, in window: NSWindow) {
        let title = withObservationTracking {
            viewModel.windowTitle
        } onChange: { [weak viewModel, weak window] in
            Task { @MainActor in
                guard let viewModel, let window else { return }
                followWindowTitle(of: viewModel, in: window)
            }
        }
        window.title = title
    }
}

@MainActor
private final class AppKitDetachedWebPreviewWindow: WebPreviewDetachedWindowHosting {
    private let window: NSWindow
    /// Dropped before we close the window ourselves: the manager has already
    /// forgotten this window, so its `willClose` has nothing left to report.
    private var observer: NSObjectProtocol?

    init(window: NSWindow, observer: NSObjectProtocol) {
        self.window = window
        self.observer = observer
    }

    func focus() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        window.close()
    }
}

/// Owns the detached "Web Preview" window. Created on demand (never at launch)
/// and reused; hosts the same `WebPreviewViewModel` as the inline panel so state
/// and the screenshot action stay in sync.
///
/// One `WKWebView` renders the page, and a view has one superview, so only one
/// host can show it: whoever renders last steals it and the other goes blank.
/// `isDetached` says which host holds it, and `closeDetachedWindow()` hands it
/// back to the inline panel.
@MainActor
@Observable
final class WebPreviewWindowManager {
    /// True while the page is hosted in its own window rather than inline.
    private(set) var isDetached = false

    private let presenter: WebPreviewWindowPresenting
    private var window: WebPreviewDetachedWindowHosting?

    init(presenter: WebPreviewWindowPresenting = AppKitWebPreviewWindowPresenter()) {
        self.presenter = presenter
    }

    func show(viewModel: WebPreviewViewModel) {
        if let window {
            window.focus()
            return
        }
        window = presenter.present(viewModel: viewModel) { [weak self] in
            self?.window = nil
            self?.isDetached = false
        }
        isDetached = true
    }

    /// Gives the page back to the inline panel: tears the detached window down
    /// and forgets it. A no-op when nothing is detached.
    func closeDetachedWindow() {
        guard let window else { return }
        self.window = nil
        isDetached = false
        window.close()
    }
}
