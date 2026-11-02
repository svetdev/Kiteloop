import KiteloopCore
import SwiftUI

/// Settings → Control API → Push to phones: the APNs key the Mac
/// signs pushes with, and whether pushes can go out — the reason when they
/// cannot, the phones registered when they can.
struct PushKeySection: View {
    @Bindable var globalConfigStore: GlobalConfigStore
    @State private var keyPath = ""
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var problem: String?
    @State private var devices: [PushDevice] = []

    var body: some View {
        Section("Push to phones") {
            TextField("Key file (.p8)", text: $keyPath, prompt: Text("~/private_keys/AuthKey_XXXXXXXXXX.p8"))
                .accessibilityIdentifier("settings-push-key-path")
            TextField("Key ID", text: $keyID)
                .accessibilityIdentifier("settings-push-key-id")
            TextField("Team ID", text: $teamID)
                .accessibilityIdentifier("settings-push-team-id")
            HStack {
                Button("Save Key") { save() }
                    .accessibilityIdentifier("settings-push-key-save")
                Button("Remove Key", role: .destructive) { remove() }
                    .disabled(globalConfigStore.config.pushKey == nil)
                Spacer()
                status
            }
            if !devices.isEmpty {
                ForEach(devices, id: \.token) { device in
                    LabeledContent(device.name, value: device.environment == .production ? "TestFlight" : "Xcode build")
                }
            }
            Text("An APNs key from developer.apple.com → Certificates, Identifiers & Profiles → Keys, with Apple Push Notifications service enabled; the Team ID is your membership's. The Mac pushes straight to Apple when an item reaches the gate, an agent asks you something or has a plan ready, or a turn you started from the phone ends. Phones register themselves after pairing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .onAppear { load() }
    }

    @ViewBuilder
    private var status: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("settings-push-problem")
        } else {
            Label(devices.isEmpty ? "Ready — no phone registered yet" : "Ready — \(devices.count) phone\(devices.count == 1 ? "" : "s")",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private func load() {
        let key = globalConfigStore.config.pushKey
        keyPath = key?.keyPath ?? ""
        keyID = key?.keyID ?? ""
        teamID = key?.teamID ?? ""
        refresh()
    }

    private func save() {
        globalConfigStore.setPushKey(PushKeyConfig(
            keyPath: keyPath.trimmingCharacters(in: .whitespaces),
            keyID: keyID.trimmingCharacters(in: .whitespaces),
            teamID: teamID.trimmingCharacters(in: .whitespaces)))
        refresh()
    }

    private func remove() {
        globalConfigStore.setPushKey(nil)
        load()
    }

    private func refresh() {
        PushRelay.shared.keyChanged()
        problem = PushRelay.shared.problem
        Task { devices = await PushRelay.shared.devices?.all() ?? [] }
    }
}
