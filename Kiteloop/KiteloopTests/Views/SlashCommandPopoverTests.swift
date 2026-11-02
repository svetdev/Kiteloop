import KiteloopCore
import XCTest
@testable import Kiteloop

/// The slash-command popover draws a bounded number of rows, and the input bar
/// keeps only those — so the arrow keys and Enter never reach a hidden command.
/// Esc, or a click away, then keeps a popover shut for as long as the token it
/// was dismissed on is still being edited.
final class SlashCommandPopoverTests: XCTestCase {

    private func skills(_ count: Int) -> [Skill] {
        (0..<count).map { index in
            Skill(
                id: "skill-\(index)",
                name: "skill\(index)",
                description: "Skill \(index)",
                isUserInvocable: true,
                argumentHint: nil,
                body: "",
                sourceURL: URL(fileURLWithPath: "/tmp/skill-\(index).md"),
                source: .project
            )
        }
    }

    func testRowLimitIsEight() {
        XCTAssertEqual(SlashCommandPopover.rowLimit, 8)
    }

    func testMoreMatchesThanTheLimitKeepsTheFirstRowsInOrder() {
        let matches = skills(12)
        XCTAssertEqual(SlashCommandPopover.drawnSkills(from: matches), Array(matches[0..<8]))
    }

    func testFewerMatchesThanTheLimitKeepsThemAll() {
        let matches = skills(3)
        XCTAssertEqual(SlashCommandPopover.drawnSkills(from: matches), matches)
    }

    func testNoMatchesDrawsNothing() {
        XCTAssertEqual(SlashCommandPopover.drawnSkills(from: []), [])
    }

    // MARK: - Built-in commands come first

    private func skill(named name: String) -> Skill {
        Skill(
            id: "skill-\(name)",
            name: name,
            description: "Skill \(name)",
            isUserInvocable: true,
            argumentHint: nil,
            body: "",
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).md"),
            source: .project
        )
    }

    func testAnEmptyPrefixListsEveryBuiltInCommand() {
        let names = SlashCommandPopover.mergedMatches(prefix: "", skills: []).map(\.name)
        XCTAssertEqual(names, [
            "clear", "fork", "compact", "recap", "model", "mode", "effort", "thinking", "fast",
            "cost", "context", "doctor", "history", "loop", "goal", "undo", "branch",
        ])
    }

    func testEveryBuiltInCommandHasADescription() {
        XCTAssertTrue(SlashCommandPopover.builtInCommands.allSatisfy { !$0.description.isEmpty })
    }

    func testAnEmptyPrefixPutsTheBuiltInsBeforeAnySkill() {
        let names = SlashCommandPopover.mergedMatches(prefix: "", skills: [skill(named: "deploy")]).map(\.name)
        XCTAssertEqual(names.count, 18)
        XCTAssertEqual(names.last, "deploy")
    }

    func testAPrefixNarrowsTheBuiltIns() {
        XCTAssertEqual(SlashCommandPopover.mergedMatches(prefix: "mod", skills: []).map(\.name), ["model", "mode"])
    }

    func testAPrefixMatchesTheBuiltInsCaseInsensitively() {
        XCTAssertEqual(SlashCommandPopover.mergedMatches(prefix: "CO", skills: []).map(\.name),
                       ["compact", "cost", "context"])
    }

    func testASkillNamedLikeABuiltInIsLeftOutAndOthersFollowTheBuiltIns() {
        let names = SlashCommandPopover.mergedMatches(
            prefix: "", skills: [skill(named: "clear"), skill(named: "deploy")]
        ).map(\.name)
        XCTAssertEqual(names.filter { $0 == "clear" }.count, 1)
        XCTAssertEqual(names.first, "clear")
        XCTAssertEqual(names.last, "deploy")
    }

    // MARK: - A local agent is not offered the Claude-only commands

    private let claudeOnly = ["fork", "compact", "mode", "effort", "thinking", "fast"]

    func testAnOllamaAgentIsOfferedOnlyTheCommandsThatWorkOnIt() {
        let names = SlashCommandPopover.mergedMatches(prefix: "", skills: [], runtime: .ollama).map(\.name)
        XCTAssertEqual(names, [
            "clear", "recap", "model", "cost", "context", "doctor", "history", "loop", "goal", "undo", "branch",
        ])
        XCTAssertTrue(claudeOnly.allSatisfy { !names.contains($0) })
    }

    func testACopilotAgentIsOfferedOnlyTheCommandsThatWorkOnIt() {
        let names = SlashCommandPopover.mergedMatches(prefix: "", skills: [], runtime: .copilot).map(\.name)
        XCTAssertEqual(names, [
            "clear", "recap", "model", "cost", "context", "doctor", "history", "loop", "goal", "undo", "branch",
        ])
    }

    func testAClaudeAgentIsOfferedEveryBuiltInCommand() {
        XCTAssertEqual(
            SlashCommandPopover.mergedMatches(prefix: "", skills: [], runtime: .claude).map(\.name),
            SlashCommandPopover.mergedMatches(prefix: "", skills: []).map(\.name))
        XCTAssertEqual(SlashCommandPopover.mergedMatches(prefix: "", skills: [], runtime: .claude).count, 17)
    }

    func testASkillNamedLikeAHiddenBuiltInStaysLeftOutOnALocalAgent() {
        let names = SlashCommandPopover.mergedMatches(
            prefix: "", skills: [skill(named: "compact"), skill(named: "deploy")], runtime: .ollama
        ).map(\.name)
        XCTAssertFalse(names.contains("compact"))
        XCTAssertEqual(names.last, "deploy")
    }

    // MARK: - Esc keeps a popover shut for the token it was dismissed on

    func testTypingOnInsideTheDismissedCommandTokenKeepsThePopoverShut() {
        XCTAssertTrue(InputBar.isPopoverStillDismissed(token: "/revi", dismissedOn: "/rev"))
    }

    func testBackspacingInsideTheDismissedCommandTokenKeepsThePopoverShut() {
        XCTAssertTrue(InputBar.isPopoverStillDismissed(token: "/re", dismissedOn: "/rev"))
    }

    func testACommandTokenThatDivergesOpensThePopoverAgain() {
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "/gr", dismissedOn: "/rev"))
    }

    func testAnEmptyTokenOpensThePopoverAgain() {
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "", dismissedOn: "/rev"))
    }

    func testAMentionTokenIsJudgedTheSameWay() {
        XCTAssertTrue(InputBar.isPopoverStillDismissed(token: "@alic", dismissedOn: "@ali"))
        XCTAssertTrue(InputBar.isPopoverStillDismissed(token: "@al", dismissedOn: "@ali"))
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "@bob", dismissedOn: "@ali"))
    }

    func testNothingDismissedLeavesEveryTokenOpen() {
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "/", dismissedOn: nil))
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "@", dismissedOn: nil))
        XCTAssertFalse(InputBar.isPopoverStillDismissed(token: "/rev", dismissedOn: nil))
    }
}
