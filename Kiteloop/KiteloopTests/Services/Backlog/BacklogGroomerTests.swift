import XCTest
import KiteloopCore
@testable import Kiteloop

/// The groom pass's pure half: what it does with a one-shot reply, before any
/// UI or runtime is involved. `propose` takes only values and a runner
/// closure — the shape that kept two earlier attempts at this item from
/// reaching for `BacklogViewModel` directly — so every rule here is exercised
/// with a canned reply instead of a subprocess.
final class BacklogGroomerTests: XCTestCase {

    // MARK: - Fixtures

    private func item(id: String = "cache-index", verify: String? = nil,
                      size: ItemSize? = nil, needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: "Cache the index", verify: verify, status: .draft,
                    type: .local, size: size, needs: needs)
    }

    private func backlog(items: [BacklogItem] = []) -> BacklogFile {
        BacklogFile(project: "alpha", sections: [BacklogSection(name: "Now", items: items)])
    }

    /// A reply naming everything the gate needs, grounded against `groundedSources`.
    private let goodReply = """
        {"items": [{"id": "someone-elses-id", "title": "Someone else's title", "size": "s",
          "verify": "make test", "what": "The index is built once per run.",
          "how": "Hold it on the autopilot.",
          "validation": ["A queue of five items builds the index once"],
          "outOfScope": ["Persisting the index across launches"]}]}
        """

    private var groundedSources: GroundingCheck.Sources {
        GroundingCheck.Sources(pathExists: { _ in true }, definesSymbol: { _ in true },
                               resolvesExecutable: { _ in true })
    }

    private var ungroundedSources: GroundingCheck.Sources {
        GroundingCheck.Sources(pathExists: { _ in false }, definesSymbol: { _ in false },
                               resolvesExecutable: { _ in false })
    }

    // MARK: - The id and title are the item's, never the model's

    /// A proposal for `cache-index` must never be mistaken for one about
    /// another item, however the model's reply spells its own id and title —
    /// this is what keeps a proposal from landing on the wrong item's page,
    /// the failure a rejected pass at this item shipped once already.
    @MainActor
    func testProposalIDAndTitleAreForcedOntoTheItemNeverTheModelsReply() async throws {
        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertEqual(proposal.itemID, "cache-index")
        XCTAssertEqual(proposal.draft.id, "cache-index")
        XCTAssertEqual(proposal.draft.title, "Cache the index")
    }

    // MARK: - A reply with nothing usable is refused, not previewed

    @MainActor
    func testAnEmptyReplyThrows() async {
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in "   " })
            XCTFail("an empty reply must not produce a proposal")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    @MainActor
    func testAReplyWithNoUsableDraftThrows() async {
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in "{\"items\": []}" })
            XCTFail("a reply with no draft must not produce a proposal")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .noDraft)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    @MainActor
    func testAReplyMissingWhatTheDefinitionOfReadyNeedsThrowsNoDraft() async {
        let missingValidation = """
            {"items": [{"id": "a", "title": "t", "size": "s", "verify": "make",
              "what": "w", "how": "h", "validation": []}]}
            """
        do {
            _ = try await BacklogGroomer.propose(
                item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
                runOneShot: { _ in missingValidation })
            XCTFail("a draft missing Validation is not usable")
        } catch let error as BacklogGroomer.GroomError {
            XCTAssertEqual(error, .noDraft)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Readiness and grounding are judged on the groomed item

    @MainActor
    func testAWellFormedGroundedProposalMeetsBothGates() async throws {
        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertTrue(proposal.readiness.isReady, proposal.readiness.summary)
        XCTAssertTrue(proposal.grounding.isGrounded, proposal.grounding.summary)
    }

    /// The original item's own `needs:` still governs readiness — a draft that
    /// says nothing about dependencies must not silently clear one the line
    /// already carried.
    @MainActor
    func testAnUnmetDependencyOnTheOriginalItemLeavesTheProposalUnready() async throws {
        let waiting = item(needs: ["schema-migration"])
        let file = backlog(items: [waiting, item(id: "schema-migration")])

        let proposal = try await BacklogGroomer.propose(
            item: waiting, detail: nil, backlog: file, sources: groundedSources,
            runOneShot: { _ in goodReply })

        XCTAssertFalse(proposal.readiness.isReady)
        XCTAssertTrue(proposal.readiness.summary.contains("schema-migration"),
                      proposal.readiness.summary)
    }

    @MainActor
    func testAnUngroundedProposalFailsTheGroundingCheckButStillPreviews() async throws {
        let ungroundedReply = """
            {"items": [{"id": "a", "title": "t", "size": "s", "verify": "/bin/echo ok",
              "what": "Update `Services/NotAFile.swift` to do the thing.", "how": "Edit it.",
              "validation": ["It does the thing"]}]}
            """
        let proposal = try await BacklogGroomer.propose(
            item: item(), detail: nil, backlog: backlog(), sources: ungroundedSources,
            runOneShot: { _ in ungroundedReply })

        XCTAssertFalse(proposal.grounding.isGrounded)
        XCTAssertTrue(proposal.grounding.summary.contains("NotAFile.swift"),
                      proposal.grounding.summary)
    }

    // MARK: - The prompt carries an existing detail's Out of Scope and Premise

    /// A re-groom must not silently drop what the file already stated: only
    /// What, How and Validation were ever echoed back into the prompt, so a
    /// draft parked with an Out of Scope list or a Premise had both vanish the
    /// moment it was re-groomed.
    func testBuildPromptIncludesExistingOutOfScopeAndPremise() {
        let detail = BacklogItemDetail(
            id: "cache-index", title: "Cache the index", verifyCommands: [],
            acceptanceCriteria: ["It builds once"],
            outOfScope: ["Persisting the index across launches"],
            what: "The index is built once per run.", approach: "Hold it on the autopilot.",
            premise: ["The index is rebuilt on every run today"])

        let prompt = BacklogGroomer.buildPrompt(item: item(), detail: detail, backlog: backlog())

        XCTAssertTrue(prompt.contains("Existing Out of Scope:\n- Persisting the index across launches"),
                      prompt)
        XCTAssertTrue(prompt.contains("Existing Premise:\n- The index is rebuilt on every run today"),
                      prompt)
    }
}
