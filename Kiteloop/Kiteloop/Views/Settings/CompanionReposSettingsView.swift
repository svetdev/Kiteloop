import SwiftUI
import KiteloopCore

/// The project's companion repositories (`ProjectConfig.companions`), edited
/// as rows and written by Save. Save writes only `companions`, onto a fresh
/// read of the config, so every other field stays as it is on disk.
struct CompanionReposSettingsView: View {
    let project: KiteloopProject
    /// Where this page reports rows typed but not yet saved, so leaving it
    /// asks first. See `SettingsEditGuard`.
    let editGuard: SettingsEditGuard
    @State private var rows: [EditableRow] = []
    /// The rows as last loaded or saved. An edit is the two disagreeing.
    @State private var savedRows: [CompanionRepo.Row] = []
    @State private var saveError: String?

    /// One row on screen, with an identity for `ForEach`.
    private struct EditableRow: Identifiable {
        let id = UUID()
        var row: CompanionRepo.Row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Companion Repositories")
                .font(.headline)
            Text("Other git repositories an item may change alongside this one. An item opts in with `repos:` in its detail frontmatter. Stored in .kiteloop/config.json.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Spacer()
                Button("Add Repository") { rows.append(EditableRow(row: .init(name: "", path: ""))) }
                    .accessibilityIdentifier("settings-companion-add")
            }

            rowList

            HStack {
                if let saveError {
                    FooterErrorLabel(saveError)
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings-companion-save")
            }
        }
        .padding()
        .onAppear { load() }
        .onChange(of: rows.map(\.row)) { _, current in
            editGuard.report(isDirty: current != savedRows, for: .companions)
        }
    }

    @ViewBuilder
    private var rowList: some View {
        if rows.isEmpty {
            ContentUnavailableView("No Companion Repositories", systemImage: "folder.badge.plus",
                                   description: Text("Add a repository a run may change beside this project."))
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach($rows) { $entry in
                    HStack {
                        TextField("Name", text: $entry.row.name)
                            .frame(width: 140)
                        TextField("Path", text: $entry.row.path)
                        TextField("Base branch", text: $entry.row.baseBranch,
                                  prompt: Text("its checkout's branch"))
                            .frame(width: 160)
                        Button(role: .destructive) {
                            rows.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this repository. Nothing changes on disk until Save.")
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
            }
        }
    }

    private func load() {
        let loaded = (project.loadConfig().companions ?? []).map {
            CompanionRepo.Row(name: $0.name, path: $0.path, baseBranch: $0.baseBranch ?? "")
        }
        rows = loaded.map { EditableRow(row: $0) }
        markSaved(loaded)
    }

    private func save() {
        switch CompanionRepo.edit(fromRows: rows.map(\.row)) {
        case .refused(let problems):
            saveError = problems.joined(separator: "; ")
        case .store(let companions):
            var config = project.loadConfig()
            config.companions = companions
            do {
                try project.saveConfig(config)
                load()
                saveError = nil
            } catch {
                saveError = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    private func markSaved(_ loaded: [CompanionRepo.Row]) {
        savedRows = loaded
        editGuard.report(isDirty: false, for: .companions)
    }
}
