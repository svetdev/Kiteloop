import KiteloopCore
import SwiftUI

/// One agent's pane in the Autopilot console, rendered in the terminal's
/// activity idiom: `Verb(target)` headlines with a dimmed result beneath, shell
/// bursts folded into a single expandable row, and the agent's prose left as the
/// largest, widest thing in the pane. The rules behind the rows are in
/// `AutopilotTranscript`.
///
/// What it renders is a window, not the whole stream, and that is load-bearing: a
/// transcript grows for the length of a run, every row costs an alignment and
/// sizing pass, and two of these panes render at once (worker + reviewer). Left
/// unbounded it pegged the main thread at 100% mid-run — the same
/// explicitAlignment/sizeThatFits profile as the span trace above it, a different
/// list. `AutopilotTranscript.defaultRowLimit` is the cap.
struct AutopilotTranscriptView: View {
    let messages: [Message]
    /// False when the pane has no agent assigned, which is a different empty
    /// state from an agent that simply hasn't said anything yet.
    let hasAgent: Bool

    /// The height of the pane's window onto the rows, which the distance from
    /// the bottom is measured against.
    @State private var viewportHeight: CGFloat = 0
    /// How far the bottom of the row stack sits below the bottom of that
    /// window, as of the last time the pane was scrolled.
    @State private var distanceFromBottom: CGFloat = 0
    /// What the stack's offset above the window was then, which is how a scroll
    /// is told from rows arriving.
    @State private var lastScrollOffset: CGFloat = 0
    /// How many rows the pane draws. Only an explicit "Show N earlier" raises it,
    /// and a new run's stream puts it back to the cap.
    @State private var rowLimit = AutopilotTranscript.defaultRowLimit

    /// The pane's own frame, which the row stack's position is read against.
    private static let scrollSpace = "autopilot-transcript-scroll"

    /// Whether a row arriving scrolls the pane. The same judgement the chat
    /// makes of its bubble list, with no find bar to hold the view on a match:
    /// the stream is followed only for a reader already at the bottom of it, so
    /// scrolling up to read what the worker just did stays there for the run.
    static func streamScrollAction(distanceFromBottom: CGFloat) -> ChatView.StreamScrollAction {
        ChatView.streamScrollAction(
            distanceFromBottom: distanceFromBottom,
            isSearching: false,
            hasMatches: false
        )
    }

