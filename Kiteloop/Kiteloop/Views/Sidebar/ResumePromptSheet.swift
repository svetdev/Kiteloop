import SwiftUI

struct ResumePromptSheet: View {
    let executions: [IncompleteExecution]
    /// Outcome of the last Resume or Dismiss press, if any — shown so a press
    /// that did nothing is never mistaken for one that worked.
    let report: Orchestrator.ResumeReport?
    let onResume: (String) -> Void
    let onDismiss: (String) -> Void
    let onDismissAll: () -> Void

    /// What a Dismiss press is asking to forget, held until the question is answered.
    private enum DismissTarget {
        case one(IncompleteExecution)
        case all
    }

    @State private var pendingDismiss: DismissTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("Interrupted Runs")
                    .font(.headline)
                Spacer()
                Button("Dismiss All") {
                    pendingDismiss = .all
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text("These runs stopped part-way through and can be continued from their last checkpoint.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let report {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.succeeded ? Color.green : Color.orange)
                    Text(report.message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(executions) { execution in
                        ResumeExecutionRow(
                            execution: execution,
                            onResume: { onResume(execution.id) },
                            onDismiss: { pendingDismiss = .one(execution) }
                        )
                    }
                }
            }
            .frame(maxHeight: 320)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(20)
        .frame(minWidth: 460)
        .confirmationDialog(
            dismissTitle,
            isPresented: Binding(
                get: { pendingDismiss != nil },
                set: { if !$0 { pendingDismiss = nil } }
            )
        ) {
            Button("Dismiss", role: .destructive) { confirmDismiss() }
            Button("Cancel", role: .cancel) { pendingDismiss = nil }
        } message: {
            Text(dismissMessage)
        }
    }

    private var dismissTitle: String {
        if case .all = pendingDismiss { return "Dismiss all interrupted runs?" }
        return "Dismiss this run?"
    }

    private var dismissMessage: String {
        switch pendingDismiss {
        case .one(let execution): return Self.dismissRunMessage(displayName: execution.displayName)
        case .all: return Self.dismissAllMessage(count: executions.count)
        case nil: return ""
        }
    }

    private func confirmDismiss() {
        guard let target = pendingDismiss else { return }
        pendingDismiss = nil
        switch target {
        case .one(let execution): onDismiss(execution.id)
        case .all: onDismissAll()
        }
    }

    /// What a row's Dismiss does, said before it does it: the run, named by
    /// the title its row shows, loses its checkpoints for good.
    static func dismissRunMessage(displayName: String) -> String {
        "Forgets “\(displayName)” and deletes its checkpoints. The run can no longer be resumed."
    }

    /// What Dismiss All does, said before it does it: how many runs are
    /// forgotten, and that none of them can be resumed afterwards.
    static func dismissAllMessage(count: Int) -> String {
        let runs = count == 1 ? "1 interrupted run" : "\(count) interrupted runs"
        return "Forgets \(runs) and deletes their checkpoints. The runs can no longer be resumed."
    }
}

private struct ResumeExecutionRow: View {
    let execution: IncompleteExecution
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(execution.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(execution.completedStepCount == 0 ? Color.orange : Color.secondary)
            }

            Spacer()

            Button("Resume") { onResume() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Continue this run from its last checkpoint.")

            Button("Dismiss") { onDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Forget this run and delete its checkpoints.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Which item, in which project, stopped when. Every autopilot run shares
    /// one graph, so without these three a row says nothing that distinguishes
    /// it from the row above.
    private var subtitle: String {
        var parts: [String] = []
        // The id is redundant next to a title that is already the id.
        if let itemID = execution.itemID, !itemID.isEmpty, itemID != execution.displayName {
            parts.append(itemID)
        }
        parts.append(execution.projectName)
        parts.append("interrupted \(Self.interruptedFormatter.localizedString(for: execution.interruptedAt, relativeTo: Date()))")
        return parts.joined(separator: " · ")
    }

    /// A run that finished nothing has no partial work to preserve, so it is
    /// worth saying so — restarting it from the top loses nothing.
    private var progress: String {
        switch execution.completedStepCount {
        case 0: return "Stopped at \(execution.currentNode) — produced nothing yet"
        case 1: return "Stopped at \(execution.currentNode) — 1 step completed"
        case let count: return "Stopped at \(execution.currentNode) — \(count) steps completed"
        }
    }

    private static let interruptedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
