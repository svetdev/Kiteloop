import Foundation
import KiteloopCore
import os.log

private let packInstallLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "pack-install")

/// A pack folder a person chose to install into a project: what File >
/// Install Pack… hands the project's window to put the confirmation up for.
struct OfferedPack: Identifiable, Equatable {
    let folder: URL
    var id: String { folder.path(percentEncoded: false) }
}

/// Installing a pack into this project: the plan a person reads, and the
/// install they confirm. Nothing here is reachable from the control API.
extension ProjectSession {

    /// What installing the pack in `folder` would write, read against the
    /// project and the app as they stand now. Writes nothing.
    func packInstallPlan(folder: URL, routines: RoutineRunner?,
                         globalConfig: GlobalConfigStore) throws -> PackInstallPlan {
        let agents = orchestrator.agents
        let target = PackInstallTarget(
            projectName: project.rootURL.lastPathComponent,
            defaultPermissionMode: Agent.initialPermissionMode(projectConfig: project.loadConfig()),
            permissionModes: Agent.permissionModes,
            agentsDirectory: project.localAgentsURL,
            templatesDirectory: project.rootURL.appending(path: BacklogTemplateStore.directoryName),
            templateSearchDirectories: BacklogTemplateStore.directories(
                backlogURL: backlogViewModel.backlogURL, projectRoot: project.rootURL),
            agentNames: agents.map(\.name) + agents.map(\.id),
            routineIDs: (routines?.routines ?? []).map(\.id),
            connectorNames: (globalConfig.config.mcpServers ?? [:]).keys.sorted())
        let plan = try PackInstallPlan.make(folder: folder, target: target)
        _ = try plan.agents.map(Self.package)
        return plan
    }

    /// Installs what `confirmed` describes, and only that: the plan is made
    /// again and refused if it no longer reads as it did when it was shown.
    /// Agents join the team without being started, routines are added
    /// disarmed, connectors carry no value, and one line goes to the
    /// project's configuration change log.
    func installPack(_ confirmed: PackInstallPlan, routines: RoutineRunner?,
                     globalConfig: GlobalConfigStore) throws {
        let plan = try packInstallPlan(folder: confirmed.folder, routines: routines, globalConfig: globalConfig)
        guard plan.account == confirmed.account else { throw PackInstallError.changedSinceRead }
        let packages = try plan.agents.map(Self.package)
        try plan.copyFiles()
        do {
            try add(plan.routines, to: routines)
        } catch {
            plan.removeCopiedFiles()
            throw error
        }
        if !plan.connectors.isEmpty {
            globalConfig.setMCPServers((globalConfig.config.mcpServers ?? [:])
                .merging(plan.connectors) { existing, _ in existing })
        }
        join(packages, as: plan.agents, appDefaultEffort: globalConfig.config.defaultEffort)
        do {
            try ConfigChangeLog.append(plan.logRecord(at: .now),
                                       to: ConfigChangeLog.url(projectPath: project.rootURL.path(percentEncoded: false)))
        } catch {
            packInstallLog.error("Failed to log a pack install: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The agent package the app reads from a planned agent's `agent.json`.
    /// What is wrong with one is said in fixed words: the decoder's own can
    /// quote the file.
    private static func package(of agent: PackInstallPlan.AgentInstall) throws -> AgentPackage {
        let file = (agent.agent.path as NSString).appendingPathComponent("agent.json")
        guard let source = agent.files.first(where: {
            $0.destination == agent.destination.appendingPathComponent("agent.json")
        })?.source, let data = try? Data(contentsOf: source),
              let package = try? JSONDecoder().decode(AgentPackage.self, from: data) else {
            throw PackInspectionError.undecodable(file: file, field: nil,
                                                  reason: "is not an agent package this app can read")
        }
        return package
    }

    /// Adds every routine, or none: one that is refused takes back the ones
    /// added before it.
    private func add(_ planned: [Routine], to routines: RoutineRunner?) throws {
        guard !planned.isEmpty else { return }
        guard let routines else {
            throw Routine.Refusal(problems: ["Routines are unavailable, so the pack's cannot be added"])
        }
        var added: [String] = []
        do {
            for routine in planned {
                try routines.put(routine)
                added.append(routine.id)
            }
        } catch {
            for id in added { _ = try? routines.remove(id) }
            throw error
        }
    }

    /// Puts each package's agent on the team, stopped, and writes the team.
    private func join(_ packages: [AgentPackage], as planned: [PackInstallPlan.AgentInstall],
                      appDefaultEffort: String?) {
        guard !packages.isEmpty else { return }
        let tuning = Self.startingTuning(config: project.loadConfig(), appDefaultEffort: appDefaultEffort)
        for (package, install) in zip(packages, planned) {
            var template = package.toAgentTemplate()
            template.systemPrompt = package.template.systemPrompt
            template.permissionMode = install.permissionMode
            var agent = template.instantiateAgent()
            agent.effort = tuning.effort
            agent.maxBudgetUSD = tuning.maxBudgetUSD
            orchestrator.addAgent(agent)
        }
        persistTeamConfig()
    }
}
