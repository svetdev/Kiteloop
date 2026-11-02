import XCTest
@testable import KiteloopCore

final class CoordinatorActionTests: XCTestCase {

    // MARK: - Bounds: filing new work

    private func draft(id: String = "new-item", title: String = "A new item",
                       size: ItemSize? = .m, verify: String? = "swift build",
                       what: String = "The outcome.", how: String = "Touch these files.",
                       validation: [String] = ["It works"],
                       outOfScope: [String] = ["Everything else"]) -> CoordinatorAction.FiledItemDraft {
        .init(id: id, title: title, epic: "Now", size: size, verify: verify,
              what: what, how: how, validation: validation, outOfScope: outOfScope)
    }

    func testFiledItemAllowsANewWellFormedDraft() {
        XCTAssertNil(CoordinatorBounds.filedItemRejection(draft: draft(), existingIDs: ["task-1"]))
    }

    /// The action files new work only — an id that exists is the one way it
    /// could reach an existing item's status or text, so it never gets there.
    func testFiledItemRejectsAnIDThatAlreadyExists() {
        let reason = CoordinatorBounds.filedItemRejection(draft: draft(id: "task-1"),
                                                          existingIDs: ["task-1"])
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("regroom") ?? false, "Points at the verb that does edit items")
    }

    /// The id becomes `backlog/<id>.md`, so anything that could escape that
    /// directory — or name a hidden file — is refused before any write.
    func testFiledItemRejectsUnsafeIDs() {
        for bad in ["../../etc/passwd", "a/b", ".hidden", "with space", "quote\"d", "a..b"] {
            XCTAssertNotNil(CoordinatorBounds.filedItemRejection(draft: draft(id: bad), existingIDs: []),
                            "\(bad) is not a safe file name")
        }
    }

    func testFiledItemRejectsMissingIDOrTitle() {
        XCTAssertNotNil(CoordinatorBounds.filedItemRejection(draft: draft(id: "   "), existingIDs: []))
        XCTAssertNotNil(CoordinatorBounds.filedItemRejection(draft: draft(title: "  \n "), existingIDs: []))
    }

    // MARK: - The self-check that picks the filing status

    func testGroomedDraftFilesAsReady() {
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft()), .ready)
    }

    func testUnderGroomedDraftFilesAsDraftNotReady() {
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(what: "")), .draft)
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(how: "")), .draft)
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(validation: [])), .draft)
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(size: nil)), .draft)
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(size: .l)), .draft,
                       "L is too large to run unattended")
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(verify: nil)), .draft)
    }

    /// A drafted item with no `verify:` still inherits the file's default once
    /// written, so the self-check has to judge what will actually land.
    func testDraftWithoutVerifyInheritsTheBacklogDefault() {
        XCTAssertEqual(CoordinatorAction.FiledItemDraft.filingStatus(for: draft(verify: nil),
                                                          verifyDefault: "swift build"), .ready)
    }

    // MARK: - The drafted detail file

    /// The whole point of writing `backlog/<id>.md` is that the pickup gate
    /// reads it back. Round-trip it through the real parser.
    func testDetailMarkdownRoundTripsThroughTheParser() throws {
        let d = draft(validation: ["First criterion", "Second criterion"],
                      outOfScope: ["Renaming things", "The other epic"])
        let parsed = try XCTUnwrap(BacklogParser.parseDetail(d.detailMarkdown, fallbackID: d.id))

        XCTAssertEqual(parsed.id, "new-item")
        XCTAssertEqual(parsed.title, "A new item")
        XCTAssertEqual(parsed.size, "M")
        XCTAssertEqual(parsed.verifyCommands.map(\.cmd), ["swift build"])
        XCTAssertEqual(parsed.what, "The outcome.")
        XCTAssertEqual(parsed.approach, "Touch these files.")
        XCTAssertEqual(parsed.acceptanceCriteria, ["First criterion", "Second criterion"])
        XCTAssertEqual(parsed.outOfScope, ["Renaming things", "The other epic"])
        XCTAssertTrue(DefinitionOfReady.evaluate(item: d.item(status: .ready), detail: parsed).isReady)
    }

    /// Frontmatter and backlog lines are line-oriented; a newline the model put
    /// in a title would otherwise split the file into nonsense.
    func testMultiLineFieldsAreFlattenedBeforeWriting() {
        let d = draft(id: "an-id", title: "Title\nwith a break")
        XCTAssertEqual(d.item(status: .ready).title, "Title with a break")
        XCTAssertTrue(d.detailMarkdown.contains("title: Title with a break"))
    }
}
