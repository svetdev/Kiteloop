import SwiftUI
import KiteloopCore

struct MCPServerConfigView: View {
    let projectPath: String
    /// Where this page reports work typed but not yet saved, so leaving it
    /// asks first. See `SettingsEditGuard`.
    let editGuard: SettingsEditGuard
    @State private var servers: [MCPServerRow] = []
    @State private var selectedServerID: UUID?
    @State private var saveError: String?
    /// What `fingerprint` was when the page last loaded or saved. An edit is
    /// the two disagreeing.
    @State private var savedFingerprint: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP Servers")
                .font(.headline)
            Text("Model Context Protocol servers provide tools to agents. Stored in .claude/settings.json.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Spacer()
                Button("Add Server") {
                    let row = MCPServerRow(name: "new-server", command: "npx", args: "-y @example/server", env: "")
                    servers.append(row)
                    selectedServerID = row.id
                }
            }

            if servers.isEmpty {
                ContentUnavailableView("No MCP Servers", systemImage: "server.rack", description: Text("Add an MCP server to extend agent capabilities."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedServerID) {
                    ForEach($servers) { $server in
                        HStack(alignment: .top) {
                            MCPServerRowView(server: $server)
                            Button(role: .destructive) {
                                servers.removeAll { $0.id == server.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Remove this server. Nothing changes on disk until Save.")
                            .accessibilityIdentifier("settings-project-mcp-delete-\(server.name)")
                        }
                    }
                    .onDelete { indexSet in
                        servers.remove(atOffsets: indexSet)
                    }
                }
            }

            HStack {
                if let saveError {
                    FooterErrorLabel(saveError)
                }
                Spacer()
                Button("Save") { saveServers() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { loadServers() }
        .onChange(of: fingerprint) { _, current in
            editGuard.report(isDirty: current != savedFingerprint, for: .mcpServers)
        }
    }

    /// What the page has on screen, as text a baseline can be compared with.
    /// `MCPServerRow` is not `Equatable`, so the four fields a row edits, and
    /// the names of the keys it keeps unedited, are what an edit shows up in.
    private var fingerprint: String {
        servers
            .map { "\($0.name)\u{1}\($0.command)\u{1}\($0.args)\u{1}\($0.env)\u{1}\($0.extras.keys.sorted())" }
            .joined(separator: "\u{2}")
    }

    private func markSaved() {
        savedFingerprint = fingerprint
        editGuard.report(isDirty: false, for: .mcpServers)
    }

    private func loadServers() {
        guard !projectPath.isEmpty else { return }
        let settingsURL = URL(fileURLWithPath: projectPath).appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any] else { return }
        servers = Self.rows(from: mcpServers)
        markSaved()
    }

    /// The `mcpServers` dictionary as rows, sorted by name. Every key the page
    /// does not edit — a remote server's `type`, `url` and `headers`, a stdio
    /// server's `cwd` — is kept verbatim in `extras`, so Save writes it back.
    static func rows(from mcpServers: [String: Any]) -> [MCPServerRow] {
        var rows: [MCPServerRow] = []
        for (name, value) in mcpServers {
            guard let config = value as? [String: Any] else { continue }
            let command = config["command"] as? String ?? ""
            let args = ShellArguments.line(from: config["args"] as? [String] ?? [])
            let envDict = (config["env"] as? [String: Any] ?? [:]).compactMapValues(envValue)
            let envStr = envDict.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            let extras = config.filter { !["command", "args", "env"].contains($0.key) }
            rows.append(MCPServerRow(name: name, command: command, args: args, env: envStr, extras: extras))
        }
        return rows.sorted { $0.name < $1.name }
    }

    /// An env value as the text the page edits: a number or a boolean in its
    /// JSON spelling, rather than one such value emptying the whole env.
    private static func envValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }

    /// The entry a row writes: its kept keys, with command, args and env laid
    /// over them. A row with no command writes neither command nor args, so a
    /// remote server stays remote.
    static func entry(for server: MCPServerRow) -> [String: Any] {
        var entry = server.extras
        if !server.command.isEmpty {
            entry["command"] = server.command
            entry["args"] = ShellArguments.tokenize(server.args)
        }
        let env = Self.environment(from: server.env)
        if !env.isEmpty {
            entry["env"] = env
        }
        return entry
    }

    /// The typed `KEY=VALUE` lines, as the dictionary that is written.
    ///
    /// A value may be empty — `TOKEN=` is a variable the server sees as the
    /// empty string, not a line to drop — so the split keeps empty
    /// subsequences. Both sides are trimmed, so `KEY = value` is the name
    /// `KEY`, not `"KEY "`. A line with no `=` at all, and a line whose name is
    /// blank once trimmed, carry no variable and are skipped.
    static func environment(from text: String) -> [String: String] {
        let pairs = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, parts[1].trimmingCharacters(in: .whitespaces))
        }
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }

