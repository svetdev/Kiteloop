import KiteloopCore
import SwiftUI

/// The one list of what only a person can clear, across every open project —
/// items at the approval gate and agents holding an unanswered question.
///
/// **Why it is a drawer.** The same list exists on the start screen, as the
/// "needs you" strip `PortfolioView` draws, and that screen is up only when no
/// project is open — which is to say, never while anyone is working. The
/// placement had to be one that survives a tab being open, and the sidebar
/// footer already collects the surfaces whose scope is the whole portfolio
/// rather than the project in front of you: the Planner, the fleet, the day's
/// ceiling. So this is the third of those — a footer box that states the count
/// in a line, opening a resizable pane with the room to name every row. It is
/// deliberately not a fourth section of the fleet drawer: that pane is about
/// what the machines are doing on their own, and this one is the list of what
/// they cannot do without you.
///
/// The rows navigate and nothing more — approving from here, or answering from
/// here, would be a second place those things happen and a second thing to keep
/// in step with the run. Selecting a row lands on the surface that already owns
/// the decision: the project's Autopilot panel, where Approve and Reject live,
/// or the agent's chat, where the answer is typed.
struct WaitingOnYouDrawer: View {
    /// What was read at the last refresh. Every line here is a field of it —
    /// see `WaitingOnYou` — so the footer box and this pane cannot come to
    /// disagree about what is waiting.
    let waiting: WaitingOnYou
    /// Go to where the row is cleared. The window does the going; this pane
    /// only says which gate was picked.
    let onOpen: (WaitingOnYou.Row) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if waiting.isEmpty {
                empty
            } else {
                list
            }
            Spacer(minLength: 0)
        }
        .background(.background)
        .accessibilityIdentifier("waiting-drawer")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: "hand.raised")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Waiting on you")
                .font(.system(.caption, weight: .semibold))
            AutonomyScopeLabel(text: AutonomyScopeLabel.allProjects)
            AutonomyLoopStatePill(text: waiting.summary,
                                  tint: waiting.isEmpty ? .gray : .orange)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Close Waiting on you")
            .accessibilityIdentifier("waiting-drawer-close")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xs)
        .background(.ultraThinMaterial)
    }

    /// Said plainly, because "nothing is waiting" is the answer this pane is
    /// opened for as often as any other, and a blank pane does not give it.
    private var empty: some View {
        Text("Nothing is waiting on you. An item that reaches the approval gate, "
             + "or an agent that asks you a question, turns up here.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(KiteloopTokens.Spacing.lg)
            .accessibilityIdentifier("waiting-drawer-empty")
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                ForEach(waiting.rows) { row in
                    WaitingRow(row: row) { onOpen(row) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(KiteloopTokens.Spacing.md)
        }
    }
}

/// One gate: what it is, where it is, how long it has been there — and the
/// click that goes to it.
///
/// The whole row is the target rather than the id inside it. Elsewhere an item
/// mention is an `ItemLink` to the item's page, but the page is not where an
/// approval is granted; a row here has exactly one destination and putting a
/// second, differently-destined link inside it would make the two compete.
private struct WaitingRow: View {
    let row: WaitingOnYou.Row
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: KiteloopTokens.Spacing.md) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: KiteloopTokens.Spacing.md) {
                        Text(row.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: KiteloopTokens.Spacing.md)
                        // How long it has been sitting there. Absent rather
                        // than guessed where the gate has outlived its notice —
                        // those rows are at the top of the list, which is the
                        // same fact said by position.
                        if let since = row.since {
                            Text(since, format: .relative(presentation: .numeric))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(row.subtitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                .fill(Color.accentColor.opacity(isHovering ? KiteloopTokens.Opacity.medium : 0))
        )
        .onHover { isHovering = $0 }
        .hoverCursor()
        .help(help)
        .accessibilityIdentifier("waiting-row-\(row.id)")
    }

    /// The inbox's glyphs and colours for the same two kinds, so a gate looks
    /// the same wherever it is read.
    private var icon: String {
        switch row.gate {
        case .approval: "hand.raised"
        case .question: "questionmark.circle"
        case .stale: "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch row.gate {
        case .approval: .orange
        case .question: .blue
        case .stale: .yellow
        }
    }

    /// Name the destination, since the row is a link whose target is not the
    /// thing it names — an approval opens the panel it is granted on, not the
    /// item's own page.
    private var help: String {
        switch row.gate {
        case .approval(let itemID):
            "Open \(row.projectName)'s Autopilot panel, where \(itemID) is approved or rejected"
        case .question(let agentID):
            "Open \(row.agentName ?? agentID)'s chat in \(row.projectName) to answer"
        case .stale(let itemID):
            "Open \(itemID)'s page in \(row.projectName) — nothing has touched it in a while"
        }
    }
}
