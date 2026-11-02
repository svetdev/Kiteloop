import KiteloopCore
import SwiftUI

struct TraceDetailView: View {
    let session: TraceSession
    let spans: [TraceSpan]
    var agentName: (String) -> String = { $0 }
    var chatTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()

            Divider()

            if spans.isEmpty {
                PanelEmptyState(
                    icon: "list.bullet",
                    title: "No turns recorded",
                    message: "This session ended before any turn was measured, so there is nothing to break down."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(spans) { span in
                            SpanRow(span: span)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(agentName(session.agentID))
                    .font(.title2.bold())
                if let chatTitle {
                    Text(chatTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(Self.sessionLabel(for: session.id))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "$%.4f", session.totalCost))
                    .font(.title3.monospacedDigit())
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedDuration: String {
        DurationPhrase.phrase(session.duration)
    }

    /// The header's session line: the whole Claude CLI session id, so it can be
    /// copied into `claude --resume` or searched for in logs. A turn recorded
    /// without one carries "unknown", which says so rather than posing as an id.
    static func sessionLabel(for sessionID: String) -> String {
        guard !sessionID.isEmpty, sessionID != "unknown" else { return "No session id recorded" }
        return "Session: \(sessionID)"
    }

    /// What a turn consumed, as one caption: `10.0k in · 450 out · cache 88% ·
    /// claude-sonnet-5`. Nil for a span recorded before the counters existed —
    /// it says nothing rather than claiming zeros. The prompt figure is
    /// `promptTokens`, since `inputTokens` is only the uncached remainder.
    static func usageLine(for span: TraceSpan) -> String? {
        guard let usage = span.tokenUsage else { return nil }
        let tokens = "\(TokenUsage.compactCount(usage.promptTokens)) in · "
            + "\(TokenUsage.compactCount(usage.outputTokens)) out · cache \(usage.cacheHitRateText)"
        guard let model = span.model else { return tokens }
        return "\(tokens) · \(model)"
    }

    /// How long a turn, tool call or thinking span lasted: a minute or more on
    /// the header's scale ("4m 3s"), under a minute in fractional seconds, so a
    /// 0.3s tool call does not read "0s".
    static func spanDurationLabel(_ seconds: TimeInterval) -> String {
        guard seconds < 60 else { return DurationPhrase.phrase(seconds) }
        return String(format: "%.2fs", seconds)
    }

    /// When a turn started: the time alone for a turn from today, the date and
    /// time for one from an earlier calendar day — Traces lists every day file,
    /// so last week's turn sits beside this morning's.
    static func startTimeLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: isToday ? .omitted : .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return style.format(date)
    }
}

private struct SpanRow: View {
    let span: TraceSpan

    var body: some View {
        HStack(spacing: 12) {
            spanIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spanLabel)
                        .font(.system(.body, design: .monospaced))
                    if let tool = span.metadata["tool"] {
                        Text(tool)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    }
                }
                if let duration = span.duration {
                    Text(TraceDetailView.spanDurationLabel(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let usage = TraceDetailView.usageLine(for: span) {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // What this turn added, not the session's running total at the time
            // of it — `costUSD` is the latter, so a row reading it only ever
            // climbs. Formatted as the header's total is.
            if let cost = span.costDeltaUSD ?? span.reportedCostUSD {
                Text(String(format: "$%.4f", cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(TraceDetailView.startTimeLabel(for: span.startTime, now: Date(), calendar: .current, locale: .current))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(backgroundColor))
    }

    private var spanLabel: String {
        switch span.type {
        case .turn: return "Turn"
        case .toolCall: return "Tool"
        case .thinking: return "Think"
        }
    }

    @ViewBuilder
    private var spanIcon: some View {
        switch span.type {
        case .turn:
            Image(systemName: "message")
                .foregroundStyle(.blue)
        case .toolCall:
            Image(systemName: "wrench")
                .foregroundStyle(.orange)
        case .thinking:
            Image(systemName: "brain")
                .foregroundStyle(.purple)
        }
    }

    private var backgroundColor: Color {
        switch span.type {
        case .turn: return .blue.opacity(0.05)
        case .toolCall: return .orange.opacity(0.05)
        case .thinking: return .purple.opacity(0.05)
        }
    }
}