    /// The `mcpServers` dictionary the rows say to write, or the reason the
    /// list is not writable. A row with no name, a row with neither a command
    /// nor a `url`, and two rows
    /// that share one name, are refused by position so the person can find the
    /// row: before this, such a row was written nowhere and simply gone at the
    /// next load.
    static func serversToWrite(from rows: [MCPServerRow]) -> MCPServerSave {
        var mcpServers: [String: Any] = [:]
        for (index, server) in rows.enumerated() {
            let row = "Row \(index + 1)"
            guard !server.name.isEmpty else {
                return .refused("\(row) has no server name. Name it or remove it before saving.")
            }
            guard !server.command.isEmpty || server.extras["url"] != nil else {
                return .refused("\(row) (\"\(server.name)\") has no command. Give it one or remove the row before saving.")
            }
            guard mcpServers[server.name] == nil else {
                return .refused("Two rows are named \"\(server.name)\". Rename one before saving.")
            }
            mcpServers[server.name] = entry(for: server)
        }
        return .servers(mcpServers)
    }

    private func saveServers() {
        guard !projectPath.isEmpty else { return }
        let mcpServers: [String: Any]
        switch Self.serversToWrite(from: servers) {
        case .refused(let message):
            saveError = message
            return
        case .servers(let entries):
            mcpServers = entries
        }
        let settingsURL = URL(fileURLWithPath: projectPath).appending(path: ".claude/settings.json")
        let claudeDir = URL(fileURLWithPath: projectPath).appending(path: ".claude")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = json
        }

        existing["mcpServers"] = mcpServers
        do {
            let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            saveError = nil
            markSaved()
        } catch {
            saveError = "Couldn't save MCP servers: \(error.localizedDescription)"
        }
    }
}

/// What the MCP panel's Save does with the rows: the dictionary to write, or
/// the message the person is shown instead of a silent write.
enum MCPServerSave {
    case servers([String: Any])
    case refused(String)
}

struct MCPServerRow: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var args: String
    var env: String
    /// The entry's keys other than command, args and env, verbatim — a remote
    /// server's `type`, `url` and `headers`, or a stdio server's `cwd`. The
    /// page shows a remote server's but edits none of them.
    var extras: [String: Any] = [:]

    /// `type: url` for a remote server, nil for a stdio one.
    var remoteSummary: String? {
        guard let url = extras["url"] as? String else { return nil }
        guard let type = extras["type"] as? String else { return url }
        return "\(type): \(url)"
    }
}

private struct MCPServerRowView: View {
    @Binding var server: MCPServerRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Server name", text: $server.name)
                    .frame(width: 160)
                    .help("Unique name for this MCP server")
                TextField("Command", text: $server.command)
                    .frame(width: 100)
                    .help("e.g. npx, node, python")
            }
            TextField("Arguments (quote one that contains a space)", text: $server.args)
                .help("e.g. -y @modelcontextprotocol/server-github --root \"/Users/me/My Project\"")
            TextField("Environment (KEY=VALUE per line)", text: $server.env, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(.body, design: .monospaced))
                .help("e.g. GITHUB_TOKEN=ghp_xxx")
            if let remote = server.remoteSummary {
                Text(remote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
