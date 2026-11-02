import KiteloopCore
import XCTest
@testable import Kiteloop

/// Coverage for the avatar an agent gets when nobody picked one. Both Settings
/// editors used to seed their field with the literal `bot_face_ui`, a name no
/// picker offers and no asset backs, which the sidebar then drew as that text
/// inside the avatar circle.
final class EditorAvatarDefaultTests: XCTestCase {

    // MARK: - Settings → Agents

    /// An untouched Avatar control stores no avatar at all, so the row falls
    /// through to the role-derived emoji.
    func testUntouchedCatalogEditorStoresNoAvatar() {
        let template = CatalogTemplateEditor.rebuiltTemplate(
            from: nil,
            name: "QA",
            model: "sonnet",
            description: "",
            group: "",
            systemPrompt: "",
            permissionMode: "acceptEdits",
            avatar: nil
        )
        XCTAssertNil(template.avatar)
        XCTAssertEqual(AgentAvatarView.defaultEmoji(for: template.name), "🐍")
    }

    /// Every role the sidebar has always drawn still derives the same emoji.
    func testRoleEmojiAreUnchanged() {
        let pairs: [String: String] = [
            "coder": "\u{1F916}", "backend": "\u{1F916}",
            "reviewer": "\u{1F989}",
            "researcher": "\u{1F52E}", "research": "\u{1F52E}",
            "frontend": "\u{1F3A8}",
            "components": "\u{1F9E9}",
            "infra": "\u{2694}\u{FE0F}", "devops": "\u{2694}\u{FE0F}", "operations": "\u{2694}\u{FE0F}",
            "security": "\u{1F6E1}\u{FE0F}", "enforcer": "\u{1F6E1}\u{FE0F}",
            "creative": "\u{1F9D9}\u{200D}\u{2642}\u{FE0F}", "designer": "\u{1F9D9}\u{200D}\u{2642}\u{FE0F}",
            "wireframe": "\u{1F9D9}\u{200D}\u{2642}\u{FE0F}",
            "qa": "\u{1F40D}", "tester": "\u{1F40D}", "test": "\u{1F40D}",
            "performance": "\u{26A1}", "optimizer": "\u{26A1}",
            "data": "\u{1F441}\u{FE0F}", "analytics": "\u{1F441}\u{FE0F}",
            "debug": "\u{1F41B}", "troubleshooter": "\u{1F41B}",
            "prompt tuner": "\u{1F9DD}\u{200D}\u{2642}\u{FE0F}", "prompt engineer": "\u{1F9DD}\u{200D}\u{2642}\u{FE0F}",
            "prd": "\u{1F985}", "product": "\u{1F985}", "manager": "\u{1F985}",
            "claude": "\u{1F3F0}"
        ]
        for (role, emoji) in pairs {
            XCTAssertEqual(AgentAvatarView.defaultEmoji(for: role), emoji, "role \(role)")
            XCTAssertEqual(AgentAvatarView.defaultEmoji(for: role.uppercased()), emoji, "role \(role) upper-cased")
        }
    }

    /// A name outside the role table still draws an emoji rather than text.
    func testUnknownRoleStillDrawsAnEmoji() {
        XCTAssertEqual(AgentAvatarView.defaultEmoji(for: "iOS Expert"), "👾")
        XCTAssertNotEqual(AgentAvatarView.defaultEmoji(for: "iOS Expert"), "bot_face_ui")
    }

    /// An avatar a user really chose is written through unchanged.
    func testCatalogEditorKeepsAChosenAvatar() {
        let template = CatalogTemplateEditor.rebuiltTemplate(
            from: AgentTemplate(id: "t1", name: "Reviewer", avatar: "🦉"),
            name: "Reviewer",
            model: "sonnet",
            description: "",
            group: "",
            systemPrompt: "",
            permissionMode: "plan",
            avatar: "🦉"
        )
        XCTAssertEqual(template.id, "t1")
        XCTAssertEqual(template.avatar, "🦉")
    }
}
