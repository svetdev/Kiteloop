import KiteloopCore
import SwiftUI

/// Project Settings › Autopilot: the nine things a person sets for this
/// project's autopilot — an autonomy dial, one budget, the worker and
/// reviewer, the verify map file, and the stall and
/// merge-verify timeouts — plus the stages autopilot may pick items up from,
/// which sat here before this item and stays here: nothing else in the app
/// writes `autopilotPickupStages`.
///
/// Everything else that used to live here — worktree isolation, review
/// rounds, the worktree setup
/// command, the base branch and opening a pull request —
/// stayed a setting a hand-edited
/// `.kiteloop/autopilot-config.json` or `PUT /v1/autopilot` can still reach;
/// it just is not a decision this page asks a person to hold in their head
/// any more.
///
/// Every control writes straight to the autopilot (or, for the verify map, the
/// project; for pickup stages, the backlog), which persists it the moment it
/// changes. `PUT /v1/autopilot` writes the same values, and the mirrors
/// follow it, so a value set over the API mid-session shows here without
/// reopening the page.
struct AutopilotRunSettingsForm: View {
    @Bindable var autopilot: BacklogAutopilot
    /// The agents offered as worker and reviewer. Team only: an aside is
    /// ephemeral, so the caller leaves it out.
    var agents: [Agent]
    /// The backlog whose flow holds the pickup stages.
    let backlog: BacklogViewModel
    /// Where the verify map file lives.
    let project: KiteloopProject

    // A text mirror of the one budget: only written back to the autopilot when
    // the field is committed (Return or focus leaving it), so a half-typed "1"
    // in "12.50" never becomes the live budget.
    @State private var budgetText: String = ""
    @FocusState private var budgetFocused: Bool
    @State private var workflow: BacklogWorkflowConfig = .default
    @State private var workflowSaveError: String?
    @State private var setupCommandText: String = ""
    @FocusState private var setupCommandFocused: Bool
    @State private var showResetConfirmation = false
    @State private var loaded = false

    var body: some View {
        Form {
            autonomySection
            teamSection
            budgetSection
            projectSection
            pickupSection
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: autopilot.worktreeSetupCommand) { _, newValue in
            guard !setupCommandFocused else { return }
            setupCommandText = newValue ?? ""
        }
        .onChange(of: setupCommandFocused) { wasFocused, _ in
            if wasFocused { commitSetupCommand() }
        }
        .accessibilityIdentifier("project-settings-autopilot-page")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        budgetText = BacklogAutopilot.formatCostCapUSD(autopilot.budgetUSD)
        setupCommandText = autopilot.worktreeSetupCommand ?? ""
        workflow = backlog.workflow
    }

    // MARK: - Autonomy

    /// How far this project may go on its own — one dial over
    /// `autonomousWorkEnabled` and `approvalGate`.
    private var autonomySection: some View {
        Section {
            Picker("Autonomy", selection: $autopilot.autonomy) {
                Text("Off").tag(BacklogAutopilot.Autonomy.off)
                Text("Propose").tag(BacklogAutopilot.Autonomy.propose)
                Text("Land").tag(BacklogAutopilot.Autonomy.land)
            }
            .accessibilityIdentifier("project-settings-autopilot-autonomy-picker")
            .help("Off: the fleet never picks this project up unattended — running an item by hand still works. Propose: unattended runs start, and a review-passed item parks at the approval gate for you. Land: a review-passed item is approved without asking and merged, the same as pressing approve yourself.")
            if let note = Self.handStartedRunsNote(autonomousWorkEnabled: autopilot.autonomousWorkEnabled,
                                                   approvalGate: autopilot.approvalGate) {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("project-settings-autopilot-hand-started-runs-note")
            }
            Text("A worker and a reviewer make the project startable; the dial is what lets the fleet start it while nobody is watching. An unattended run's worker and reviewer use Claude Code's auto mode, whose classifier decides each tool call; the project's permission mode governs chat agents.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Autonomy")
        }
    }

    /// The one pair the dial cannot show: unattended runs off with the gate at
    /// `land` reads as Off, yet a run started by hand still lands itself. nil
    /// for every other pair.
    nonisolated static func handStartedRunsNote(autonomousWorkEnabled: Bool,
                                                approvalGate: BacklogAutopilot.ApprovalGate) -> String? {
        guard !autonomousWorkEnabled, approvalGate == .land else { return nil }
        return "Unattended runs are off, but a run started by hand is still approved without a person and merged once its review passes."
    }

    // MARK: - Team

