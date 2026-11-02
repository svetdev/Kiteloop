import KiteloopCore
import SwiftUI

struct PluginManagerView: View {
    /// The spawn needs the resolved Claude CLI path — honouring an operator's
    /// `claudePath` override and falling back to the same `which`-then-candidates
    /// lookup every other spawn site in the app uses — rather than shelling
    /// `/usr/bin/env claude`, which only finds `claude` when it is already on the
    /// minimal PATH a GUI app inherits from Finder.
    let globalConfig: GlobalConfig

    @State private var installedPlugins: [InstalledPlugin] = []
    @State private var installInput = ""
    @State private var isInstalling = false
    @State private var installStatus: String?
    /// The rows a delete swipe named, held until the confirmation answers.
    /// Removing a plugin deletes its directory under `~/.claude/plugins/cache`
    /// outright, so the swipe only asks — nothing leaves the disk until the
    /// destructive button is pressed.
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugins")
                .font(.headline)
            Text("Claude Code plugins extend agent capabilities with skills and tools. Installed at ~/.claude/plugins/.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                TextField("Plugin (e.g. name@marketplace)", text: $installInput)
                    .textFieldStyle(.roundedBorder)
                Button("Install") {
                    Task { await installPlugin() }
                }
                .disabled(installInput.isEmpty || isInstalling)
                .buttonStyle(.borderedProminent)
            }

