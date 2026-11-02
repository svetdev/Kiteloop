import KiteloopCore
import SwiftUI

struct MCPAuthorizationCard: View {
    let request: Message.MCPAuthRequest
    /// Whether the agent is still waiting on this card's request. False for a
    /// card still marked pending whose request is gone — it says so rather than
    /// drawing fields and buttons that answer nothing.
    let isAnswerable: Bool
    let onAuthorize: ([String: String]) -> Void
    let onDeny: () -> Void

    @State private var envValues: [String: String] = [:]

    /// The key fields and the Authorize and Deny buttons are drawn only for a
    /// request the agent is still waiting on.
    var showsAnswerControls: Bool { request.status == .pending && isAnswerable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(.purple)
                Text(request.serverName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)
                Text("requests access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(request.description)
                .font(.callout)
                .foregroundStyle(.primary)

            if !request.reason.isEmpty {
                Text("Reason: \(request.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsAnswerControls {
                if !request.authKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(request.authKeys, id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 160, alignment: .leading)
                                if isSecretKey(key) {
                                    SecureField("required", text: binding(for: key))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                } else {
                                    TextField("required", text: binding(for: key))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        onAuthorize(envValues)
                    } label: {
                        Label("Authorize", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .disabled(!allKeysProvided)

                    Button {
                        onDeny()
                    } label: {
                        Label("Deny", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            } else if request.status == .pending {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                    Text("This request is no longer waiting for an answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    if request.status == .authorized {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Authorized — restarting session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Denied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.purple.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .onAppear {
            // `request.envValues` is always empty now — nothing writes it, so
            // that a typed key never reaches the saved chat history. The field
            // stays on the model so histories written before that still decode,
            // and this read stays so one of them still seeds its fields.
            for key in request.authKeys {
                envValues[key] = request.envValues[key] ?? ""
            }
        }
    }

    private var allKeysProvided: Bool {
        request.authKeys.allSatisfy { key in
            !(envValues[key] ?? "").isEmpty
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { envValues[key] ?? "" },
            set: { envValues[key] = $0 }
        )
    }

    private func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("key") || lower.contains("token")
            || lower.contains("secret") || lower.contains("password")
    }
}
