import KiteloopCore
import SwiftUI

/// A configuration change an agent asked for over the control API, waiting on
/// a person: who asked, which call, what it would change — secrets left out —
/// and the Approve and Decline buttons (`ConfigChangeGate`).
///
/// The waiting drawer's row opens it. Nothing applies until Approve; a change
/// whose caller has hung up says so and only clears.
struct HeldConfigChangeCard: View {
    let change: HeldConfigChange
    /// Answers the change and says what became of it.
    let answer: (Bool) -> HeldConfigChanges.Answer
    let onClose: () -> Void

    /// Why an approval was refused — the log line could not be written.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(change.route)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Text(change.project.map { "Project: \($0.name)" } ?? "Applies to \(WaitingOnYou.wholeApp) as a whole")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(change.summary.isEmpty ? "The call carries no parameters." : change.summary)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            if let failure {
                Label("Not applied — the decision could not be logged: \(failure)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            footer
        }
        .padding(16)
        .frame(width: 460)
        .accessibilityIdentifier("held-config-change-card")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2")
                .foregroundStyle(.orange)
            Text(change.caller)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text("asks to change configuration")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(change.askedAt, format: .relative(presentation: .numeric))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if failure != nil {
            HStack { Spacer(); Button("Close", action: onClose) }
        } else if change.callerGone {
            HStack {
                Text("The caller is no longer waiting. Nothing will be applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { decide(false) }
            }
        } else {
            HStack(spacing: 12) {
                Button { decide(true) } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("held-config-change-approve")
                Button { decide(false) } label: {
                    Label("Decline", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("held-config-change-decline")
                Spacer()
                Button("Later", action: onClose)
            }
        }
    }

    private func decide(_ approve: Bool) {
        if case .unrecorded(let reason) = answer(approve) {
            failure = reason
        } else {
            onClose()
        }
    }
}

/// Puts a held change's card up as a sheet when its request id is set — by a
/// row of the waiting drawer, the menu bar or a banner.
struct HeldConfigChangeSheet: ViewModifier {
    let controlServer: KiteloopControlServer
    @Binding var requestID: String?
    /// The card's own copy of the change, so the sheet still has something to
    /// draw while it closes — the change leaves the list as it is answered.
    @State private var onCard: HeldConfigChange?

    func body(content: Content) -> some View {
        content
            .sheet(item: $onCard) { change in
                HeldConfigChangeCard(
                    change: controlServer.configChanges.waiting.first { $0.id == change.id } ?? change,
                    answer: { controlServer.answerConfigChange(change.id, approve: $0) },
                    onClose: { onCard = nil })
            }
            .onChange(of: requestID) { _, asked in
                guard let asked else { return }
                onCard = controlServer.configChanges.waiting.first { $0.id == asked }
                requestID = nil
            }
    }
}
