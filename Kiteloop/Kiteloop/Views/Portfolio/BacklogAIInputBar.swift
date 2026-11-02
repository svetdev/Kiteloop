import SwiftUI

/// Bottom-of-editor input that lets the user talk to a project's backlog in
/// natural language. Proposed changes are shown for confirmation before any are
/// written — nothing is applied silently.
struct BacklogAIInputBar: View {
    let editor: BacklogAIEditor
    @Bindable var viewModel: BacklogViewModel
    let projectPath: String

    @State private var instruction = ""

    var body: some View {
        VStack(spacing: 0) {
            switch editor.phase {
            case .review(let ops, let unreadable):
                reviewPanel(ops, unreadable: unreadable)
                Divider()
            case .error(let message):
                errorPanel(message)
                Divider()
            case .idle, .thinking:
                EmptyView()
            }

            inputRow
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            TextField(
                "Ask AI to add, remove, or reorganize the backlog…",
                text: $instruction,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .onSubmit(submit)
            .disabled(editor.isBusy)

            if editor.isBusy {
                // Stop rather than a bare spinner: a reply that never comes
                // would otherwise hold the bar until a relaunch. The typed
                // request stays in the field to reword and send again.
                Button {
                    editor.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Stop this request")
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.backlogFile == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    // MARK: - Review

    /// Removals red minus, additions green plus, and every other change — a
    /// rename, move or status — a neutral pencil, so it doesn't read as new work.
    @ViewBuilder
    private func opIcon(_ op: BacklogEditOp) -> some View {
        if op.isDestructive {
            Image(systemName: "minus.circle").foregroundStyle(.red)
        } else if op.isAddition {
            Image(systemName: "plus.circle").foregroundStyle(.green)
        } else {
            Image(systemName: "pencil.circle").foregroundStyle(.secondary)
        }
    }

    private func reviewPanel(_ ops: [BacklogEditOp], unreadable: [String]) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Proposed changes")
                .font(.system(.subheadline, weight: .semibold))
            ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                HStack(spacing: KiteloopTokens.Spacing.sm) {
                    opIcon(op)
                        .font(.caption)
                    Text(op.previewLine(in: viewModel.backlogFile))
                        .font(.callout)
                }
            }
            // What the list above is missing. Without it the operator approves a
            // shorter proposal than the one that was made, with nothing on
            // screen to say so.
            if !unreadable.isEmpty {
                unreadablePanel(unreadable)
            }
            HStack {
                Spacer()
                Button("Discard") { editor.reset() }
                    .controlSize(.small)
                Button("Apply \(ops.count) change\(ops.count == 1 ? "" : "s")") {
                    editor.apply(ops, to: viewModel)
                    // Kept when a change didn't land, so the request that
                    // produced it is still there to retry or reword.
                    if case .idle = editor.phase { instruction = "" }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unreadablePanel(_ unreadable: [String]) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("\(unreadable.count) proposed change\(unreadable.count == 1 ? "" : "s") couldn't be read and \(unreadable.count == 1 ? "is" : "are") not listed above")
                    .font(.callout)
            }
            ForEach(Array(unreadable.enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func errorPanel(_ message: String) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { editor.reset() }
                .controlSize(.small)
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
    }

    // MARK: - Actions

    private func submit() {
        guard let backlog = viewModel.backlogFile,
              !instruction.trimmingCharacters(in: .whitespaces).isEmpty,
              !editor.isBusy else { return }
        editor.submit(instruction: instruction, backlog: backlog, projectPath: projectPath)
    }
}
