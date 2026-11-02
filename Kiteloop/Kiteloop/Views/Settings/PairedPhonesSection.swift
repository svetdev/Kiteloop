import KiteloopCore
import SwiftUI

/// Settings → Control API → Paired phones: every phone that holds a token of
/// its own, and Revoke, which stops that phone and no other. The control token
/// scripts use is not listed and keeps working.
struct PairedPhonesSection: View {
    let controlServer: KiteloopControlServer
    @State private var phones: [ControlDevice] = []
    @State private var revoking: ControlDevice?

    var body: some View {
        Section("Paired phones") {
            if phones.isEmpty {
                Text("No phone has paired yet. Pair a phone above; each gets a token of its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(phones) { phone in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.name)
                        Text(Self.detail(phone)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke…", role: .destructive) { revoking = phone }
                        .accessibilityIdentifier("settings-revoke-phone-\(phone.id.uuidString)")
                }
            }
        }
        .onAppear { phones = controlServer.pairedPhones }
        .confirmationDialog("Revoke \(revoking?.name ?? "this phone")?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) {
                if let phone = revoking { controlServer.revokePhone(phone.id) }
                phones = controlServer.pairedPhones
                revoking = nil
            }
        } message: {
            Text("Its next request is refused. Other phones and the control token keep working.")
        }
    }

    static func detail(_ phone: ControlDevice) -> String {
        let paired = "Paired \(phone.pairedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let used = phone.lastUsedAt else { return paired }
        return "\(paired) · last used \(used.formatted(.relative(presentation: .named)))"
    }
}
