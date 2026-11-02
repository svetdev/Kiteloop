import XCTest
@testable import Kiteloop

/// What the catalog editor's Save writes back.
///
/// The Save button rebuilds the edited template field by field, so anything the
/// form does not show has to be carried off the template being edited. `tools`,
/// `denied`, `subscriptions` and `skills` always were; `mcpServers` and
/// `runtimeKind` were not, so editing a Copilot-backed entry's description
/// turned it into a Claude one and emptied its MCP allowlist.
@MainActor
final class CatalogTemplateEditorRebuildTests: XCTestCase {

    /// Shaped like the `copilot-critic` entry in `PredefinedTemplates`: a
    /// non-Claude runtime, a denied list and an MCP allowlist, none of which the
    /// form offers a control for.
    private func copilotCritic() -> AgentTemplate {
        AgentTemplate(
            id: "catalog-copilot-critic",
            name: "Copilot Critic",
            model: "copilot-gpt-4o",
            systemPrompt: "You are a plan critic powered by GitHub Copilot.",
            tools: [],
            denied: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
            permissionMode: "plan",
            subscriptions: ["plan.proposed"],
            mcpServers: ["kiteloop-tools", "github"],
            skills: ["review"],
            description: "Copilot-powered critic — reviews plans via structured debate",
            avatar: "🔍",
            group: "Review",
            runtimeKind: "copilot"
        )
    }

    private func rebuilt(
        from template: AgentTemplate?,
        name: String = "Copilot Critic",
        model: String = "copilot-gpt-4o",
        description: String = "Copilot-powered critic — reviews plans via structured debate",
        group: String = "Review",
        systemPrompt: String = "You are a plan critic powered by GitHub Copilot.",
        permissionMode: String = "plan",
        avatar: String = "🔍"
    ) -> AgentTemplate {
        CatalogTemplateEditor.rebuiltTemplate(
            from: template,
            name: name,
            model: model,
            description: description,
            group: group,
            systemPrompt: systemPrompt,
            permissionMode: permissionMode,
            avatar: avatar
        )
    }

    /// Editing only the description must leave the runtime and the allowlist alone.
    func testEditingTheDescriptionKeepsRuntimeKindAndMCPServers() {
        let source = copilotCritic()

        let saved = rebuilt(from: source, description: "Reviews plans and blocks the risky ones")

        XCTAssertEqual(saved.description, "Reviews plans and blocks the risky ones")
        XCTAssertEqual(saved.runtimeKind, "copilot")
        XCTAssertEqual(saved.mcpServers, ["kiteloop-tools", "github"])
    }

    /// The fields the form already preserved must keep being preserved, and the
    /// edited entry must stay the same entry.
    func testEveryFieldTheFormDoesNotEditIsCarriedThrough() {
        let source = copilotCritic()

        let saved = rebuilt(from: source)

        XCTAssertEqual(saved.id, "catalog-copilot-critic")
        XCTAssertEqual(saved.tools, [])
        XCTAssertEqual(saved.denied, source.denied)
        XCTAssertEqual(saved.subscriptions, ["plan.proposed"])
        XCTAssertEqual(saved.skills, ["review"])
    }

    /// The fields the form does edit are taken from the form, not the source.
    func testFormFieldsOverwriteTheSourceTemplate() {
        let saved = rebuilt(
            from: copilotCritic(),
            name: "Critic",
            model: "opus",
            group: "Quality",
            systemPrompt: "Be brief.",
            permissionMode: "acceptEdits",
            avatar: "🦉"
        )

        XCTAssertEqual(saved.name, "Critic")
        XCTAssertEqual(saved.model, "opus")
        XCTAssertEqual(saved.group, "Quality")
        XCTAssertEqual(saved.systemPrompt, "Be brief.")
        XCTAssertEqual(saved.permissionMode, "acceptEdits")
        XCTAssertEqual(saved.avatar, "🦉")
    }

    /// An emptied group field means "no group", not a group named "".
    func testAnEmptyGroupFieldBecomesNil() {
        XCTAssertNil(rebuilt(from: copilotCritic(), group: "").group)
    }

    /// A brand-new agent has no source template: it gets a fresh id, the
    /// starter tool list, and no runtime or allowlist of its own.
    func testANewTemplateGetsAFreshIDAndTheDefaultTools() {
        let first = rebuilt(from: nil, name: "Fresh")
        let second = rebuilt(from: nil, name: "Fresh")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertEqual(first.tools, ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "publish_event", "propose_memory"])
        XCTAssertEqual(first.mcpServers, [])
        XCTAssertNil(first.runtimeKind)
    }
}
