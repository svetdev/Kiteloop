import KiteloopCore
import SwiftUI

/// The console "Activity" tab: a live, reverse-chronological feed of workflow /
/// autopilot / agent events flowing through the project's EventBus.
struct ActivityFeedView: View {
    @Bindable var viewModel: ActivityFeedViewModel

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if viewModel.filteredEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.filteredEvents) { event in
                            ActivityRow(event: event, source: viewModel.sourceLabel(for: event))
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .task { await viewModel.run() }
    }

    private var controlBar: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Menu {
                Button("All events") { viewModel.typeFilter = nil }
                if !viewModel.presentTypes.isEmpty {
                    Divider()
                    ForEach(viewModel.presentTypes, id: \.self) { type in
                        Button(type.label) { viewModel.typeFilter = type }
                    }
                }
            } label: {
                Label(viewModel.typeFilter?.label ?? "All events", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Text("\(viewModel.filteredEvents.count)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                viewModel.clear()
            } label: {
                Image(systemName: "trash").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Clear the feed")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xs)
    }

    @ViewBuilder
    private var emptyState: some View {
        let search = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            PanelEmptyState(
                icon: "magnifyingglass",
                title: "No matching events",
                message: "Nothing in this feed matches “\(search)”. Clear the search to see everything."
            )
        } else if let filter = viewModel.typeFilter {
            PanelEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching events",
                message: "Nothing in this feed is a “\(filter.label)” event. Pick “All events” to see everything."
            )
        } else {
            PanelEmptyState(
                icon: "dot.radiowaves.left.and.right",
                title: "No activity yet",
                message: "Workflow and autopilot events appear here. Run a backlog item to start one."
            )
        }
    }
}

private struct ActivityRow: View {
    let event: KiteloopEvent
    let source: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ActivityFeedViewModel.timeLabel(
                for: event.timestamp, now: Date(), calendar: .current, locale: .current
            ))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()

            Text(event.type.label)
                .font(.system(.caption2, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(event.type.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(event.type.tint)
                .fixedSize()

            Text(source)
                .font(.system(.caption, weight: .medium))
                .lineLimit(1)
                .fixedSize()

            if let summary = event.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(event.type.summaryLineLimit)
                    .truncationMode(event.type.summaryLineLimit > 1 ? .tail : .middle)
                    .help(summary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }
}

// MARK: - Event presentation

extension KiteloopEvent.EventType {
    /// Human-readable label ("workflow_transitioned" → "Workflow Transitioned").
    var label: String {
        rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var tint: Color {
        switch self {
        case .error, .workflowFailed:
            return .red
        case .workflowApprovalRequired, .workflowResumeOffered:
            return .orange
        case .workflowCompleted, .taskComplete, .reviewComplete, .testComplete,
             .prReady, .engineeringComplete, .opsComplete, .prdComplete,
             .wireframeComplete, .researchComplete, .dataComplete:
            return .green
        case .workflowStarted, .workflowTransitioned, .workflowResumed, .workflowApprovalResolved:
            return .blue
        case .memoryProposed, .knowledgeRecalled, .agentCardGenerated, .agentDiscovered:
            return .purple
        default:
            return .secondary
        }
    }

    /// How many lines a row's summary may wrap over: a failure, an error or a
    /// gate's question is the text worth reading whole, so it gets four.
    var summaryLineLimit: Int {
        switch self {
        case .error, .workflowFailed, .workflowApprovalRequired:
            return 4
        default:
            return 1
        }
    }
}

extension KiteloopEvent {
    /// A one-line human summary drawn from the most meaningful payload keys.
    var summary: String? {
        switch type {
        case .workflowTransitioned:
            if let from = payload["from"], let to = payload["to"] { return "\(from) → \(to)" }
        case .workflowStarted, .workflowCompleted:
            if let graph = payload["graphID"] { return graph }
        case .workflowFailed:
            if let reason = payload["reason"] { return reason }
        case .workflowApprovalRequired:
            if let q = payload["question"] { return q }
        case .workflowApprovalResolved:
            let verdict = payload["approved"] == "true" ? "approved" : "rejected"
            if let reason = payload["reason"] { return "\(verdict) — \(reason)" }
            return verdict
        default:
            break
        }
        // Generic fallback: compact key: value pairs, skipping noisy IDs.
        let skip: Set<String> = ["executionID", "nodeID"]
        let parts = payload
            .filter { !skip.contains($0.key) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .prefix(3)
            .map { "\($0.key): \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
