import KiteloopCore
import SwiftUI

/// The project's settings, one page per concern, chosen from a sidebar list.
///
/// Seven tabs was where the tab strip stopped working — labels truncating,
/// the eighth page with nowhere to go — and it was still missing the page
/// that mattered most: everything autopilot does in this project lived in a
/// popover behind a gear on another tab. The list has room to grow, groups the
/// four integrations under one heading, and can be opened on a page from
/// anywhere in the window through `OpenProjectSettingsAction`.
struct ProjectSettingsView: View {
    let project: KiteloopProject
    let globalConfigStore: GlobalConfigStore
    /// The open project's backlog. The Backlog Flow page edits it in place so a
    /// changed flow reaches the running project rather than only the file.
    let backlog: BacklogViewModel
    /// This project's autopilot, for the Autopilot page. Its switches write
    /// through to the live instance the way the gear popover's used to.
    let autopilot: BacklogAutopilot
    /// The agents offered as worker and reviewer. Team only.
    var agents: [Agent] = []
    /// The page the sheet opens on.
    var initialPage: ProjectSettingsPage = .general
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPage: ProjectSettingsPage?
    @State private var model: String = ""
    @State private var permissionMode: String = ProjectConfig.default.permissionMode
    @State private var effort: String = ""
    @State private var maxBudgetUSD: String = ""
    @State private var showAdvanced = false
    @State private var loaded = false
    @State private var saveError: String?
    /// Unsaved work on the page in view, and the answer to whether a
    /// navigation away from it can go ahead. See `SettingsEditGuard`.
    @State private var editGuard = SettingsEditGuard()
    /// Where the person asked to go while a page had unsaved edits, held until
    /// they discard them or go back to editing.
    @State private var pendingDestination: SettingsEditGuard.Destination?

