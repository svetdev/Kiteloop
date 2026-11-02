import KiteloopCore
import SwiftUI

/// The learning engine's readout: how long tasks actually take by size and epic,
/// and how well past estimates matched reality. Read-only over `TaskMetricStore`.
struct TaskInsightsView: View {
    let store: TaskMetricStore
    let projectPath: String
    let projectName: String
    /// When embedded (e.g. in the Inspector drawer) the view fills its container
    /// and hides the modal "Done" button.
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var bySize: [(size: String, summary: TaskMetricSummary)] {
        store.summariesBySize(projectPath: projectPath)
    }
    private var byEpic: [(epic: String, summary: TaskMetricSummary)] {
        store.summariesByEpic(projectPath: projectPath)
    }
    private var calibration: [(estimate: TaskEstimate, actual: TaskMetricRecord)] {
        store.calibration(projectPath: projectPath)
    }
    /// The most recent runs that recorded token counters, newest first. Runs
    /// that recorded none are left out rather than shown as zero — an unmeasured
    /// run has nothing to say about the cache.
    private var recentUsage: [TaskMetricRecord] {
        store.records
            .filter { KiteloopProject.canonicalPath($0.projectPath) == KiteloopProject.canonicalPath(projectPath) }
            .filter { $0.tokenUsage != nil }
            .suffix(8)
            .reversed()
    }
    private var hasData: Bool { !bySize.isEmpty || !byEpic.isEmpty || !recentUsage.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if hasData {
                ScrollView {
                    VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
                        if !bySize.isEmpty { sizeSection }
                        if !byEpic.isEmpty { epicSection }
                        if !recentUsage.isEmpty { usageSection }
                        if !calibration.isEmpty { calibrationSection }
                    }
                    .padding(KiteloopTokens.Spacing.xl)
                }
            } else {
                emptyState
            }
        }
        .frame(width: embedded ? nil : 520, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Task Insights")
                    .font(.headline)
                Text(projectName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !embedded {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(KiteloopTokens.Spacing.xl)
    }

    // MARK: - By size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Average duration by size")
                .font(.system(.subheadline, weight: .semibold))
            let maxDuration = bySize.map(\.summary.avgDurationSeconds).max() ?? 1
            ForEach(bySize, id: \.size) { size, summary in
                statRow(
                    label: size,
                    labelColor: .blue,
                    value: minutes(summary.avgDurationSeconds),
                    detail: summary.insightsDetail,
                    fraction: summary.avgDurationSeconds / maxDuration
                )
            }
        }
    }

    // MARK: - By epic

    private var epicSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("By epic")
                .font(.system(.subheadline, weight: .semibold))
            let maxDuration = byEpic.map(\.summary.avgDurationSeconds).max() ?? 1
            ForEach(byEpic, id: \.epic) { epic, summary in
                statRow(
                    label: epic,
                    labelColor: .purple,
                    value: minutes(summary.avgDurationSeconds),
                    detail: summary.insightsDetail,
                    fraction: summary.avgDurationSeconds / maxDuration
                )
            }
        }
    }

    // MARK: - Token usage

    /// What recent runs consumed, and how much of it came from cache.
    ///
    /// The cache hit rate is the point of the section. Cache reads are billed at
    /// a tenth of the base input rate and are most of the prompt on a long run,
    /// so a run whose rate collapses is a cost regression — one that the dollar
    /// figure beside it shows only after the fact, and never explains.
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Tokens and cache")
                .font(.system(.subheadline, weight: .semibold))
            ForEach(recentUsage) { record in
                usageRow(record)
            }
        }
    }

    private func usageRow(_ record: TaskMetricRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text(record.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: KiteloopTokens.Spacing.md)
                if let usage = record.tokenUsage {
                    Text("\(TokenUsage.compactCount(usage.promptTokens)) in / \(TokenUsage.compactCount(usage.outputTokens)) out")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("cache \(record.tokenUsage?.cacheHitRateText ?? "not measured")")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(cacheColor(record.cacheHitRate))
            }
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text(record.model ?? "model not recorded")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: KiteloopTokens.Spacing.md)
                // Both figures, always. They are measuring the same run two
                // different ways, and a gap between them is worth seeing — a
                // model missing from the price table, or a rate that has moved.
                Text("reported $\(String(format: "%.2f", record.costUSD))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(derivedLabel(record))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func derivedLabel(_ record: TaskMetricRecord) -> String {
        guard let derived = record.derivedCostUSD else { return "derived —" }
        let version = record.priceVersion.map { " @ \($0)" } ?? ""
        return "derived $\(String(format: "%.2f", derived))\(version)"
    }

    /// Nothing measured stays neutral — grey is "we don't know", not "it's fine".
    private func cacheColor(_ rate: Double?) -> Color {
        guard let rate else { return .secondary }
        if rate >= 0.7 { return .green }
        if rate >= 0.3 { return .orange }
        return .red
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Estimate vs actual")
                .font(.system(.subheadline, weight: .semibold))
            ForEach(Array(calibration.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: KiteloopTokens.Spacing.md) {
                    Text(pair.actual.title)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: KiteloopTokens.Spacing.md)
                    Text("est \(minutes(pair.estimate.predictedDurationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Text("→")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("actual \(minutes(pair.actual.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(deltaLabel(estimate: pair.estimate.predictedDurationSeconds, actual: pair.actual.durationSeconds))
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(deltaColor(estimate: pair.estimate.predictedDurationSeconds, actual: pair.actual.durationSeconds))
                }
            }
        }
    }

    // MARK: - Building blocks

    private func statRow(label: String, labelColor: Color, value: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(labelColor)
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(KiteloopTokens.Opacity.light))
                    Capsule().fill(labelColor.opacity(0.5))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }

    private var emptyState: some View {
        PanelEmptyState(
            icon: "chart.bar",
            title: "No measured runs yet",
            message: "Duration, cost, and rework loops appear here once a backlog item finishes in Autopilot."
        )
    }

    private func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(1, m))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    private func deltaLabel(estimate: Double, actual: Double) -> String {
        guard estimate > 0 else { return "" }
        let ratio = actual / estimate
        if ratio > 1.15 { return "+\(Int((ratio - 1) * 100))%" }
        if ratio < 0.85 { return "-\(Int((1 - ratio) * 100))%" }
        return "on target"
    }

    private func deltaColor(estimate: Double, actual: Double) -> Color {
        guard estimate > 0 else { return .secondary }
        let ratio = actual / estimate
        if ratio > 1.15 || ratio < 0.85 { return .orange }
        return .green
    }
}
