import KiteloopCore
import SwiftUI

/// A team change an agent asked for through `hire_agent` or `fire_agent`,
/// waiting on a person: who asked, the roster before and after, and the
/// Approve and Deny buttons (`GlobalConfig.agentChangesNeedingApproval`).
struct ConfigChangeCard: View {
    let request: Message.ApprovalRequest
    /// The agent that asked for the change.
    let requestedBy: String
    /// Whether the agent is still waiting on this card. False for a card still
    /// marked pending whose request is gone — it says so rather than drawing
    /// buttons that answer nothing.
    let isAnswerable: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(request.action)
                .font(.callout)
            roster("Team now", request.before)
            roster("Team after", request.after)
            footer
        }
        .padding(12)
        .background(.orange.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.badge.gearshape")
                .foregroundStyle(.orange)
            Text(requestedBy)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text("asks to change the team")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func roster(_ label: String, _ names: String?) -> some View {
        Text("\(label): \(names.flatMap { $0.isEmpty ? nil : $0 } ?? "nobody")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var footer: some View {
        switch request.status {
        case .pending where isAnswerable:
            HStack(spacing: 12) {
                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                Button(action: onDeny) {
                    Label("Deny", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        case .pending, .abandoned:
            status("clock.badge.xmark", .secondary, "This request is no longer waiting for an answer.")
        case .approved:
            status("checkmark.circle.fill", .green, "Approved")
        case .denied:
            status("xmark.circle.fill", .red, "Denied")
        }
    }

    private func status(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