    private var teamSection: some View {
        Section {
            rolePicker("Worker", emptyChoice: "Choose…", selection: workerSelection)
                .accessibilityIdentifier("project-settings-autopilot-worker-picker")
                .help("The agent that implements each item. Required to run.")
            rolePicker("Reviewer", emptyChoice: Self.noReviewerChoice, selection: reviewerSelection)
                .accessibilityIdentifier("project-settings-autopilot-reviewer-picker")
                .help("The agent that checks the worker's diff against the item. Optional: with no separate reviewer, the worker checks its own diff and the gates decide.")
        } header: {
            Text("Team")
        }
    }

    private var workerSelection: Binding<String> {
        Binding(get: { autopilot.workerAgentID ?? "" },
                set: { autopilot.workerAgentID = $0.isEmpty ? nil : $0 })
    }

    private var reviewerSelection: Binding<String> {
        Binding(get: { autopilot.reviewerAgentID ?? "" },
                set: { autopilot.reviewerAgentID = Self.reviewerAgentID(forSelection: $0) })
    }

    /// The reviewer picker's empty choice. Not an unset slot but a setting:
    /// a run with no reviewer goes from the worker straight to the gates.
    nonisolated static let noReviewerChoice = "No separate reviewer"

    /// What the reviewer picker stores for a selection: its empty tag — the
    /// "No separate reviewer" choice — stores no reviewer.
    nonisolated static func reviewerAgentID(forSelection selection: String) -> String? {
        selection.isEmpty ? nil : selection
    }

