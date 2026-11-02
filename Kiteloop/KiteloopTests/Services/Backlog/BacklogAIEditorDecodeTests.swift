import XCTest
@testable import Kiteloop
import KiteloopCore

/// Decoding the model's proposed backlog edits — and, the point of these cases,
/// what happens to the ones that can't be decoded.
///
/// Every op the mapper couldn't read used to vanish: the preview list was
/// silently shorter than the proposal, the operator approved it believing it was
/// whole, and a reply whose ops *all* failed read as `The assistant didn't
/// propose any changes` — which states the opposite of what happened. So each
/// case here asserts both halves: the ops that survive, and the phrase naming
/// what didn't and why.
@MainActor
final class BacklogAIEditorDecodeTests: XCTestCase {

    // MARK: - Helpers

    /// The ops' summaries, which is what the preview lists.
    private func summaries(_ proposal: BacklogAIEditor.Proposal) -> [String] {
        proposal.ops.map(\.summary)
    }

    /// The `- {…}` op bullets `buildPrompt` lists, each trimmed to its balanced
    /// JSON object — the parenthetical note after `moveItemBefore`'s bullet is
    /// prose, not part of the object, so it stops at the closing brace rather
    /// than swallowing the line.
    private func jsonObjectBullets(in prompt: String) -> [String] {
        prompt.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- {"), let open = trimmed.firstIndex(of: "{") else { return nil }
            var depth = 0
            for index in trimmed[open...].indices {
                switch trimmed[index] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(trimmed[open...index]) }
                default: break
                }
            }
            return nil
        }
    }

    // MARK: - The valid ops still decode

    func testDecodesEveryOpKind() throws {
        let reply = """
        [{"op":"addEpic","name":"Platform","description":"The engine room"},
         {"op":"addItem","epic":"Platform","title":"Cache the index"},
         {"op":"updateItem","id":"kl-001","title":"Renamed"},
         {"op":"setStatus","id":"kl-002","status":"in-review"},
         {"op":"moveItem","id":"kl-003","toEpic":"Platform"},
         {"op":"moveItemBefore","id":"kl-005","before":"kl-006"},
         {"op":"removeItem","id":"kl-004"},
         {"op":"removeEpic","name":"Old"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(proposal.ops.count, 8)
        XCTAssertTrue(proposal.unreadable.isEmpty, "nothing here is unreadable: \(proposal.unreadable)")
        XCTAssertEqual(summaries(proposal).first, "Add epic “Platform”")
        XCTAssertEqual(summaries(proposal)[3], "Set kl-002 to In Review")
    }

    // MARK: - Mixed valid and invalid

    func testKeepsValidOpsAndReportsEachDroppedOne() throws {
        let reply = """
        [{"op":"addItem","epic":"Platform","title":"Cache the index"},
         {"op":"frobnicate","id":"kl-001"},
         {"op":"setStatus","id":"kl-002","status":"pending"},
         {"op":"removeItem","id":"kl-003"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), [
            "Add item “Cache the index” to “Platform”",
            "Remove item kl-003"
        ])
        XCTAssertEqual(proposal.unreadable.count, 2)
        // Position, so two ops of the same kind in one reply are tellable apart.
        XCTAssertTrue(proposal.unreadable[0].hasPrefix("Change 2:"), proposal.unreadable[0])
        XCTAssertTrue(proposal.unreadable[1].hasPrefix("Change 3:"), proposal.unreadable[1])
    }

    // MARK: - moveItemBefore

    func testMoveItemBeforeWithBeforeProducesTheSummaryItSpells() throws {
        let proposal = try BacklogAIEditor.decodeOps(
            from: #"[{"op":"moveItemBefore","id":"kl-001","before":"kl-002"}]"#)

        XCTAssertEqual(summaries(proposal), ["Move kl-001 in front of kl-002"])
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    func testMoveItemBeforeWithoutBeforeIsTheTopOfEpicSummary() throws {
        let proposal = try BacklogAIEditor.decodeOps(
            from: #"[{"op":"moveItemBefore","id":"kl-001"}]"#)

        XCTAssertEqual(summaries(proposal), ["Move kl-001 to the top of its epic"])
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    func testMoveItemBeforeWithoutIdNamesTheMissingField() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"moveItemBefore","before":"kl-002"}]"#)

        XCTAssertTrue(proposal.ops.isEmpty)
        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("`moveItemBefore` is missing `id`"), phrase)
    }

    // MARK: - What each phrase names

    func testUnrecognisedOpIsNamedInItsPhrase() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"frobnicate","id":"kl-001"}]"#)

        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("frobnicate"), phrase)
        XCTAssertTrue(phrase.contains("unrecognised op"), phrase)
        // And what to write instead, rather than only that it was wrong.
        XCTAssertTrue(phrase.contains("setStatus"), phrase)
    }

    func testUnrecognisedStatusNamesTheFieldAndTheValue() throws {
        let proposal = try BacklogAIEditor.decodeOps(
            from: #"[{"op":"setStatus","id":"kl-001","status":"pending"}]"#)

        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("`status`"), phrase)
        XCTAssertTrue(phrase.contains("pending"), phrase)
        // And the statuses it could have written, rather than only that it was wrong.
        XCTAssertTrue(phrase.contains("in-review"), phrase)
        // A bad value is a different fix from a missing field, and says so.
        XCTAssertFalse(phrase.contains("missing"), phrase)
    }

    func testAddItemWithoutTitleNamesTheMissingField() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"addItem","epic":"Platform"}]"#)

        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("`addItem`"), phrase)
        XCTAssertTrue(phrase.contains("missing `title`"), phrase)
        // `epic` was given, so it isn't named as missing.
        XCTAssertFalse(phrase.contains("`epic`"), phrase)
    }

    func testMissingStatusFieldReadsAsMissingRatherThanUnrecognised() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"setStatus","id":"kl-001"}]"#)

        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("`setStatus` is missing `status`"), phrase)
    }

    func testEveryAbsentFieldIsNamed() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"updateItem"}]"#)

        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("missing `id` and `title`"), phrase)
    }

    /// The ops that accept an alternative spelling still take it — a phrase for
    /// an op that was perfectly readable is as misleading as a silent drop.
    func testAlternativeFieldSpellingsAreNotReportedAsMissing() throws {
        let reply = """
        [{"op":"addEpic","epic":"Platform"},
         {"op":"moveItem","id":"kl-001","epic":"Platform"},
         {"op":"removeEpic","epic":"Old"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(proposal.ops.count, 3)
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    // MARK: - Elements the JSON decoder itself refuses

    /// The decode used to be `[RawOp]` as a unit, so one element without an `op`
    /// key threw and took every other proposed change with it — the operator saw
    /// a raw Swift decoding sentence and none of the work the model had done.
    func testElementWithoutAnOpKeyCostsOnlyItself() throws {
        let reply = """
        [{"op":"addItem","epic":"Platform","title":"Cache the index"},
         {"id":"kl-001","title":"Renamed"},
         {"op":"removeItem","id":"kl-002"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), [
            "Add item “Cache the index” to “Platform”",
            "Remove item kl-002"
        ])
        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertEqual(proposal.unreadable.count, 1)
        XCTAssertTrue(phrase.hasPrefix("Change 2:"), phrase)
        XCTAssertTrue(phrase.contains("no `op` field"), phrase)
        // And what it could have written, as an unrecognised op gets.
        XCTAssertTrue(phrase.contains("updateItem"), phrase)
    }

    func testWrongTypedFieldCostsOnlyItsOwnChange() throws {
        let reply = """
        [{"op":"addEpic","name":"Platform"},
         {"op":"updateItem","id":"kl-001","title":5},
         {"op":"removeItem","id":"kl-002"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Add epic “Platform”", "Remove item kl-002"])
        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.hasPrefix("Change 2:"), phrase)
        // The op is named even though no `RawOp` survived to name it, and so is
        // the field — the reply is what has to be fixed.
        XCTAssertTrue(phrase.contains("`updateItem`"), phrase)
        XCTAssertTrue(phrase.contains("`title`"), phrase)
        XCTAssertTrue(phrase.contains("isn't text"), phrase)
    }

    /// An element that isn't an object at all says so, rather than naming a field
    /// that was never there.
    func testElementThatIsNotAnObjectIsReportedAsSuch() throws {
        let proposal = try BacklogAIEditor.decodeOps(
            from: #"[{"op":"removeItem","id":"kl-001"},"just do it"]"#)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.hasPrefix("Change 2:"), phrase)
        XCTAssertTrue(phrase.contains("isn't a JSON object"), phrase)
    }

    /// A structurally malformed element and one the mapper refused are the same
    /// kind of finding to the operator, so they are numbered in one sequence.
    func testDecodeAndMapFailuresShareOnePhraseSequence() throws {
        let reply = """
        [{"title":"no op here"},
         {"op":"frobnicate"},
         {"op":"removeItem","id":"kl-001"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        XCTAssertEqual(proposal.unreadable.count, 2)
        XCTAssertTrue(proposal.unreadable[0].hasPrefix("Change 1:"), proposal.unreadable[0])
        XCTAssertTrue(proposal.unreadable[1].hasPrefix("Change 2:"), proposal.unreadable[1])
    }

    /// A reply that is *all* malformed reaches the operator as the sentence
    /// written for that case, not as `The data couldn't be read…`.
    func testEveryElementMalformedIsAllOpsUnreadableRatherThanADecoderMessage() throws {
        let reply = """
        [{"id":"kl-001"},
         {"op":"setStatus","id":"kl-002","status":7}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertTrue(proposal.ops.isEmpty)
        XCTAssertEqual(proposal.unreadable.count, 2)

        let message = BacklogAIEditor.EditorError
            .allOpsUnreadable(proposal.unreadable).localizedDescription
        XCTAssertTrue(message.contains("proposed 2 changes and none of them could be read"), message)
        XCTAssertFalse(message.contains("couldn't be read."), "not the Foundation decoding sentence: \(message)")
    }

    /// A null where a string belongs is a different fix from an absent key, and
    /// the phrase says which one happened.
    func testNullOpReadsAsNullRatherThanMissing() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":null,"id":"kl-001"}]"#)

        XCTAssertTrue(proposal.ops.isEmpty)
        let phrase = try XCTUnwrap(proposal.unreadable.first)
        XCTAssertTrue(phrase.contains("null `op`"), phrase)
    }

    // MARK: - All dropped vs. nothing proposed

    func testEmptyArrayProposesNothingRatherThanFailingToRead() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: "[]")

        XCTAssertTrue(proposal.ops.isEmpty)
        XCTAssertTrue(proposal.unreadable.isEmpty, "a literal [] is the model saying no change is needed")
    }

    func testEveryOpFailingLeavesNoOpsButKeepsTheReasons() throws {
        let reply = """
        [{"op":"frobnicate"},
         {"op":"setStatus","id":"kl-001","status":"pending"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertTrue(proposal.ops.isEmpty)
        XCTAssertEqual(proposal.unreadable.count, 2, "an empty ops list here is not an empty proposal")
    }

    func testAllUnreadableErrorSaysTheReplyCouldNotBeRead() {
        let message = BacklogAIEditor.EditorError
            .allOpsUnreadable(["Change 1: `setStatus` is missing `status`."])
            .localizedDescription

        XCTAssertTrue(message.contains("couldn't be read"), message)
        // The reason travels with the error, not just the fact that there was one.
        XCTAssertTrue(message.contains("Change 1:"), message)
        // The wording a genuine `[]` gets — the two must not read alike.
        XCTAssertFalse(message.contains("didn't propose any changes"), message)
    }

    func testAllUnreadableErrorCountsTheChanges() {
        let message = BacklogAIEditor.EditorError
            .allOpsUnreadable(["Change 1: a.", "Change 2: b.", "Change 3: c."])
            .localizedDescription

        XCTAssertTrue(message.contains("proposed 3 changes"), message)
        XCTAssertTrue(message.contains("none of them could be read"), message)
    }

    // MARK: - What the preview is handed

    /// The preview reads its unreadable count off the phase, so the phase has to
    /// carry it alongside the ops rather than the ops alone.
    func testReviewPhaseCarriesTheUnreadableOpsBesideTheOnesItWillApply() throws {
        let proposal = try BacklogAIEditor.decodeOps(
            from: #"[{"op":"removeItem","id":"kl-001"},{"op":"frobnicate"}]"#)
        let phase = BacklogAIEditor.Phase.review(proposal.ops, unreadable: proposal.unreadable)

        guard case .review(let ops, let unreadable) = phase else {
            return XCTFail("expected a review phase")
        }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(unreadable.count, 1)
    }

    // MARK: - The failures that predate this

    func testEmptyReplyStillThrows() {
        XCTAssertThrowsError(try BacklogAIEditor.decodeOps(from: "   ")) { error in
            XCTAssertEqual((error as? BacklogAIEditor.EditorError)?.errorDescription,
                           BacklogAIEditor.EditorError.emptyResponse.errorDescription)
        }
    }

    func testReplyWithNoJSONArrayStillThrows() {
        XCTAssertThrowsError(try BacklogAIEditor.decodeOps(from: "I couldn't work out what you meant.")) { error in
            XCTAssertEqual((error as? BacklogAIEditor.EditorError)?.errorDescription,
                           BacklogAIEditor.EditorError.noJSON.errorDescription)
        }
    }

    /// Prose or fences around the array are still tolerated — this decode path
    /// is unchanged, and the unreadable list must not swallow that tolerance.
    func testFencedReplyStillDecodes() throws {
        let reply = """
        Here you go:
        ```json
        [{"op":"removeItem","id":"kl-001"}]
        ```
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        XCTAssertTrue(proposal.unreadable.isEmpty)
    }

    func testBareArrayStillDecodes() throws {
        let proposal = try BacklogAIEditor.decodeOps(from: #"[{"op":"removeItem","id":"kl-001"}]"#)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        XCTAssertTrue(proposal.unreadable.isEmpty)
    }

    // MARK: - Brackets in the prose around the array

    /// The scan ran from the first `[` to the last `]`, so a bracket in a
    /// sentence *after* the array was swallowed into the slice and the decode
    /// failed — one aside about an item the model left alone cost the operator
    /// every change it had proposed.
    func testBracketInTheProseAfterTheArrayDoesNotSwallowTheProposal() throws {
        let reply = """
        [{"op":"removeItem","id":"kl-001"}]
        I left kl-002 [WIP] alone, since you didn't ask about it.
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    /// And the same sentence written *before* the array, where the stray `[`
    /// opened the slice early.
    func testBracketInTheProseBeforeTheArrayDoesNotSwallowTheProposal() throws {
        let reply = """
        I left kl-002 [WIP] alone, since you didn't ask about it. Here are the changes:
        [{"op":"removeItem","id":"kl-001"}]
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Remove item kl-001"])
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    /// A bracket inside an op's own string value is part of the title, not a
    /// delimiter: the scan tracks quoting, so it neither ends the slice early
    /// nor arrives in the preview mangled.
    func testBracketInsideAnOpsStringValueSurvivesIntoThePreviewedOp() throws {
        let reply = """
        Here you go:
        [{"op":"addItem","epic":"Platform","title":"Cache [index] lookups"}]
        Nothing else changed [as requested].
        """
        let proposal = try BacklogAIEditor.decodeOps(from: reply)

        XCTAssertEqual(summaries(proposal), ["Add item “Cache [index] lookups” to “Platform”"])
        XCTAssertTrue(proposal.unreadable.isEmpty, "\(proposal.unreadable)")
    }

    /// Balanced brackets alone aren't an array — prose that has them and no JSON
    /// in it is still a reply with nothing to apply, and says so.
    func testProseWithBracketsButNoArrayStillThrows() {
        let reply = "I couldn't work out what you meant — kl-001 [WIP] is the only one I could see."
        XCTAssertThrowsError(try BacklogAIEditor.decodeOps(from: reply)) { error in
            XCTAssertEqual((error as? BacklogAIEditor.EditorError)?.errorDescription,
                           BacklogAIEditor.EditorError.noJSON.errorDescription)
        }
    }

    // MARK: - The prompt's own op bullets

    /// `buildPrompt`'s menu is what the model learns the op shapes from — a
    /// bullet that isn't a well-formed object, or an op named twice, teaches the
    /// model something the mapper can't then read back. Every bullet is parsed
    /// on its own and checked against `knownOps`, the list `map` actually reads.
    func testEveryPromptBulletIsOneObjectNamingAKnownOpExactlyOnce() throws {
        let backlog = BacklogFile(project: "Kiteloop", sections: [])
        let prompt = BacklogAIEditor.buildPrompt(instruction: "move kl-001 to Platform", backlog: backlog)

        let bullets = jsonObjectBullets(in: prompt)
        XCTAssertFalse(bullets.isEmpty, "expected at least one op bullet in the prompt")

        var opsSeen: [String] = []
        for bullet in bullets {
            guard let data = bullet.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("bullet is not a well-formed JSON object: \(bullet)")
                continue
            }
            guard let op = object["op"] as? String else {
                XCTFail("bullet has no `op` field: \(bullet)")
                continue
            }
            XCTAssertTrue(BacklogAIEditor.knownOps.contains(op), "“\(op)” isn't in knownOps: \(bullet)")
            opsSeen.append(op)
        }

        for op in BacklogAIEditor.knownOps {
            XCTAssertEqual(opsSeen.filter { $0 == op }.count, 1,
                            "“\(op)” should appear in exactly one bullet, appeared in \(opsSeen.filter { $0 == op }.count)")
        }
    }

    // MARK: - The preview line reads against the backlog

    private let previewFixture = BacklogParser.parse("""
    # Demo Backlog

    ## Epic: Old

    - [ ] kl-001 | Cache the index | ready | size: S
    - [ ] kl-002 | Retry the upload | ready | size: S
    - [ ] kl-003 | Trim the log | ready | size: S

    ## Epic: Platform

    """)

    func testRemovingAnEpicSaysHowManyItemsGoWithIt() {
        XCTAssertEqual(BacklogEditOp.removeEpic(name: "Old").previewLine(in: previewFixture),
                       "Remove epic “Old” and its 3 items")
    }

    func testAnEmptyEpicRemovalKeepsThePlainSummary() {
        XCTAssertEqual(BacklogEditOp.removeEpic(name: "Platform").previewLine(in: previewFixture),
                       "Remove epic “Platform”")
    }

    func testEachItemOpNamesTheItemsTitleBesideItsID() {
        let ops: [BacklogEditOp] = [
            .removeItem(id: "kl-002"),
            .updateItem(id: "kl-002", title: "Renamed"),
            .setStatus(id: "kl-002", status: .done),
            .moveItem(id: "kl-002", toEpic: "Platform"),
            .moveItemBefore(id: "kl-002", before: "kl-001"),
        ]
        for op in ops {
            let line = op.previewLine(in: previewFixture)
            XCTAssertTrue(line.contains("kl-002 “Retry the upload”"), line)
        }
        XCTAssertEqual(BacklogEditOp.removeItem(id: "kl-002").previewLine(in: previewFixture),
                       "Remove item kl-002 “Retry the upload”")
    }

    func testAnIDOrEpicTheBacklogDoesNotHoldKeepsThePlainSummary() {
        let ops: [BacklogEditOp] = [
            .removeEpic(name: "Gone"),
            .removeItem(id: "kl-999"),
            .updateItem(id: "kl-999", title: "Renamed"),
            .setStatus(id: "kl-999", status: .done),
            .moveItem(id: "kl-999", toEpic: "Platform"),
            .moveItemBefore(id: "kl-999", before: nil),
        ]
        for op in ops {
            XCTAssertEqual(op.previewLine(in: previewFixture), op.summary)
            XCTAssertEqual(op.previewLine(in: nil), op.summary)
        }
    }

    func testOnlyAdditionsCountAsAdditions() {
        XCTAssertTrue(BacklogEditOp.addEpic(name: "New", description: nil).isAddition)
        XCTAssertTrue(BacklogEditOp.addItem(epic: "Old", title: "New").isAddition)
        XCTAssertFalse(BacklogEditOp.updateItem(id: "kl-001", title: "Renamed").isAddition)
        XCTAssertFalse(BacklogEditOp.setStatus(id: "kl-001", status: .done).isAddition)
        XCTAssertFalse(BacklogEditOp.moveItem(id: "kl-001", toEpic: "Platform").isAddition)
        XCTAssertFalse(BacklogEditOp.removeItem(id: "kl-001").isAddition)
    }
}
