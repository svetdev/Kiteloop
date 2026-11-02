import XCTest
@testable import Kiteloop

/// The Hooks panel's read of `.claude/settings.json`, and the merge it writes
/// back: everything the panel cannot represent survives a save untouched.
@MainActor
final class HookSettingsFileTests: XCTestCase {

    private func settings(_ json: String) throws -> [String: Any] {
        switch HookConfigView.classify(Data(json.utf8)) {
        case .parsed(let settings):
            return settings
        default:
            XCTFail("expected \(json) to parse")
            return [:]
        }
    }

    private func unreadableMessage(_ json: String) -> String? {
        if case .unreadable(let message) = HookConfigView.classify(Data(json.utf8)) { return message }
        return nil
    }

    private func roundTrip(_ json: String, edit: ([HookEntry]) -> [HookEntry] = { $0 }) throws -> [String: Any] {
        let original = try settings(json)
        let entries = HookConfigView.hookEntries(in: original)
        return HookConfigView.merged(edit(entries), into: original)
    }

    private func hooks(_ merged: [String: Any]) -> [String: Any] {
        merged["hooks"] as? [String: Any] ?? [:]
    }

    private func rules(_ merged: [String: Any], _ event: String) -> [[String: Any]] {
        hooks(merged)[event] as? [[String: Any]] ?? []
    }

    private func definitions(_ merged: [String: Any], _ event: String, rule: Int = 0) -> [[String: Any]] {
        rules(merged, event)[rule]["hooks"] as? [[String: Any]] ?? []
    }

    // MARK: - Classifying the bytes

    func testMissingFileIsAbsentNotUnreadable() {
        guard case .absent = HookConfigView.classify(nil) else {
            return XCTFail("a file that is not there is absent")
        }
    }

