import KiteloopCore
import SwiftUI

struct AgentConfigSheet: View {
    let agentName: String
    let mcpConfigPath: String
    /// Whether the agent has a live session, and the state it is in: the CLI
    /// reads `--mcp-config` only at spawn, so a save reaches a running agent
    /// only through a restart.
    let hasSession: Bool
    let state: Agent.AgentState?
    /// Stops the agent's live session and starts it again with the saved file.
    let onRestart: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var config: ClaudeMCPConfig?
    @State private var envValues: [String: [String: String]] = [:]
    @State private var saveError: String?
    /// Why the MCP file that exists could not be read. Set, the sheet shows
    /// it in place of the servers and Save stays off: there is nothing to save.
    @State private var loadError: String?
    /// Set when the save landed on an agent that was mid-turn, so the sheet
    /// stays open and says when the change takes.
    @State private var appliesAtNextStart: Bool = false

    init(agentName: String, mcpConfigPath: String, hasSession: Bool,
         state: Agent.AgentState?, onRestart: @escaping () -> Void) {
        self.agentName = agentName
        self.mcpConfigPath = mcpConfigPath
        self.hasSession = hasSession
        self.state = state
        self.onRestart = onRestart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Divider()

            if let loadError {
                loadErrorView(loadError)
            } else if let config, !config.mcpServers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(config.mcpServers.keys.sorted(), id: \.self) { serverName in
                            serverSection(name: serverName, entry: config.mcpServers[serverName]!)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("No MCP servers configured")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            if appliesAtNextStart {
                Text("Saved. \(agentName) is mid-turn, so this takes effect at its next start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("agent-config-next-start-note")
            }

            Divider()
            buttons
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 420)
        .frame(minHeight: 300, maxHeight: 600)
        .onAppear { loadConfig() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agentName)
                .font(.headline)
            Text("MCP Configuration")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func loadErrorView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            Text("Could not read the MCP configuration")
                .font(.subheadline.bold())
            Text(mcpConfigPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func serverSection(name: String, entry: ClaudeMCPServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text(name)
                    .font(.subheadline.bold())
            }

            // A server Kiteloop cannot model as a stdio command has no command
            // line to show; it is described by what it does carry.
            let summary = entry.displaySummary
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let env = entry.env, !env.isEmpty {
                ForEach(env.keys.sorted(), id: \.self) { key in
                    envField(serverName: name, key: key)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    @ViewBuilder
    private func envField(serverName: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            let binding = Binding<String>(
                get: { envValues[serverName]?[key] ?? "" },
                set: { envValues[serverName, default: [:]][key] = $0 }
            )

            if isSecretKey(key) {
                SecureField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                TextField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(loadError != nil)
        }
    }

    /// A missing file is no servers; one that exists and cannot be read says
    /// why; a read one fills each server's fields with the values it holds.
    private func loadConfig() {
        switch Result(catching: { try ClaudeMCPConfig.loadIfPresent(from: mcpConfigPath) }) {
        case .success(let loaded?):
            config = loaded
            envValues.merge(loaded.mcpServers.compactMapValues(\.env)) { _, read in read }
        case .success(nil):
            break
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard var config else { return }
        for (serverName, values) in envValues {
            config.mcpServers[serverName]?.env = values
        }
        switch Self.saveEffect(hasSession: hasSession, state: state, write: { try config.save(to: mcpConfigPath) }) {
        case .success(.dismiss):
            dismiss()
        case .success(.restartSession):
            onRestart()
            dismiss()
        case .success(.applyAtNextStart):
            saveError = nil
            appliesAtNextStart = true
        case .failure(let error):
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }

    /// Writes the file, then decides what that means for the agent's live
    /// session by the same rule Edit Agent… follows. A write that throws
    /// decides nothing, so nothing is restarted.
    static func saveEffect(
        hasSession: Bool, state: Agent.AgentState?, write: () throws -> Void
    ) -> Result<AgentEditorSheet.SaveEffect, Error> {
        Result {
            try write()
            return AgentEditorSheet.saveEffect(hasSession: hasSession, state: state)
        }
    }

    private func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("key") || lower.contains("token") || lower.contains("secret") || lower.contains("password")
    }
}
