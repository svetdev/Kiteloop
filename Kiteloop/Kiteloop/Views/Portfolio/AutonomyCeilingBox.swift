import SwiftUI

/// The day's autonomy ceiling, as its own row of the sidebar's status block — a
/// sibling of the Planner's and the fleet's, not a line inside either.
///
/// The placement is the argument. One number bounds **both** loops: grooming
/// draws from the same daily ledger unattended runs do, which is what "one
/// ceiling per scope" settled. Rendered inside the Planner's box it reads as the
/// Planner's setting, and rendered again as a field in the fleet's controls it
/// reads as a second, different number — which is exactly the reading it
/// produced. Beside them both it can only read as what it is: shared.
///
/// Two properties are load-bearing:
///
/// * **Nothing commits implicitly.** The ceiling is what arms the fleet, and the
///   inline field this replaces committed on blur — which cleared the portfolio
///   ceiling when focus merely passed through, and needed `syncedBudgetText` and
///   `CostGovernor.shouldCommitCapOnBlur` to guard against itself. A popover with
///   an explicit Save cannot fire on blur, on a pass-through, or before the field
///   has ever shown the stored value: the bug class goes rather than being
///   guarded.
/// * **It says what it bounds.** In words, in the editor, because "grooming and
///   unattended running share this" is the fact the old layout hid.
struct AutonomyCeilingBox: View {

    /// The portfolio ceiling and what the day has spent against it — the pair
    /// the box states and the editor writes back to.
    let budget: DailyBudget
    /// Writes the new ceiling. Nil clears it, which disarms both loops.
    let setBudgetUSD: (Double?) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        Button { beginEditing() } label: {
            SidebarStatusRowLabel(icon: "dollarsign.circle", name: "Daily budget", status: stateLine,
                                  tint: stateTint, statusID: "autonomy-ceiling-state")
        }
        .buttonStyle(.plain)
        .help("\(stateLine)\nThe one ceiling both loops answer to: grooming and unattended running spend against the same daily number. Neither arms without it. Click to change it.")
        .accessibilityIdentifier("autonomy-ceiling-box")
        .popover(isPresented: $editing, arrowEdge: .trailing) { editor }
    }

    /// What the box says when nobody is editing: the figure, or the reason there
    /// isn't one. An absent ceiling is not a blank — it is why the fleet will not
    /// arm, and saying so is the whole point of the box.
    private var stateLine: String {
        guard budget.budgetUSD != nil else { return "no ceiling — autonomy can't arm" }
        if budget.isExhausted { return "\(budget.text) — spent, holds until tomorrow" }
        return budget.text
    }

    private var stateTint: Color {
        guard budget.budgetUSD != nil else { return .orange }
        return budget.isExhausted ? .orange : .secondary
    }

    // MARK: - The editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Daily autonomy budget")
                .font(.headline)
            // The sentence the old layout could not say, because the number was
            // drawn in two places that each looked like they owned it.
            Text("One ceiling for the day, shared: grooming and unattended running spend against it together. Neither arms without one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)

            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Text("USD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("none", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(commit)
                    .accessibilityIdentifier("autonomy-ceiling-field")
            }

            Text(invalid
                 ? "A ceiling is a positive number, or empty for none."
                 : "Empty clears it — which stops unattended work until one is set again.")
                .font(.caption2)
                .foregroundStyle(invalid ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .accessibilityIdentifier("autonomy-ceiling-cancel")
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("autonomy-ceiling-save")
            }
        }
        .padding(KiteloopTokens.Spacing.lg)
        .frame(width: 300)
    }

    private func beginEditing() {
        draft = budget.budgetUSD.map { BacklogAutopilot.formatCostCapUSD($0) } ?? ""
        invalid = false
        editing = true
    }

    /// Save. The only path that writes — there is deliberately no commit on
    /// dismiss, so closing the popover any other way leaves the ceiling alone.
    private func commit() {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            setBudgetUSD(nil)
            editing = false
            return
        }
        guard let value = BacklogAutopilot.parseCostCapUSD(typed), value > 0 else {
            invalid = true
            return
        }
        setBudgetUSD(value)
        editing = false
    }
}