    func testBytesThatAreNotJSONAreUnreadable() {
        let message = unreadableMessage("{\"hooks\": ")
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("not valid JSON") == true, "\(message ?? "nil")")
    }

    func testTopLevelThatIsNotAnObjectIsUnreadable() {
        XCTAssertTrue(unreadableMessage("[1, 2]")?.contains("top level") == true)
    }

    func testHooksValueThatIsNotAnObjectIsUnreadable() {
        XCTAssertTrue(unreadableMessage("{\"hooks\": [\"PreToolUse\"]}")?.contains("hooks") == true)
    }

    func testSettingsWithoutAnyHooksKeyParsesToNoEntries() throws {
        let parsed = try settings("{\"permissions\": {\"allow\": []}}")
        XCTAssertTrue(HookConfigView.hookEntries(in: parsed).isEmpty)
    }

    // MARK: - What a row's event menu offers

    func testARowForAKnownEventOffersOnlyTheKnownEvents() {
        XCTAssertEqual(HookConfigView.eventChoices(for: "Stop"), HookConfigView.eventTypes)
        XCTAssertEqual(HookConfigView.eventChoices(for: "PreToolUse"), HookConfigView.eventTypes)
    }

    func testARowForAnUnlistedEventOffersItAfterTheKnownEvents() {
        let choices = HookConfigView.eventChoices(for: "SessionStart")
        XCTAssertEqual(choices, HookConfigView.eventTypes + ["SessionStart"])
        XCTAssertEqual(Set(choices).count, choices.count, "no duplicate: \(choices)")
    }

    func testAnEntryReadFromASessionStartRuleHasItsEventAmongItsChoices() throws {
        let parsed = try settings("""
        {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "a"}]}]}}
        """)
        let entry = try XCTUnwrap(HookConfigView.hookEntries(in: parsed).first)
        XCTAssertEqual(entry.event, "SessionStart")
        XCTAssertTrue(HookConfigView.eventChoices(for: entry.event).contains(entry.event))
    }

    // MARK: - What a save carries through

    func testUnmodelledTopLevelKeySurvivesASave() throws {
        let merged = try roundTrip("""
        {"permissions": {"allow": ["Bash"]}, "model": "opus",
         "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a"}]}]}}
        """)
        XCTAssertEqual(merged["model"] as? String, "opus")
        XCTAssertNotNil(merged["permissions"] as? [String: Any])
    }

    func testEventWithAShapeThePanelCannotReadSurvivesAnEditToAnotherEvent() throws {
        let merged = try roundTrip("""
        {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "a"}]}],
                   "SessionStart": {"legacy": true}}}
        """) { entries in
            entries.map { var entry = $0; entry.command = "edited"; return entry }
        }
        XCTAssertEqual((hooks(merged)["SessionStart"] as? [String: Any])?["legacy"] as? Bool, true)
        XCTAssertEqual(definitions(merged, "PreToolUse").first?["command"] as? String, "edited")
    }

    func testDefinitionWithoutATimeoutIsWrittenBackWithoutOne() throws {
        let merged = try roundTrip("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "gate.py"}]}]}}
        """)
        let def = definitions(merged, "Stop").first
        XCTAssertNil(def?["timeout"])
        XCTAssertEqual(def?["command"] as? String, "gate.py")
    }

    func testUnmodelledKeysOnARuleAndOnItsDefinitionSurviveASave() throws {
        let merged = try roundTrip("""
        {"hooks": {"PreToolUse": [{"matcher": "Bash", "note": "keep me",
                                   "hooks": [{"type": "command", "command": "a", "timeout": 10,
                                              "statusMessage": "checking"}]}]}}
        """)
        XCTAssertEqual(rules(merged, "PreToolUse").first?["note"] as? String, "keep me")
        XCTAssertEqual(definitions(merged, "PreToolUse").first?["statusMessage"] as? String, "checking")
    }

    func testRuleWithoutAMatcherIsNotGivenAnEmptyOne() throws {
        let merged = try roundTrip("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a"}]}]}}
        """)
        XCTAssertNil(rules(merged, "Stop").first?["matcher"])
    }

    func testRuleThePanelCouldNotReadIsKeptAtItsIndex() throws {
        let merged = try roundTrip("""
        {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": "not-an-array"},
                                  {"matcher": "Edit", "hooks": [{"type": "command", "command": "a"}]}]}}
        """)
        let kept = rules(merged, "PreToolUse")
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first?["hooks"] as? String, "not-an-array")
        XCTAssertEqual(kept.last?["matcher"] as? String, "Edit")
    }

    func testTwoDefinitionsUnderOneRuleStayOneRule() throws {
        let merged = try roundTrip("""
        {"hooks": {"PreToolUse": [{"matcher": "Bash",
                                   "hooks": [{"type": "command", "command": "a"},
                                             {"type": "command", "command": "b"}]}]}}
        """)
        XCTAssertEqual(rules(merged, "PreToolUse").count, 1)
        XCTAssertEqual(definitions(merged, "PreToolUse").compactMap { $0["command"] as? String }, ["a", "b"])
    }

    func testATypeThePanelDoesNotModelIsNotRewrittenAsCommand() throws {
        let merged = try roundTrip("""
        {"hooks": {"Stop": [{"hooks": [{"type": "future", "command": "a"}]}]}}
        """)
        XCTAssertEqual(definitions(merged, "Stop").first?["type"] as? String, "future")
    }

    // MARK: - What a save changes

    func testAnEditedTimeoutIsWrittenAndADeletedEntryDropsItsEvent() throws {
        let merged = try roundTrip("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a"}]}],
                   "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "b"}]}]}}
        """) { entries in
            entries.filter { $0.event == "Stop" }.map { var entry = $0; entry.timeout = 45; return entry }
        }
        XCTAssertEqual(definitions(merged, "Stop").first?["timeout"] as? Int, 45)
        XCTAssertNil(hooks(merged)["PostToolUse"])
    }

    func testAnAddedEntryMergesIntoAnEmptySettingsObject() {
        let added = HookEntry(event: "PreToolUse", matcher: "Bash", command: "echo hi", timeout: 10)
        let merged = HookConfigView.merged([added], into: [:])
        XCTAssertEqual(rules(merged, "PreToolUse").first?["matcher"] as? String, "Bash")
        let def = definitions(merged, "PreToolUse").first
        XCTAssertEqual(def?["type"] as? String, "command")
        XCTAssertEqual(def?["timeout"] as? Int, 10)
        XCTAssertEqual(def?["command"] as? String, "echo hi")
    }

    func testAnEditedMatcherSplitsThePairItSharedARuleWith() throws {
        let merged = try roundTrip("""
        {"hooks": {"PreToolUse": [{"matcher": "Bash",
                                   "hooks": [{"type": "command", "command": "a"},
                                             {"type": "command", "command": "b"}]}]}}
        """) { entries in
            entries.enumerated().map { index, entry in
                var entry = entry
                if index == 1 { entry.matcher = "Edit" }
                return entry
            }
        }
        XCTAssertEqual(rules(merged, "PreToolUse").count, 2)
        XCTAssertEqual(rules(merged, "PreToolUse").last?["matcher"] as? String, "Edit")
    }

    func testThisRepositoryOwnSettingsSurviveASaveUntouched() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: ".claude/settings.json"))
        guard case .parsed(let original) = HookConfigView.classify(data) else {
            return XCTFail("this repository's own settings should parse")
        }
        let merged = HookConfigView.merged(HookConfigView.hookEntries(in: original), into: original)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        )
    }
}