            if let status = installStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("Error") ? .red : .green)
            }

            Divider()

            if installedPlugins.isEmpty {
                ContentUnavailableView("No Plugins Installed", systemImage: "puzzlepiece", description: Text("Install a plugin to add skills to your agents."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(installedPlugins) { plugin in
                        HStack {
                            PluginRow(plugin: plugin)
                            Button(role: .destructive) {
                                if let index = installedPlugins.firstIndex(where: { $0.id == plugin.id }) {
                                    pendingDeleteOffsets = IndexSet(integer: index)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete this plugin. Asks first.")
                            .accessibilityIdentifier("settings-plugin-delete-\(plugin.name)")
                        }
                    }
                    .onDelete { indexSet in
                        pendingDeleteOffsets = indexSet
                    }
                }
            }
        }
        .padding()
        .onAppear { scanPlugins() }
        .confirmationDialog(
            "Delete this plugin?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            )
        ) {
            Button("Delete Plugin", role: .destructive) {
                guard let offsets = pendingDeleteOffsets else { return }
                pendingDeleteOffsets = nil
                removePlugins(at: offsets)
            }
            Button("Cancel", role: .cancel) { pendingDeleteOffsets = nil }
        } message: {
            Text(Self.deletePluginMessage(names: pendingDeleteNames))
        }
    }

    /// The names the pending delete would take, in list order.
    private var pendingDeleteNames: [String] {
        guard let offsets = pendingDeleteOffsets else { return [] }
        return offsets.sorted().compactMap { index in
            index < installedPlugins.count ? installedPlugins[index].name : nil
        }
    }

    /// What the delete confirmation says: the plugin by name, and that the
    /// deletion reaches the disk — the row goes and so do its files under
    /// `~/.claude/plugins/cache`.
    static func deletePluginMessage(names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }.joined(separator: ", ")
        if names.count == 1 {
            return "Deletes the plugin \(quoted) and removes its files from disk. This can't be undone."
        }
        return "Deletes the plugins \(quoted) and removes their files from disk. This can't be undone."
    }

    private func scanPlugins() {
        let cacheDir = KiteloopHome.url.appending(path: ".claude/plugins/cache")
        installedPlugins = Self.scanPlugins(cacheDir: cacheDir)
    }

    /// Walks `cacheDir` (`~/.claude/plugins/cache/<registry>/<plugin>/<version>/`)
    /// and builds the installed-plugin list, sorted by name.
    ///
    /// Picks each plugin's newest version with `SkillRegistry.newestVersionDirectory(among:)` —
    /// the same helper `SkillRegistry.defaultScanPaths` uses for this exact layout —
    /// rather than sorting version names as plain text, which would rank `1.9.0`
    /// above `1.10.0` and read the skills of the wrong version.
    nonisolated static func scanPlugins(cacheDir: URL) -> [InstalledPlugin] {
        let fm = FileManager.default
        guard let registries = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var plugins: [InstalledPlugin] = []
        for registry in registries {
            let registryName = registry.lastPathComponent
            guard let pluginDirs = try? fm.contentsOfDirectory(
                at: registry,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for pluginDir in pluginDirs {
                let pluginName = pluginDir.lastPathComponent
                guard let versions = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                guard let latest = SkillRegistry.newestVersionDirectory(among: versions) else {
                    plugins.append(InstalledPlugin(
                        registry: registryName,
                        name: pluginName,
                        version: "unknown",
                        skillCount: 0,
                        path: pluginDir
                    ))
                    continue
                }

                // Counts what the app would load, not what the directory holds:
                // `SkillRegistry.discoverSkillFiles` takes a subdirectory with a
                // readable SKILL.md, so a README or a hidden file is not a skill.
                let skillsDir = latest.appending(path: "skills")
                let entries = (try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let skillCount = entries.filter {
                    fm.isReadableFile(atPath: $0.appending(path: "SKILL.md").path(percentEncoded: false))
                }.count

                plugins.append(InstalledPlugin(
                    registry: registryName,
                    name: pluginName,
                    version: latest.lastPathComponent,
                    skillCount: skillCount,
                    path: pluginDir
                ))
            }
        }
        return plugins.sorted { $0.name < $1.name }
    }

    private func installPlugin() async {
        let identifier = installInput.trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return }
        isInstalling = true
        installStatus = "Installing \(identifier)..."

        let claudePath = CLIResolver.resolve(globalConfig: globalConfig).claude
        let arguments = Self.installArguments(for: identifier)
        let result = await Task.detached {
            Self.runInstall(arguments, executable: claudePath)
        }.value

        if result.status == 0 {
            installStatus = "Installed \(identifier) successfully."
            installInput = ""
            scanPlugins()
        } else if result.timedOut {
            installStatus = "Error: install timed out after \(Int(Self.installTimeout))s."
        } else {
            installStatus = "Error: \(String(result.output.prefix(200)))"
        }
        isInstalling = false
    }

    /// The Claude CLI arguments that install `identifier` — a plugin named as
    /// `plugin` or `plugin@marketplace` — through `claude plugin install`.
    nonisolated static func installArguments(for identifier: String) -> [String] {
        ["plugin", "install", identifier.trimmingCharacters(in: .whitespaces)]
    }

    /// How long an install spawn gets before it's treated as hung. A `claude`
    /// that stopped to ask for an interactive answer — e.g. an unauthenticated
    /// session — would otherwise hold `isInstalling` for the life of the app,
    /// with the Install button disabled and no way to cancel.
    ///
    /// `nonisolated`: it is the default value of a `nonisolated` function's
    /// parameter, and a `View`'s static members are main-actor-isolated by
    /// default, which a nonisolated context cannot reference.
    nonisolated static let installTimeout: TimeInterval = 60

    /// Runs the plugin install command against `executable`, on a deadline.
    ///
    /// `executable` is `nil` when `CLIResolver` found no usable Claude CLI —
    /// handled here, not only by the caller, so the "no CLI" arm is directly
    /// testable: it returns a failed result naming the setting to fix without
    /// touching `Process` at all.
    ///
    /// Synchronous — it blocks until the child exits or the deadline fires, so
    /// call it off the main actor.
    nonisolated static func runInstall(
        _ arguments: [String],
        executable: String?,
        timeout: TimeInterval = installTimeout
    ) -> (status: Int32, output: String, timedOut: Bool) {
        guard let executable else {
            return (-1, "no Claude CLI found — set it in Settings › General › Setup & Health (Claude CLI)", false)
        }
        return SubprocessOutput.runWithDeadline(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    private func removePlugins(at offsets: IndexSet) {
        let (kept, failureMessage) = Self.removePlugins(installedPlugins, at: offsets)
        installedPlugins = kept
        if let failureMessage {
            installStatus = failureMessage
        }
    }

    /// Deletes the plugins at `offsets` via `removeItem`, and reports what to
    /// keep plus a message naming any that could not be removed. A plugin whose
    /// removal throws — a permission the app does not have on
    /// `~/.claude/plugins/cache`, a file held open, a read-only volume — must
    /// stay in the list rather than silently vanishing from it while still
    /// installed and still loaded by every agent.
    ///
    /// `removeItem` is the injected-closure shape `SubprocessOutput.git` and
    /// `Orchestrator.runShellNodeCommand` already use for their failure arms, so
    /// the failure path is directly testable; nothing in the app passes it.
    static func removePlugins(
        _ plugins: [InstalledPlugin],
        at offsets: IndexSet,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> (kept: [InstalledPlugin], failureMessage: String?) {
        var kept = plugins
        var failures: [String] = []
        for index in offsets.sorted(by: >) {
            let plugin = plugins[index]
            do {
                try removeItem(plugin.path)
                kept.remove(at: index)
            } catch {
                failures.append("\(plugin.name) (\(error.localizedDescription))")
            }
        }
        guard !failures.isEmpty else { return (kept, nil) }
        return (kept, "Error: could not remove \(failures.joined(separator: ", "))")
    }
}

struct InstalledPlugin: Identifiable {
    let id = UUID()
    let registry: String
    let name: String
    let version: String
    let skillCount: Int
    let path: URL
}

private struct PluginRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body.bold())
                Text("\(plugin.registry) · v\(plugin.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(plugin.skillCount) skill\(plugin.skillCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }
}