    private var page: ProjectSettingsPage { selectedPage ?? initialPage }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 190)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 540)
        .onAppear {
            selectedPage = initialPage
            loadConfig()
        }
        .confirmationDialog("Discard your unsaved changes?", isPresented: confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                guard let destination = pendingDestination else { return }
                pendingDestination = nil
                go(to: destination)
            }
            Button("Keep Editing", role: .cancel) { pendingDestination = nil }
        } message: {
            Text("This page has edits you haven't saved. Leaving it loses them.")
        }
    }

    /// The dialog is up exactly while a destination is waiting on an answer.
    private var confirmingDiscard: Binding<Bool> {
        Binding(
            get: { pendingDestination != nil },
            set: { shown in if !shown { pendingDestination = nil } }
        )
    }

    /// The sidebar's selection, routed through the guard: picking another row
    /// while a page has unsaved edits raises the dialog instead of destroying
    /// the page, and the list stays on the page it was on because the getter
    /// still reports it.
    private var sidebarSelection: Binding<ProjectSettingsPage?> {
        Binding(
            get: { selectedPage },
            set: { picked in if let picked { requestNavigation(to: .page(picked)) } }
        )
    }

    /// Carries the navigation out, or asks first when it would throw away
    /// unsaved work.
    private func requestNavigation(to destination: SettingsEditGuard.Destination) {
        switch editGuard.decision(for: destination) {
        case .proceed: go(to: destination)
        case .confirm: pendingDestination = destination
        }
    }

    private func go(to destination: SettingsEditGuard.Destination) {
        editGuard.clear()
        switch destination {
        case .page(let picked): selectedPage = picked
        case .done: dismiss()
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(ProjectSettingsPage.allCases.filter { !$0.isIntegration }) { page in
                    pageRow(page)
                }
            }
            Section("Integrations") {
                ForEach(ProjectSettingsPage.allCases.filter(\.isIntegration)) { page in
                    pageRow(page)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("project-settings-pages")
    }

    private func pageRow(_ page: ProjectSettingsPage) -> some View {
        Label(page.title, systemImage: page.icon)
            .tag(page)
            .accessibilityIdentifier("project-settings-page-\(page.rawValue)")
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general:
            generalTab
        case .autopilot:
            AutopilotRunSettingsForm(autopilot: autopilot, agents: agents, backlog: backlog, project: project)
        case .backlogFlow:
            BacklogFlowSettingsView(backlog: backlog)
        case .direction:
            ScrollView { ProjectDirectionView(project: project) }
        case .mcpServers:
            MCPServerConfigView(projectPath: project.rootURL.path(percentEncoded: false), editGuard: editGuard)
        case .hooks:
            HookConfigView(projectPath: project.rootURL.path(percentEncoded: false), editGuard: editGuard)
        case .git:
            GitIntegrationView(projectPath: project.rootURL.path(percentEncoded: false))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.rootURL.lastPathComponent)
                    .font(.headline)
                Text(project.rootURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if let saveError {
                FooterErrorLabel(saveError)
            }
            Spacer()
            Button("Done") { requestNavigation(to: .done) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("project-settings-done-button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var generalTab: some View {
        Form {
            Section("Model & Effort") {
                Picker("Model", selection: $model) {
                    Text(modelDefaultLabel).tag("")
                    ForEach(ModelCatalog.all) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .accessibilityIdentifier("project-settings-model-picker")

                Picker("Reasoning Effort", selection: $effort) {
                    Text(effortDefaultLabel).tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Max").tag("max")
                }
                .accessibilityIdentifier("project-settings-effort-picker")
            }

            Section("Permissions") {
                Picker("Default mode for new agents", selection: $permissionMode) {
                    Text("Auto (Claude Code decides)").tag("auto")
                    Text("Accept Edits").tag("acceptEdits")
                    Text("Plan (read-only)").tag("plan")
                    Text("Ask (before edits and commands)").tag("default")
                    Text("Don't Ask (refuse what would ask)").tag("dontAsk")
                    Text("Bypass All").tag("bypassPermissions")
                }
                .accessibilityIdentifier("project-settings-permission-mode-picker")
                Text("Agents added to this project start in this mode, as do team agents that name none when the project next opens. An agent's own mode, once set, is kept. Chat only — an unattended run always uses auto mode.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Remembered permissions") {
                RememberedPermissionsList(projectRoot: project.rootURL)
            }

            Section("Budget") {
                TextField("Max per-turn USD", text: $maxBudgetUSD)
                    .frame(width: 100)
                    .help("Leave empty for unlimited")
                    .accessibilityIdentifier("project-settings-max-budget-field")
                Text("One turn of a chat agent. Autopilot's caps — per item, per session, per day — are on the Autopilot page.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model) { _, _ in saveConfig() }
        .onChange(of: permissionMode) { _, _ in saveConfig() }
        .onChange(of: effort) { _, _ in saveConfig() }
        .onChange(of: maxBudgetUSD) { _, _ in saveConfig() }
    }

    /// What "Default" resolves to at this scope, and where from: the app's
    /// default model when one is set, else the built-in. The picker's Default
    /// entry says so, because the question a person has here is not what the
    /// project stores but which value wins.
    private var modelDefaultLabel: String {
        let resolved = SettingInheritance.resolve(
            builtIn: ModelCatalog.defaultModelID,
            app: SettingInheritance.present(globalConfigStore.config.defaultModel))
        return SettingInheritance.defaultLabel(resolved, describe: ModelCatalog.displayName(for:))
    }

    private var effortDefaultLabel: String {
        let resolved = SettingInheritance.resolve(
            builtIn: "",
            app: SettingInheritance.present(globalConfigStore.config.defaultEffort))
        return SettingInheritance.defaultLabel(resolved, describe: SettingNames.effort)
    }

    private func loadConfig() {
        guard !loaded else { return }
        loaded = true
        let config = project.loadConfig()
        model = config.model ?? ""
        permissionMode = config.permissionMode
        effort = config.effort ?? ""
        maxBudgetUSD = config.maxBudgetUSD.map { String(format: "%.2f", $0) } ?? ""
    }

    /// What the Budget field's text means. `Double(_:)` alone cannot tell a
    /// field left empty — which is how the project says "unlimited" — from a
    /// typo, and both used to land as nil: a stray keystroke wiped the cap.
    enum BudgetEntry: Equatable {
        /// An empty field: no per-turn cap.
        case unlimited
        /// A positive dollar amount to store.
        case amount(Double)
        /// Text that is not a dollar amount. Stores nothing.
        case invalid

        /// What the config stores for this entry; nil is unlimited.
        var storedValue: Double? {
            if case .amount(let value) = self { return value }
            return nil
        }
    }

    /// Reads the Budget field. Empty is unlimited; anything else must be a
    /// finite, positive number, so `abc`, `1,50` and `-5` are all invalid
    /// rather than silently unlimited.
    static func parseBudget(_ text: String) -> BudgetEntry {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unlimited }
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return .invalid }
        return .amount(value)
    }

    /// What a save of the General page would write: the four fields over
    /// `stored`, everything else in it kept as it was. An empty Model or
    /// Effort is Default — nil, so the app's value wins. A Budget that is not
    /// a dollar amount refuses the whole save with the sentence the page shows,
    /// so a typo never wipes the stored cap.
    static func editedConfig(_ stored: ProjectConfig, model: String, permissionMode: String,
                             effort: String, budgetText: String) -> Result<ProjectConfig, BudgetRefusal> {
        let budget = parseBudget(budgetText)
        guard budget != .invalid else { return .failure(BudgetRefusal()) }
        var config = stored
        config.model = model.isEmpty ? nil : model
        config.permissionMode = permissionMode
        config.effort = effort.isEmpty ? nil : effort
        config.maxBudgetUSD = budget.storedValue
        return .success(config)
    }

    /// Why a save was refused, as the page says it.
    struct BudgetRefusal: Error, Equatable {
        let message = "Budget isn't a dollar amount — type a positive number like 2.50, or leave it empty for unlimited."
    }

    private func saveConfig() {
        guard loaded else { return }
        switch Self.editedConfig(project.loadConfig(), model: model, permissionMode: permissionMode,
                                 effort: effort, budgetText: maxBudgetUSD) {
        case .failure(let refusal):
            saveError = refusal.message
        case .success(let config):
            do {
                try project.saveConfig(config)
                saveError = nil
            } catch {
                saveError = "Couldn't save settings: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Pages

/// The pages of the project settings sheet, in sidebar order. The three
/// integrations are listed under their own heading.
enum ProjectSettingsPage: String, CaseIterable, Identifiable {
    case general, autopilot, backlogFlow, direction
    case mcpServers, hooks, git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .autopilot: return "Autopilot"
        case .backlogFlow: return "Backlog Flow"
        case .direction: return "Direction"
        case .mcpServers: return "MCP Servers"
        case .hooks: return "Hooks"
        case .git: return "Git"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .autopilot: return "bolt.fill"
        case .backlogFlow: return "checklist"
        case .direction: return "scope"
        case .mcpServers: return "puzzlepiece.extension"
        case .hooks: return "bolt.horizontal"
        case .git: return "arrow.triangle.pull"
        }
    }

    var isIntegration: Bool {
        switch self {
        case .mcpServers, .hooks, .git: return true
        case .general, .autopilot, .backlogFlow, .direction: return false
        }
    }
}

// MARK: - Opening the sheet from anywhere

/// Opens the project settings sheet on a page. Installed by the main window
/// over everything in it, the way `OpenItemAction` is, so a surface deep in a
/// tab can send someone to the right page without being handed the sheet's
/// state. A preview or test host without it sees `isInstalled == false` and
/// draws its link disabled rather than one that leads nowhere.
struct OpenProjectSettingsAction {
    private let handler: (@MainActor (ProjectSettingsPage) -> Void)?

    init() { handler = nil }

    init(_ handler: @escaping @MainActor (ProjectSettingsPage) -> Void) {
        self.handler = handler
    }

    var isInstalled: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ page: ProjectSettingsPage) {
        handler?(page)
    }
}

private struct OpenProjectSettingsActionKey: EnvironmentKey {
    static let defaultValue = OpenProjectSettingsAction()
}

extension EnvironmentValues {
    /// The app-level open-settings action. See `OpenProjectSettingsAction`.
    var openProjectSettings: OpenProjectSettingsAction {
        get { self[OpenProjectSettingsActionKey.self] }
        set { self[OpenProjectSettingsActionKey.self] = newValue }
    }
}
