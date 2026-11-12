import KiteloopCore
import SwiftUI

struct AgentCatalogView: View {
    @Bindable var catalogStore: AgentCatalogStore
    @State private var sheetTemplate: AgentTemplate?
    @State private var isAddingNew = false
    /// The template whose trash was pressed, held until the confirmation
    /// answers. `AgentCatalogStore.remove(id:)` writes the catalog file
    /// immediately and there is no undo, so the click only asks — and the
    /// trash sits one icon away from the pencil.
    @State private var pendingDeleteTemplate: AgentTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    claudeRow
                    Divider().padding(.horizontal, 12)

                    ForEach(groupedTemplates, id: \.group) { section in
                        if let group = section.group {
                            HStack {
                                Text(group.uppercased())
                                    .font(.system(.caption2, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        }
                        ForEach(section.templates) { template in
                            catalogRow(template)
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
        .sheet(isPresented: Binding(
            get: { sheetTemplate != nil || isAddingNew },
            set: { if !$0 { sheetTemplate = nil; isAddingNew = false } }
        )) {
            CatalogTemplateEditor(template: sheetTemplate) { result in
                if sheetTemplate != nil {
                    catalogStore.update(result)
                } else {
                    catalogStore.add(result)
                }
                sheetTemplate = nil
                isAddingNew = false
            }
        }
        .confirmationDialog(
            "Delete this task agent?",
            isPresented: Binding(
                get: { pendingDeleteTemplate != nil },
                set: { if !$0 { pendingDeleteTemplate = nil } }
            )
        ) {
            Button("Delete Agent", role: .destructive) {
                guard let template = pendingDeleteTemplate else { return }
                pendingDeleteTemplate = nil
                catalogStore.remove(id: template.id)
            }
            Button("Cancel", role: .cancel) { pendingDeleteTemplate = nil }
        } message: {
            Text(Self.deleteTemplateMessage(
                name: pendingDeleteTemplate?.name ?? "",
                handle: pendingDeleteTemplate.map { catalogStore.templateHandle(for: $0) } ?? ""
            ))
        }
    }

    /// What the delete confirmation says: the agent by name and by the handle
    /// that stops working once it is gone — the part a bare trash icon next to
    /// a pencil doesn't show.
    static func deleteTemplateMessage(name: String, handle: String) -> String {
        "Deletes the task agent “\(name)” from the catalog. @\(handle) will no longer summon it. This can't be undone."
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Task Agents")
                    .font(.title3.bold())
                Text("Specialist agents you can summon with @mention to get a dedicated chat tab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { isAddingNew = true } label: {
                Image(systemName: "plus")
            }
        }
    }

    private var claudeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Claude")
                        .font(.body.bold())
                    Text("Always present")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
                Text("Full-capability generalist — does everything, can summon specialists")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("@claude")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.04))
    }

    private func catalogRow(_ template: AgentTemplate) -> some View {
        HStack(spacing: 12) {
            AgentAvatarView(
                agent: template.instantiateAgent(),
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.body)
                if !template.description.isEmpty {
                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("@\(catalogStore.templateHandle(for: template))")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)

            Button {
                sheetTemplate = template
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                pendingDeleteTemplate = template
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private struct TemplateSection: Hashable {
        let group: String?
        let templates: [AgentTemplate]
        func hash(into hasher: inout Hasher) { hasher.combine(group) }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.group == rhs.group }
    }

    private var groupedTemplates: [TemplateSection] {
        var groups: [String?: [AgentTemplate]] = [:]
        for t in catalogStore.templates {
            groups[t.group, default: []].append(t)
        }
        let order = groups.keys.sorted { ($0 ?? "zzz") < ($1 ?? "zzz") }
        return order.map { TemplateSection(group: $0, templates: groups[$0]!) }
    }
}

// MARK: - CatalogTemplateEditor

struct CatalogTemplateEditor: View {
    let template: AgentTemplate?
    let onSave: (AgentTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var model: String = CatalogModelSelection.initial(for: nil)
    @State private var description: String = ""
    @State private var group: String = ""
    @State private var systemPrompt: String = ""
    @State private var permissionMode: String = Agent.defaultPermissionMode
    /// `nil` is the picker's "Auto (by role)" state — no avatar chosen, so
    /// the agent is drawn with the emoji its role derives.
    @State private var avatar: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(template == nil ? "New Agent" : "Edit Agent")
                .font(.headline)
                .padding()

            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                    TextField("Group (e.g. Engineering, Quality)", text: $group)
                    AvatarPickerField(selection: $avatar)
                }

                Section("Configuration") {
                    Picker("Model", selection: $model) {
                        ForEach(ModelCatalog.pickerOptions(including: model)) { option in
                            Text(option.pickerLabel).tag(option.id)
                        }
                    }

                    Picker("Permission Mode", selection: $permissionMode) {
                        Text("Auto (Claude Code decides)").tag("auto")
                        Text("Accept Edits").tag("acceptEdits")
                        Text("Plan (read-only)").tag("plan")
                        Text("Ask (before edits and commands)").tag("default")
                        Text("Don't Ask (refuse what would ask)").tag("dontAsk")
                    }
                }

                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let result = Self.rebuiltTemplate(
                        from: template,
                        name: name,
                        model: model,
                        description: description,
                        group: group,
                        systemPrompt: systemPrompt,
                        permissionMode: permissionMode,
                        avatar: avatar
                    )
                    onSave(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 520)
        .onAppear {
            if let t = template {
                name = t.name
                model = CatalogModelSelection.initial(for: t)
                description = t.description
                group = t.group ?? ""
                systemPrompt = t.systemPrompt
                permissionMode = t.permissionMode
                avatar = t.avatar
            }
        }
    }

    /// The template Save writes: the form's fields, plus everything the form
    /// does not edit carried off the template being edited. A field dropped
    /// here resets on the next save — `runtimeKind` turned a Copilot-backed
    /// template into a Claude one, and `mcpServers` emptied its allowlist.
    static func rebuiltTemplate(
        from template: AgentTemplate?,
        name: String,
        model: String,
        description: String,
        group: String,
        systemPrompt: String,
        permissionMode: String,
        avatar: String?
    ) -> AgentTemplate {
        AgentTemplate(
            id: template?.id ?? UUID().uuidString,
            name: name,
            model: model,
            systemPrompt: systemPrompt,
            tools: template?.tools ?? ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "publish_event", "propose_memory"],
            denied: template?.denied ?? [],
            permissionMode: permissionMode,
            subscriptions: template?.subscriptions ?? [],
            mcpServers: template?.mcpServers ?? [],
            skills: template?.skills ?? [],
            description: description,
            avatar: avatar,
            group: group.isEmpty ? nil : group,
            runtimeKind: template?.runtimeKind
        )
    }
}

/// The model a catalog template's editor opens on: the template's own,
/// normalised the way every other model picker normalises it — so a Bedrock
/// inference-profile id selects its family — or, for a new template, the
/// app's default model.
enum CatalogModelSelection {
    static func initial(for template: AgentTemplate?) -> String {
        template.map { ModelCatalog.normalize($0.model) } ?? ModelCatalog.defaultModelID
    }
}
