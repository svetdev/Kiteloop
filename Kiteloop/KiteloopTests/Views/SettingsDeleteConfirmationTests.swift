import XCTest
@testable import Kiteloop

/// The two Settings deletes that destroy something for real say what they are
/// about to destroy: the task agent by name and handle, the plugin by name and
/// the fact that its files leave the disk.
final class SettingsDeleteConfirmationTests: XCTestCase {

    func testTemplateMessageNamesTheAgentAndItsHandle() {
        let message = AgentCatalogView.deleteTemplateMessage(name: "Reviewer", handle: "reviewer")
        XCTAssertTrue(message.contains("Reviewer"))
        XCTAssertTrue(message.contains("@reviewer"))
        XCTAssertTrue(message.contains("can't be undone"))
    }

    func testTemplateMessageSaysItLeavesTheCatalog() {
        let message = AgentCatalogView.deleteTemplateMessage(name: "Data Analyst", handle: "data-analyst")
        XCTAssertTrue(message.contains("Data Analyst"))
        XCTAssertTrue(message.contains("catalog"))
    }

    func testPluginMessageNamesThePluginAndTheDisk() {
        let message = PluginManagerView.deletePluginMessage(names: ["cloudflare"])
        XCTAssertTrue(message.contains("cloudflare"))
        XCTAssertTrue(message.contains("the plugin "))
        XCTAssertTrue(message.contains("files from disk"))
        XCTAssertTrue(message.contains("can't be undone"))
    }

    func testPluginMessageForSeveralNamesEachOfThem() {
        let message = PluginManagerView.deletePluginMessage(names: ["cloudflare", "anthropic-skills"])
        XCTAssertTrue(message.contains("cloudflare"))
        XCTAssertTrue(message.contains("anthropic-skills"))
        XCTAssertTrue(message.contains("the plugins "))
        XCTAssertTrue(message.contains("their files from disk"))
    }
}
