import KiteloopCore
import SwiftUI

/// Project Settings → Backlog Flow. Lets a team shape the stage machine:
/// which optional stages exist, where new items land, and — the important one —
/// whether a human must approve work before it counts as Done. Which stages
/// autopilot may pick up is the Autopilot page's, beside its other switches
/// (`AutopilotRunSettingsForm`), and writes the same flow.
///
/// Every read and write goes through the open project's ``BacklogViewModel``
/// rather than a store of its own. That is the whole point: the file used to be
/// the only thing a save touched, so the running project — and the autopilot
/// asking it `stageAfterAgentReview` at every handoff — kept the flow it had
/// loaded at launch, and an approval gate switched back on did nothing until the
/// project was closed and reopened.
struct BacklogFlowSettingsView: View {
    let backlog: BacklogViewModel

    @State private var config: BacklogWorkflowConfig = .default
    @State private var loaded = false
    @State private var saveError: String?

    /// What the tab shows when a save could not be written.
    static func saveErrorMessage(for error: Error) -> String {
        "Couldn't save backlog flow: \(error.localizedDescription)"
    }

    var body: some View {
        Form {
            Section("Flow") {
                stagePipeline

                Toggle("Draft stage", isOn: binding(\.useDraftStage))
                Text("New items start as Draft and must be groomed (What / How / Validation) before an agent can pick them up.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("Review stage", isOn: binding(\.useReviewStage))
                Text("Shows the reviewer agent's QA pass as its own stage.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("Require human approval before Done", isOn: binding(\.requireHumanApproval))
                Text(config.requireHumanApproval
                     ? "Work that passes agent review parks at Awaiting Approval until you accept or send it back. Agents can never mark an item Done."
                     : "⚠️ A passing agent review sends the item straight to Done. The agent grades its own work.")
                    .font(.caption)
                    .foregroundStyle(config.requireHumanApproval ? Color.secondary.opacity(0.7) : Color.orange)
            }

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            config = backlog.workflow
            loaded = true
        }
    }

    /// The stage machine, drawn left to right so the flow is legible at a glance.
    private var stagePipeline: some View {
        HStack(spacing: 4) {
            ForEach(Array(config.activeStages.enumerated()), id: \.element) { index, stage in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Text(stage.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(color(for: stage).opacity(0.15))
                    )
                    .foregroundStyle(color(for: stage))
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for stage: BacklogItemStatus) -> Color {
        switch stage {
        case .draft: return .gray
        case .ready: return .secondary
        case .active: return .blue
        case .inReview: return .purple
        case .awaitingApproval: return .blue
        case .done: return .green
        case .blocked: return .red
        }
    }

    private func binding(_ keyPath: WritableKeyPath<BacklogWorkflowConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                var updated = config
                updated[keyPath: keyPath] = newValue
                save(updated)
            }
        )
    }

    private func save(_ updated: BacklogWorkflowConfig) {
        do {
            try backlog.updateWorkflow(updated)
            saveError = nil
        } catch {
            saveError = Self.saveErrorMessage(for: error)
        }
        // Whether or not the write landed, the controls show what the view model
        // now holds — sanitized, and the same value the next autopilot handoff
        // reads.
        config = backlog.workflow
    }
}
