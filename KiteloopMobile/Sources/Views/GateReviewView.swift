import SwiftUI

/// What clearing the gate merges: the item's What/Validation beside the
/// branch's diff, then the decision. The whole point of the human gate is
/// judgment — this screen is the thing to judge.
struct GateReviewView: View {
    let model: NowViewModel
    let client: ControlClient
    let gate: NowViewModel.Gate
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ItemDetailReply?
    @State private var diff: DiffReply?
    @State private var diffProblem: String?
    @State private var diffFailure: String?
    @State private var detailFailure: String?
    @State private var refusal: String?
    @State private var notMerged: String?
    @State private var askingReason = false
    @State private var rejectReason = ""

    var body: some View {
        List {
            Section {
                Text(gate.item.title ?? gate.item.id).font(.headline)
                LabeledContent("Project", value: gate.project)
                if let epic = gate.item.epic { LabeledContent("Epic", value: epic) }
            }
            if let detailFailure {
                Section {
                    Text("The item's What and Validation could not be loaded: " + detailFailure)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let what = detail?.what { Section("What") { Text(what).font(.callout) } }
            if let criteria = detail?.acceptanceCriteria, !criteria.isEmpty {
                Section("Validation") { ForEach(criteria, id: \.self) { Text("· " + $0).font(.callout) } }
            }
            if let notes = detail?.notes, !notes.isEmpty {
                Section("Notes — the reviewer's advisories land here") { Text(notes).font(.callout) }
            }
            if let stat = diff?.stat, !stat.isEmpty {
                Section("Changed files") {
                    Text(stat).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let preview = diff?.preview {
                Section(preview.header) {
                    DiffText(preview: preview)
                }
            } else if let problem = diffProblem {
                Section("Diff") { Text(problem).font(.caption).foregroundStyle(.orange) }
            } else if let diffFailure {
                Section("Diff could not be loaded") { Text(diffFailure).font(.caption).foregroundStyle(.orange) }
            }
            if let refusal {
                Section("The Mac did not take it") { Text(refusal).font(.callout).foregroundStyle(.red) }
            }
            Section {
                Button("Approve — merge this") { decide(approve: true) }
                .buttonStyle(.borderedProminent)
                Button("Reject — send it back", role: .destructive) { rejectReason = ""; askingReason = true }
            }
        }
        .navigationTitle(gate.item.id)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Approved — not merged", isPresented: Binding(get: { notMerged != nil }, set: { if !$0 { notMerged = nil } })) {
            Button("OK") { dismiss() }
        } message: {
            Text(notMerged ?? "")
        }
        .alert("Send it back?", isPresented: $askingReason) {
            TextField("Why (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) { decide(approve: false, reason: rejectReason) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next run reads this under \"Rejected last time\".")
        }
        .task {
            switch await model.detail(client, gate) {
            case .success(let reply): detail = reply
            case .failure(let failure): detailFailure = failure.reason
            }
            switch await model.diff(client, gate) {
            case .loaded(let reply): diff = reply
            case .noBranch: diffProblem = "No branch to diff — the item ran in the live tree, or its branch is already merged."
            case .failed(let reason): diffFailure = reason
            }
        }
    }

    /// Closes the screen only once the item has left the gate: a refusal stays
    /// here with the Mac's reason, and an approval that skipped the merge says
    /// why before it closes.
    private func decide(approve: Bool, reason: String? = nil) {
        Task {
            switch await model.approve(client, project: gate.project, item: gate.item.id, approve: approve, reason: reason) {
            case .resolved: dismiss()
            case .resolvedWithoutMerge(let note): refusal = nil; notMerged = note
            case .refused(let reason): refusal = reason
            }
        }
    }
}

/// The unified diff, colored the way every diff reader colors it. Line-by-line
/// Texts, already capped by the preview, inside one horizontal scroll so long
/// lines don't wrap into noise.
struct DiffText: View {
    let preview: DiffPreview

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("diff ") { return .secondary }
        return .primary
    }
}