    var body: some View {
        let transcript = AutopilotTranscript.make(from: messages, limit: rowLimit)
        Group {
            if transcript.rows.isEmpty {
                emptyState
            } else {
                stream(transcript)
            }
        }
        // A different first message is a different run's stream replacing this one.
        .onChange(of: messages.first?.id) { _, _ in
            rowLimit = AutopilotTranscript.defaultRowLimit
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: hasAgent ? "ellipsis.bubble" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(.quaternary)
            Text(hasAgent ? "Waiting for activity..." : "No agent selected")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func stream(_ transcript: AutopilotTranscript.Transcript) -> some View {
        // Scrolling follows the total row count rather than the visible one: the
        // window is capped, so a visible count stops rising the moment the cap is
        // reached and the pane would stop following the run from there on.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let page = AutopilotTranscript.earlierPage(
                        limit: rowLimit, hiddenRowCount: transcript.hiddenRowCount) {
                        earlierButton(page, topRow: transcript.rows.first?.id, proxy: proxy)
                    }
                    ForEach(transcript.rows) { row in
                        rowView(row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(rowStackProbe)
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .background(viewportProbe)
            .onChange(of: transcript.totalRowCount) { _, _ in
                guard Self.streamScrollAction(distanceFromBottom: distanceFromBottom) == .follow,
                      let last = transcript.rows.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// Raises the window by one page and holds the row that was on top where it
    /// was, so the rows revealed above it don't push the reader's place away.
    private func earlierButton(
        _ page: (nextLimit: Int, revealed: Int),
        topRow: String?,
        proxy: ScrollViewProxy
    ) -> some View {
        Button("Show \(page.revealed) earlier") {
            rowLimit = page.nextLimit
            guard let topRow else { return }
            DispatchQueue.main.async { proxy.scrollTo(topRow, anchor: .top) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10))
        .padding(.vertical, 2)
    }

    /// Where the row stack sits in the pane's window onto it, reported on every
    /// change so the pane knows whether its reader is still at the bottom.
    private var rowStackProbe: some View {
        GeometryReader { stack in
            let frame = stack.frame(in: .named(Self.scrollSpace))
            Color.clear.onChange(of: PaneScroll(
                offset: -frame.minY,
                distanceFromBottom: frame.maxY - viewportHeight
            )) { _, scroll in
                record(scroll)
            }
        }
    }

    /// The height of the window itself, which the stack's `maxY` is measured
    /// against.
    private var viewportProbe: some View {
        GeometryReader { viewport in
            Color.clear.onChange(of: viewport.size.height, initial: true) { _, height in
                viewportHeight = height
            }
        }
    }

    /// Only a scroll of the pane itself moves the recorded distance: a row
    /// arriving pushes the bottom of the transcript further below the window
    /// without the reader having moved, and that must not read as their having
    /// scrolled away from the run. The chat's judgement, `ChatView.recordedDistance`.
    private func record(_ scroll: PaneScroll) {
        let distance = ChatView.recordedDistance(
            offset: scroll.offset, distanceFromBottom: scroll.distanceFromBottom,
            lastOffset: lastScrollOffset, recorded: distanceFromBottom)
        if scroll.offset != lastScrollOffset { lastScrollOffset = scroll.offset }
        if distance != distanceFromBottom { distanceFromBottom = distance }
    }

    @ViewBuilder
    private func rowView(_ row: AutopilotTranscript.Row) -> some View {
        switch row.kind {
        case .prose(let message):
            ProseRow(message: message)
        case .call(let call):
            ActivityRow(call: call)
        case .shell(let calls):
            ShellBurstRow(calls: calls)
        }
    }
}

/// How far the pane's row stack has been scrolled, and how far below the
/// bottom of the window onto it the transcript ends.
private struct PaneScroll: Equatable {
    var offset: CGFloat
    var distanceFromBottom: CGFloat
}

// MARK: - Prose

/// The part of the pane a human actually reads, so it keeps the transcript's
/// full-size body text and gives up the bubble it used to sit in — the pane is
/// already headed by the agent's name, and a boxed, indented paragraph in a
/// column this narrow is mostly margin.
private struct ProseRow: View {
    let message: Message

    var body: some View {
        switch message.content {
        case .text(let text):
            switch message.sender {
            case .agent:
                SelectableMarkdownView(markdown: text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            case .human:
                labelled("You", color: .blue) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .system:
                labelled("System", color: .orange) {
                    Text(text)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

        case .error(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .textSelection(.enabled)

        case .systemEvent(let event):
            SystemEventDivider(event: event)

        case .image(let data):
            ImageContentView(data: data)

        case .approval(let request):
            labelled("Approval", color: .orange) {
                Text(request.action)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    /// A one-word caption over anything that isn't the agent talking, so an
    /// injected prompt or a system note can't be mistaken for the agent's own
    /// prose now that the bubbles are gone.
    private func labelled(
        _ label: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Activity

/// `⏺ Read(AutopilotView.swift)` over `⎿ Read 1651 lines`. Clicking the
/// headline of a call that has returned unfolds everything it returned beneath
/// the line, and clicking again folds it.
private struct ActivityRow: View {
    let call: AutopilotTranscript.Call
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActivityHeadline(verb: call.verb, target: call.target)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard call.output != nil else { return }
                    withAnimation(KiteloopTokens.Anim.expand) { isExpanded.toggle() }
                }
            if let result = call.result {
                ActivityResult(text: result, isError: call.isError)
            }
            if isExpanded, let output = call.output {
                ActivityOutput(text: output, isError: call.isError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A call's whole output, unfolded under its result line: selectable so an error
/// can be copied out, red when the call failed, and capped so a build log can't
/// stall the pane.
private struct ActivityOutput: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(AutopilotTranscript.cappedOutput(text))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(isError ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 22)
            .padding(.vertical, 2)
    }
}

private struct ActivityHeadline: View {
    let verb: String
    let target: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("⏺")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
            (Text(verb).fontWeight(.semibold) + Text(target.isEmpty ? "" : "(\(target))"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// The dimmed half of a row. Indented under the headline it belongs to and, like
/// the terminal's, never more than one line: the pane is a pulse, not a log.
private struct ActivityResult: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("⎿")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isError ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }
}

/// A run of consecutive shell calls as one row. A worker checking out a branch,
/// running a build and reading its status is three lines of intent and thirty of
/// output; collapsed it is one row that says whether any of it failed, and
/// expands to the individual commands when it did.
private struct ShellBurstRow: View {
    let calls: [AutopilotTranscript.Call]
    @State private var isExpanded = false

    private var failed: Bool { calls.contains(where: \.isError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("⏺")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                Text(AutopilotTranscript.shellHeadline(calls))
                    .font(.system(size: 11, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(KiteloopTokens.Anim.expand) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(calls) { call in
                        ActivityRow(call: call)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 2)
            } else {
                ActivityResult(text: AutopilotTranscript.shellSummary(calls), isError: failed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
