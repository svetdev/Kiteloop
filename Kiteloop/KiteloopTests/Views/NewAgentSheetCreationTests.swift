import XCTest
import KiteloopCore
@testable import Kiteloop

/// What New Agent's Create hands to `ProjectSession.addAgent`.
///
/// The sheet used to pass only the name, model, permission mode and avatar, so
/// an agent picked from the catalog came out as a generic developer. The rest
/// of the picked template has to travel with the sheet's edits.
@MainActor
final class NewAgentSheetCreationTests: XCTestCase {

    /// Every field differs from `addAgent`'s defaults.
    private func reviewer() -> AgentTemplate {
        AgentTemplate(
            id: "reviewer",
            name: "Reviewer",
            model: "opus",
            tools: ["Read", "Grep"],
            denied: ["Edit", "Write"],
            permissionMode: "plan",
            mcpServers: ["github"],
            skills: ["review"],
            avatar: "🔍",
            runtimeKind: "copilot"
        )
    }

    private func created(
        from template: AgentTemplate?,
        packagePrompt: String? = "You review diffs.",
        name: String = "Reviewer",
        model: String = "opus",
        permissionMode: String = "plan",
        avatar: String? = "🔍"
    ) -> NewAgentSheet.Creation {
        NewAgentSheet.creation(
            from: template, packagePrompt: packagePrompt,
            name: name, model: model, permissionMode: permissionMode, avatar: avatar
        )
    }

    func testCatalogTemplateCarriesItsToolsRuntimeMCPServersAndSkills() {
        let creation = created(from: reviewer())

        XCTAssertEqual(creation.tools, ["Read", "Grep"])
        XCTAssertEqual(creation.denied, ["Edit", "Write"])
        XCTAssertEqual(creation.runtimeKind, "copilot")
        XCTAssertEqual(creation.mcpServers, ["github"])
        XCTAssertEqual(creation.skills, ["review"])
    }

    func testCatalogTemplateTakesThePackagePrompt() {
        XCTAssertEqual(created(from: reviewer()).systemPrompt, "You review diffs.")
    }

    /// An empty package prompt is left nil, which `addAgent` turns into its
    /// default "senior developer" prompt.
    func testEmptyPackagePromptFallsBackToTheDefault() {
        XCTAssertNil(created(from: reviewer(), packagePrompt: "").systemPrompt)
        XCTAssertNil(created(from: reviewer(), packagePrompt: nil).systemPrompt)
    }

    func testSheetEditsOverrideTheTemplate() {
        let creation = created(
            from: reviewer(), name: "Critic", model: "sonnet",
            permissionMode: "acceptEdits", avatar: "🦉"
        )

        XCTAssertEqual(creation.name, "Critic")
        XCTAssertEqual(creation.model, "sonnet")
        XCTAssertEqual(creation.permissionMode, "acceptEdits")
        XCTAssertEqual(creation.avatar, "🦉")
    }

    /// Custom Agent leaves every template field nil, so `addAgent` applies its
    /// defaults: the default tools and prompt, no denied tools, no runtime.
    func testCustomAgentKeepsTheDefaults() {
        let creation = created(
            from: nil, packagePrompt: nil, name: "Agent", model: "sonnet",
            permissionMode: "acceptEdits", avatar: nil
        )

        XCTAssertEqual(
            creation,
            NewAgentSheet.Creation(name: "Agent", model: "sonnet", permissionMode: "acceptEdits", avatar: nil)
        )
        XCTAssertNil(creation.systemPrompt)
        XCTAssertNil(creation.tools)
        XCTAssertNil(creation.denied)
        XCTAssertNil(creation.runtimeKind)
    }

    // MARK: - The mode a new agent starts in

    /// The project's configured mode when there is one, else the app default.
    func testInitialModeIsTheProjectsConfiguredMode() {
        var config = ProjectConfig.default
        config.permissionMode = "plan"
        XCTAssertEqual(Agent.initialPermissionMode(projectConfig: config), "plan")
        XCTAssertEqual(Agent.initialPermissionMode(projectConfig: nil), Agent.defaultPermissionMode)
        config.permissionMode = ""
        XCTAssertEqual(Agent.initialPermissionMode(projectConfig: config), Agent.defaultPermissionMode)
    }

    /// Read off the project's own `config.json`; no project, or one that never
    /// saved a config, is the default.
    func testInitialModeIsReadFromTheProjectOnDisk() throws {
        let root = try makeTemporaryDirectory(prefix: "new-agent-mode")
        let project = KiteloopProject(rootURL: root)
        XCTAssertEqual(Agent.initialPermissionMode(forProjectAt: root), Agent.defaultPermissionMode)
        try project.ensureDirectoryExists()
        var config = ProjectConfig.default
        config.permissionMode = "acceptEdits"
        try project.saveConfig(config)

        XCTAssertEqual(Agent.initialPermissionMode(forProjectAt: root), "acceptEdits")
        XCTAssertEqual(Agent.initialPermissionMode(forProjectAt: nil), Agent.defaultPermissionMode)
    }

    /// Custom Agent and a catalog agent that names no mode of its own start in
    /// the project's mode; one that names a mode keeps it.
    func testThePickerStartsAtTheProjectsModeUnlessTheTemplateNamesOne() {
        XCTAssertEqual(NewAgentSheet.startingPermissionMode(for: nil, projectMode: "plan"), "plan")
        let unset = AgentTemplate(id: "unset", name: "Unset", model: "sonnet")
        XCTAssertEqual(NewAgentSheet.startingPermissionMode(for: unset, projectMode: "plan"), "plan")
        XCTAssertEqual(NewAgentSheet.startingPermissionMode(for: reviewer(), projectMode: "acceptEdits"), "plan")
    }

    /// A Custom Agent starts on the default the settings pages name: the
    /// project's model, else the app's, else the built-in. Empty is unset.
    func testACustomAgentStartsOnTheProjectThenAppThenBuiltInModel() {
        XCTAssertEqual(NewAgentSheet.startingModel(for: nil, appModel: "sonnet", projectModel: "haiku"), "haiku")
        XCTAssertEqual(NewAgentSheet.startingModel(for: nil, appModel: "sonnet", projectModel: nil), "sonnet")
        XCTAssertEqual(NewAgentSheet.startingModel(for: nil, appModel: "sonnet", projectModel: ""), "sonnet")
        XCTAssertEqual(NewAgentSheet.startingModel(for: nil, appModel: nil, projectModel: nil),
                       ModelCatalog.defaultModelID)
        XCTAssertEqual(NewAgentSheet.startingModel(for: nil, appModel: "", projectModel: ""),
                       ModelCatalog.defaultModelID)
    }

    /// A catalog package's own model stays explicit, whatever the defaults.
    func testATemplateStartsOnItsOwnModel() {
        XCTAssertEqual(NewAgentSheet.startingModel(for: reviewer(), appModel: "sonnet", projectModel: "haiku"),
                       ModelCatalog.normalize("opus"))
    }

    /// Edit Agent's note says what the project's setting does now: it is the
    /// mode new agents start in, not this agent's.
    func testTheEditorNoteNamesTheModeNewAgentsStartIn() {
        XCTAssertEqual(
            AgentEditorSheet.projectPermissionNote("plan"),
            "New agents in this project start in Plan (read-only). Chat only — an unattended run always uses auto mode.")
    }
}