    private func rolePicker(_ title: String, emptyChoice: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(emptyChoice).tag("")
            ForEach(agents) { agent in
                Text(agent.name).tag(agent.id)
            }
        }
    }

    // MARK: - Budget

    /// The project's one budget — a daily ceiling that also bounds a sitting;
    /// nil defers entirely to the fleet's own ceiling, set on the portfolio
    /// surface (`PUT /v1/coordinator/scheduling`). The per-item ceiling is no
    /// longer a setting: it is the ledger's own prediction for the item's
    /// size, once there is enough evidence for one — see
    /// `CostGovernor.effectiveItemCap(for:)`.
    private var budgetSection: some View {
        Section {
            portfolioCeilingRow
            HStack(spacing: 4) {
                Text("Budget")
                Spacer()
                Text("$").foregroundStyle(.tertiary)
                TextField("none", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($budgetFocused)
                    .onSubmit(commitBudget)
                    .accessibilityIdentifier("project-settings-autopilot-budget-field")
            }
            .help("Most this project may spend in one local day, and the hard stop that pauses autopilot for the rest of a sitting. Empty = no ceiling of its own, and the portfolio-wide ceiling above governs it alone; that ceiling always applies on top of this one, so a bigger number here never buys more than the portfolio has left.")
        } header: {
            Text("Budget")
        }
        .onChange(of: autopilot.budgetUSD) { _, newValue in
            guard !budgetFocused else { return }
            budgetText = BacklogAutopilot.formatCostCapUSD(newValue)
        }
        .onChange(of: budgetFocused) { wasFocused, _ in
            if wasFocused { commitBudget() }
        }
    }

    private var portfolioCeilingRow: some View {
        LabeledContent("Portfolio daily ceiling") {
            Text(autopilot.portfolioDailyBudgetUSD.map { String(format: "$%.2f", $0) } ?? "none")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityIdentifier("project-settings-autopilot-portfolio-ceiling")
        .help("Shared by every project and by grooming, one day's ledger. Set it on the portfolio surface; the budget below is bounded by it.")
    }

    /// Writes a finished edit through to the autopilot (which persists it) and
    /// re-renders the field from the value that actually took effect, so junk
    /// or a cleared field visibly resolves to "no ceiling" instead of sitting
    /// there looking like a budget.
    private func commitBudget() {
        let value = BacklogAutopilot.parseCostCapUSD(budgetText)
        autopilot.budgetUSD = value
        budgetText = BacklogAutopilot.formatCostCapUSD(value)
    }

    // MARK: - Project

    /// The command this project runs in a fresh worktree, and a pointer to the
    /// verify map file — edited by hand, and what the merge gate runs.
    private var projectSection: some View {
        Section {
            setupCommandControl
            verifyMapRow
        } header: {
            Text("Project")
        }
    }

    /// The command run in every worktree Kiteloop creates for this project —
    /// the worker's, the merge gate's scratch tree, the rebase scratch tree —
    /// right after checkout and before anything else runs there. Empty =
    /// nothing extra runs.
    private var setupCommandControl: some View {
        TextField("Worktree setup command", text: $setupCommandText,
                  prompt: Text("npm ci, xcodegen generate, …"))
            .font(.body.monospaced())
            .focused($setupCommandFocused)
            .onSubmit { commitSetupCommand() }
            .accessibilityIdentifier("autopilot-worktree-setup-command-field")
            .help("Run once in every worktree Kiteloop creates for this project — the worker's, the merge gate's scratch tree, the rebase scratch tree — right after it is checked out and before anything else runs there: whatever a cold tree needs before its own verify: can run (npm ci, xcodegen generate, …). Empty = nothing extra runs. A non-zero exit or a timeout refuses the merge or blocks the item, naming the command and its output; never retried. A config reset clears this.")
    }

    /// Take the typed command as the project's worktree setup step. Trimmed;
    /// blank stores nil.
    private func commitSetupCommand() {
        let trimmed = setupCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        if autopilot.worktreeSetupCommand != value { autopilot.worktreeSetupCommand = value }
        setupCommandText = trimmed
    }

    /// The per-project map from a changed path to the `verify:` command it
    /// requires — a hand-edited file, so this page points at it rather than
    /// rendering an editor for it.
    private var verifyMapRow: some View {
        LabeledContent("Verify map") {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Text(project.verifyMapURL.lastPathComponent)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.verifyMapURL])
                }
                .accessibilityIdentifier("project-settings-autopilot-verify-map-reveal")
            }
        }
        .help("\(project.verifyMapURL.path(percentEncoded: false)) — which verify: command a changed path requires. Edited by hand; there is no form for it here.")
    }

    // MARK: - Pickup

    /// Which stages autopilot may start items from. The list of candidates is
    /// the config's own, so a toggle here and a hand-edited file are held to
    /// the same rule. Predates this item and stays here — nothing else in the
    /// app writes `autopilotPickupStages`.
    private var pickupSection: some View {
        Section {
            ForEach(workflow.pickableStages, id: \.self) { stage in
                Toggle(stage.displayName, isOn: pickupBinding(stage))
                    .accessibilityIdentifier("project-settings-autopilot-pickup-\(stage.rawValue)")
            }
            Text("Stages left off are never started automatically — you can still run them by hand from the item's Run button.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let workflowSaveError {
                Label(workflowSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            resetConfigControl
        } header: {
            Text("Autopilot may pick up items in")
        }
    }

    private func pickupBinding(_ stage: BacklogItemStatus) -> Binding<Bool> {
        Binding(
            get: { workflow.autopilotPickupStages.contains(stage) },
            set: { isOn in
                var updated = workflow
                if isOn {
                    if !updated.autopilotPickupStages.contains(stage) {
                        updated.autopilotPickupStages.append(stage)
                    }
                } else {
                    updated.autopilotPickupStages.removeAll { $0 == stage }
                }
                saveWorkflow(updated)
            }
        )
    }

    private func saveWorkflow(_ updated: BacklogWorkflowConfig) {
        do {
            try backlog.updateWorkflow(updated)
            workflowSaveError = nil
        } catch {
            workflowSaveError = BacklogFlowSettingsView.saveErrorMessage(for: error)
        }
        // Whether or not the write landed, the switches show what the view
        // model now holds — sanitized, and what the next handoff reads.
        workflow = backlog.workflow
    }

    // MARK: - Reset

    /// Puts every knob this page no longer shows — and the budget it does —
    /// back to its built-in default: the way out of a session where the
    /// settings were tuned and nobody can tell any more what was changed. The
    /// UI half of `POST /v1/autopilot/reset`, and it keeps that endpoint's
    /// guards: the worker/reviewer picks survive, and a run in flight blocks
    /// the reset (its budget is being enforced).
    private var resetConfigControl: some View {
        HStack {
            Spacer()
            Button("Reset to defaults") { showResetConfirmation = true }
                .disabled(!autopilot.canResetConfigToDefaults)
                .accessibilityIdentifier("autopilot-reset-config-button")
                .help(autopilot.canResetConfigToDefaults
                      ? "Put this project's autopilot settings back to their built-in defaults, including the budget above. The worker and reviewer picks are kept."
                      : "Nothing to reset, or a run is in flight — stop it first: the budget is being enforced against the item in flight.")
        }
        .confirmationDialog("Reset autopilot settings to defaults?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { resetConfigToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the budget and puts the dial, worktree isolation and every advanced setting back to their built-in values. The portfolio-wide daily ceiling is not touched. The worker and reviewer picks are kept.")
        }
    }

    /// Resets, then re-renders the budget field from what actually took
    /// effect — the mirror's `onChange` sync skips a focused field, and the
    /// field the user was last in can still hold focus when the button fires.
    private func resetConfigToDefaults() {
        autopilot.resetConfigToDefaults()
        budgetText = BacklogAutopilot.formatCostCapUSD(autopilot.budgetUSD)
    }
}
