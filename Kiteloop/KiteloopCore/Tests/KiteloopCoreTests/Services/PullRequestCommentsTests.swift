import XCTest
@testable import KiteloopCore

/// The decisions behind the one pass over a pull request's review threads: how
/// `gh`'s GraphQL answer is read, what the worker is asked, which of its
/// dispositions are acted on, and what the item's Notes and the human's summons
/// are told.
///
/// All pure, for the reason `PullRequestCommentsTests`' sibling
/// `PullRequestChecksTests` gives: a real pull request needs a GitHub account, a
/// network and a bot that will comment on cue, while the reading and the
/// deciding — which is where this pass can be wrong in a way that reaches a
/// human — need none of them.
///
/// Two properties here are load-bearing rather than incidental, and each has its
/// own case below: a `fixed` claim is never honoured over a branch that did not
/// move, and a GraphQL `errors` array is a failure even when `gh` exited 0.
final class PullRequestCommentsTests: XCTestCase {

    // MARK: - Reading the pull request URL

    func testReadsOwnerRepoAndNumberOutOfAPullRequestURL() {
        let repository = PullRequestComments.repository(fromURL: "https://github.com/acme/widgets/pull/42")

        XCTAssertEqual(repository?.owner, "acme")
        XCTAssertEqual(repository?.name, "widgets")
        XCTAssertEqual(repository?.number, 42)
    }

    /// GitHub Enterprise puts the same path under a different host, and the
    /// query is parameterised by the coordinates rather than the host.
    func testReadsAPullRequestURLOnAnEnterpriseHost() {
        let repository = PullRequestComments.repository(fromURL: "https://git.acme.example/team/tools/pull/7")

        XCTAssertEqual(repository?.owner, "team")
        XCTAssertEqual(repository?.name, "tools")
        XCTAssertEqual(repository?.number, 7)
    }

    /// An issue URL, the repository root, and something that is not a URL at all
    /// have nothing to ask GitHub about. Guessing coordinates out of them would
    /// address the pass's mutations at whatever they happened to resolve to.
    func testAnythingThatIsNotAPullRequestURLReadsAsNoRepository() {
        XCTAssertNil(PullRequestComments.repository(fromURL: "https://github.com/acme/widgets/issues/42"))
        XCTAssertNil(PullRequestComments.repository(fromURL: "https://github.com/acme/widgets"))
        XCTAssertNil(PullRequestComments.repository(fromURL: "the pull request could not be opened"))
        XCTAssertNil(PullRequestComments.repository(fromURL: ""))
    }

    // MARK: - Reading what `gh api graphql` said

    func testReadsTheThreadListOutOfGHsJSON() {
        let threads = PullRequestComments.threads(inJSON: graphQL(threads: [
            threadJSON(id: "T_1", path: "Services/Foo.swift", line: 12,
                       comments: [("copilot", "This can be `map`.")]),
            threadJSON(id: "T_2", path: "Services/Bar.swift", line: nil, isResolved: true,
                       comments: [("someone", "Fixed already.")]),
        ]))

        XCTAssertEqual(threads?.count, 2)
        XCTAssertEqual(threads?.first?.id, "T_1")
        XCTAssertEqual(threads?.first?.path, "Services/Foo.swift")
        XCTAssertEqual(threads?.first?.line, 12)
        XCTAssertEqual(threads?.first?.comments.first?.author, "copilot")
        XCTAssertEqual(threads?.first?.location, "Services/Foo.swift:12")
        XCTAssertEqual(threads?.last?.isResolved, true)
        XCTAssertEqual(threads?.last?.location, "Services/Bar.swift")
    }

    /// `gh` merges stderr into the same capture, so its upgrade notice routinely
    /// sits *below* the JSON. A slice that ran to the end of the output would
    /// hand `JSONSerialization` that line along with the object and be rejected
    /// whole — the trap `PullRequestChecks.checks(inJSON:)` was written around,
    /// and the reason this reads every balanced slice rather than the last.
    func testFindsTheJSONWhenGHPrintsAnotherLineAfterIt() {
        let output = graphQL(threads: [threadJSON(id: "T_1", comments: [("copilot", "Nit.")])]) + """


        A new release of gh is available: 2.40.0 → 2.62.0
        To upgrade, run: gh upgrade
        """

        XCTAssertEqual(PullRequestComments.threads(inJSON: output)?.count, 1)
    }

    /// A comment by a deleted account has a null author. It still says
    /// something, and dropping it would leave the thread looking empty to the
    /// worker that has to answer it.
    func testACommentWithNoAuthorIsKeptAndAttributedToSomeone() {
        let output = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[\
        {"id":"T_1","path":"a.swift","line":1,"isResolved":false,"isOutdated":false,\
        "comments":{"nodes":[{"body":"Still worth fixing.","author":null}]}}]}}}}}
        """
        let threads = PullRequestComments.threads(inJSON: output)

        XCTAssertEqual(threads?.first?.comments.count, 1)
        XCTAssertEqual(threads?.first?.comments.first?.author, "someone")
        XCTAssertEqual(threads?.first?.author, "someone")
    }

    /// An empty body says nothing to answer, and a node with no id cannot be
    /// replied to or resolved — both mutations are addressed to that id.
    func testAnEmptyCommentAndAnIdlessThreadAreDropped() {
        let output = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[\
        {"id":"","path":"a.swift","line":1,"isResolved":false,"isOutdated":false,\
        "comments":{"nodes":[{"body":"anything","author":{"login":"bot"}}]}},\
        {"id":"T_2","path":"b.swift","line":2,"isResolved":false,"isOutdated":false,\
        "comments":{"nodes":[{"body":"   ","author":{"login":"bot"}},\
        {"body":"The real point.","author":{"login":"bot"}}]}}]}}}}}
        """
        let threads = PullRequestComments.threads(inJSON: output)

        XCTAssertEqual(threads?.count, 1)
        XCTAssertEqual(threads?.first?.id, "T_2")
        XCTAssertEqual(threads?.first?.comments.count, 1)
        XCTAssertEqual(threads?.first?.comments.first?.body, "The real point.")
    }

    /// A thread this long is a conversation, and its head is what the run is
    /// answering. The bound is what keeps one argumentative thread from filling
    /// the prompt the other nineteen share.
    func testAThreadIsReadNoDeeperThanItsFirstTenComments() {
        let comments = (1...15).map { ("bot", "point \($0)") }
        let threads = PullRequestComments.threads(inJSON: graphQL(threads: [
            threadJSON(id: "T_1", comments: comments),
        ]))

        XCTAssertEqual(threads?.first?.comments.count, PullRequestComments.maxCommentsPerThread)
        XCTAssertEqual(threads?.first?.comments.last?.body, "point 10")
    }

    func testOutputWithNoReadableThreadListReadsAsNil() {
        XCTAssertNil(PullRequestComments.threads(inJSON: ""))
        XCTAssertNil(PullRequestComments.threads(inJSON: "gh: command not found"))
        XCTAssertNil(PullRequestComments.threads(inJSON: #"{"data":{"repository":null}}"#))
    }

    // MARK: - When a `gh` call did not take effect

    /// The case this reading exists for: GraphQL answers `{"data":…,"errors":[…]}`
    /// with a zero exit status when it has refused *part* of a request. A resolve
    /// rejected for permissions must not be counted as a thread this run settled,
    /// so the errors array is read before the status and regardless of it.
    func testAGraphQLErrorIsAFailureEvenWhenGHExitedZero() {
        let output = """
        {"data":{"resolveReviewThread":null},"errors":[\
        {"message":"Resource not accessible by integration"}]}
        """

        XCTAssertEqual(PullRequestComments.failure(exitStatus: 0, output: output),
                       "Resource not accessible by integration")
        XCTAssertEqual(PullRequestComments.graphQLError(inJSON: output),
                       "Resource not accessible by integration")
    }

    /// An errors array with nothing sayable in it is still an error — the call
    /// did not take effect, and reporting success because the message was empty
    /// would be the same mistake in a quieter form.
    func testAnErrorsArrayWithNoMessageIsStillAFailure() {
        let output = #"{"data":null,"errors":[{"type":"FORBIDDEN"}]}"#

        XCTAssertEqual(PullRequestComments.failure(exitStatus: 0, output: output),
                       "gh api graphql returned an error")
    }

    func testANonZeroExitIsAFailureAndACleanCallIsNot() {
        XCTAssertNotNil(PullRequestComments.failure(exitStatus: 1, output: "could not resolve host"))
        XCTAssertNil(PullRequestComments.failure(exitStatus: 0, output: graphQL(threads: [])))
    }

    func testListingCarriesTheThreadsOrWhyThereAreNone() {
        let good = graphQL(threads: [threadJSON(id: "T_1", comments: [("bot", "Nit.")])])
        guard case .threads(let threads) = PullRequestComments.listing(exitStatus: 0, output: good) else {
            return XCTFail("expected a readable thread list")
        }
        XCTAssertEqual(threads.count, 1)

        guard case .unavailable(let reason) =
                PullRequestComments.listing(exitStatus: 0, output: "not json at all") else {
            return XCTFail("expected the listing to be unavailable")
        }
        XCTAssertEqual(reason, "gh api graphql printed no review threads")

        guard case .unavailable = PullRequestComments.listing(exitStatus: 1, output: "boom") else {
            return XCTFail("expected a failed call to be unavailable")
        }
    }

    // MARK: - Which threads a pass acts on

    /// A resolved thread has been settled — by a human, by an earlier pass, or by
    /// the bot itself — and re-answering it would argue with a conversation that
    /// is over.
    func testOnlyUnresolvedThreadsAreActionable() {
        let threads = [
            thread(id: "T_1"),
            thread(id: "T_2", isResolved: true),
            thread(id: "T_3", isOutdated: true),
        ]

        XCTAssertEqual(PullRequestComments.actionableThreads(in: threads).map(\.id), ["T_1", "T_3"])
    }

    /// Past the bound the prompt is bigger than the diff it is about. The rest
    /// wait for the human, and `note` says so rather than leaving the tally to
    /// imply the pull request was cleared.
    func testNoMoreThanTheThreadCapIsCarriedByOnePass() {
        let threads = (1...30).map { thread(id: "T_\($0)") }

        XCTAssertEqual(PullRequestComments.actionableThreads(in: threads).count,
                       PullRequestComments.maxThreads)
        XCTAssertEqual(PullRequestComments.actionableThreads(in: threads, limit: 3).map(\.id),
                       ["T_1", "T_2", "T_3"])
    }

    // MARK: - Reading the worker back

    func testReadsADispositionPerThread() {
        let dispositions = PullRequestComments.dispositions(
            in: output(#"""
            [{"thread":"T_1","action":"fixed","reply":"Good catch — fixed in the latest push."},
             {"thread":"T_2","action":"declined","reply":"This item puts that out of scope."}]
            """#),
            threads: [thread(id: "T_1"), thread(id: "T_2")])

        XCTAssertEqual(dispositions.count, 2)
        XCTAssertEqual(dispositions.first?.action, .fixed)
        XCTAssertEqual(dispositions.first?.reply, "Good catch — fixed in the latest push.")
        XCTAssertEqual(dispositions.last?.action, .declined)
    }

    /// Lenient about spelling in the same direction as `ReviewFindings`, since an
    /// unreadable answer costs the whole pass — but not about *which* thread. An
    /// id that wasn't on the list is dropped rather than guessed at: acting on it
    /// posts a comment onto a thread nobody read.
    func testAnEntryNamingAThreadThatWasNotOnTheListIsDropped() {
        let dispositions = PullRequestComments.dispositions(
            in: output(#"""
            [{"thread":"T_9","action":"declined","reply":"Not this one."},
             {"threadId":"T_1","status":"fixed","body":"Alternate keys still read."}]
            """#),
            threads: [thread(id: "T_1")])

        XCTAssertEqual(dispositions.map(\.threadID), ["T_1"])
        XCTAssertEqual(dispositions.first?.action, .fixed)
        XCTAssertEqual(dispositions.first?.reply, "Alternate keys still read.")
    }

    /// A worker that changed its mind mid-answer must not have one thread both
    /// resolved and argued with, so the first entry for an id stands.
    func testARepeatedThreadIdKeepsItsFirstEntry() {
        let dispositions = PullRequestComments.dispositions(
            in: output(#"""
            [{"thread":"T_1","action":"declined","reply":"On reflection, no."},
             {"thread":"T_1","action":"fixed","reply":"Actually, done."}]
            """#),
            threads: [thread(id: "T_1")])

        XCTAssertEqual(dispositions.count, 1)
        XCTAssertEqual(dispositions.first?.action, .declined)
        XCTAssertEqual(dispositions.first?.reply, "On reflection, no.")
    }

    /// The two directions are not symmetric: `fixed` resolves a thread and closes
    /// the conversation, `declined` posts the words and leaves it open. Wording
    /// nobody anticipated therefore reads as `declined` — guessing wrong that way
    /// costs an open thread, guessing wrong the other way hides one.
    func testWordingTheActionsDoNotCoverReadsAsDeclined() {
        let dispositions = PullRequestComments.dispositions(
            in: output(#"""
            [{"thread":"T_1","action":"partially addressed","reply":"Half of it."},
             {"thread":"T_2","action":"resolved","reply":"Done."},
             {"thread":"T_3","reply":"No action named at all."}]
            """#),
            threads: [thread(id: "T_1"), thread(id: "T_2"), thread(id: "T_3")])

        XCTAssertEqual(dispositions.map(\.action), [.declined, .fixed, .declined])
    }

    func testAnUnreadableAnswerYieldsNoDispositions() {
        XCTAssertEqual(PullRequestComments.dispositions(in: [:], threads: [thread(id: "T_1")]).count, 0)
        XCTAssertEqual(PullRequestComments.dispositions(in: output("not json"),
                                                        threads: [thread(id: "T_1")]).count, 0)
    }

    // MARK: - What the run will actually act on

    /// The property this pass most needs to hold. A `fixed` claim over a branch
    /// that did not move cannot be true — there is no commit for it to be true of
    /// — so it is dropped whole, reply included. Posting "fixed in the latest
    /// push" onto a thread over an unmoved branch is a lie told on the run's
    /// behalf, to the person the pull request is for.
    func testAFixedClaimIsDroppedWholeWhenThePassCommittedNothing() {
        let dispositions = [
            disposition(id: "T_1", action: .fixed, reply: "Fixed in the latest push."),
            disposition(id: "T_2", action: .declined, reply: "Out of scope for this item."),
        ]

        let actionable = PullRequestComments.actionable(dispositions, committed: false)

        XCTAssertEqual(actionable.map(\.threadID), ["T_2"])
        XCTAssertEqual(PullRequestComments.actionable(dispositions, committed: true).count, 2)
    }

    /// The mirror case: there is nothing to post and resolving is not on the
    /// table, so acting on it would be a no-op recorded as an answer.
    func testADeclineWithNothingToSayIsDropped() {
        let dispositions = [
            disposition(id: "T_1", action: .declined, reply: ""),
            disposition(id: "T_2", action: .declined, reply: "Because the code already does this."),
        ]

        XCTAssertEqual(PullRequestComments.actionable(dispositions, committed: true).map(\.threadID),
                       ["T_2"])
    }

    /// A fix does not need words — the commit speaks for itself — so an empty
    /// reply on a `fixed` disposition is not the same defect as an empty decline.
    func testAFixWithNoReplyStillCountsOnceSomethingWasCommitted() {
        let dispositions = [disposition(id: "T_1", action: .fixed, reply: "")]

        XCTAssertEqual(PullRequestComments.actionable(dispositions, committed: true).count, 1)
    }

    // MARK: - The tally

    /// Counted off what the run did, not off what the worker said it would do:
    /// `acted` is the dispositions whose replies posted and whose resolves took.
    func testTheTallyCountsWhatWasActedOnAndLeavesTheRestForTheGate() {
        let outcome = PullRequestComments.outcome(threads: 5, acted: [
            disposition(id: "T_1", action: .fixed, reply: "done"),
            disposition(id: "T_2", action: .fixed, reply: "done"),
            disposition(id: "T_3", action: .declined, reply: "no"),
        ])

        XCTAssertEqual(outcome, .addressed(fixed: 2, answered: 1, left: 2))
    }

    func testAPullRequestNobodyCommentedOnIsNotASkip() {
        XCTAssertEqual(PullRequestComments.outcome(threads: 0, acted: []), .nothingToAddress)
        XCTAssertNil(PullRequestComments.gateDetail(for: .nothingToAddress))
        XCTAssertEqual(PullRequestComments.note(for: .nothingToAddress),
                       "Pull request had no unresolved review comments")
    }

    // MARK: - What the Notes and the human are told

    func testTheNoteSaysHowTheThreadsWereLeft() {
        XCTAssertEqual(PullRequestComments.note(for: .addressed(fixed: 2, answered: 1, left: 0)),
                       "Pull request review comments: 2 fixed, 1 answered")
        XCTAssertEqual(PullRequestComments.note(for: .addressed(fixed: 2, answered: 1, left: 3)),
                       "Pull request review comments: 2 fixed, 1 answered, 3 left for the gate")
        XCTAssertEqual(PullRequestComments.note(for: .skipped(reason: "the item's cost cap is spent")),
                       "Pull request review comments not addressed — the item's cost cap is spent")
    }

    /// The clause on the approval-gate notification: the human being summoned
    /// learns what state the threads are in before they open the pull request.
    func testTheGateDetailNamesWhatIsStillOpen() {
        XCTAssertEqual(PullRequestComments.gateDetail(for: .addressed(fixed: 1, answered: 0, left: 0)),
                       "PR comments: 1 fixed, 0 answered")
        XCTAssertEqual(PullRequestComments.gateDetail(for: .addressed(fixed: 1, answered: 2, left: 4)),
                       "PR comments: 1 fixed, 2 answered, 4 open")
        XCTAssertEqual(PullRequestComments.gateDetail(for: .skipped(reason: "gh is not installed")),
                       "PR comments not addressed")
    }

    /// One word per terminal state, so a night's runs can be counted by grepping
    /// the phase lines for it.
    func testEveryOutcomeHasOneWordAPhaseLineCallsIt() {
        XCTAssertEqual(PullRequestComments.outcomeName(.addressed(fixed: 0, answered: 0, left: 0)),
                       "addressed")
        XCTAssertEqual(PullRequestComments.outcomeName(.nothingToAddress), "none")
        XCTAssertEqual(PullRequestComments.outcomeName(.skipped(reason: "any")), "skipped")
    }

    // MARK: - What the worker is asked

    /// The item's prohibitions bind over the bot's suggestion — the reviewer
    /// rubric already treats them that way, and a robot reviewer does not outrank
    /// them. The prompt is where the worker learns which suggestions are not this
    /// item's to take.
    func testThePromptQuotesTheItemsOutOfScopeAsBinding() {
        let prompt = PullRequestComments.prompt(
            item: item(), detail: detail(outOfScope: ["Rewriting the parser", "Adding a cache"]),
            branch: "kiteloop/pr-comments-resolved",
            url: "https://github.com/acme/widgets/pull/42",
            threads: [thread(id: "T_1")], buildOutputNote: nil)

        XCTAssertTrue(prompt.contains("Rewriting the parser"))
        XCTAssertTrue(prompt.contains("Adding a cache"))
        XCTAssertTrue(prompt.contains("These bind."))
    }

    /// An empty Out of Scope list is a legitimate statement, not a section to
    /// print with nothing under it.
    func testThePromptOmitsTheOutOfScopeSectionWhenTheItemNamedNone() {
        let prompt = PullRequestComments.prompt(
            item: item(), detail: detail(outOfScope: []),
            branch: "b", url: "https://github.com/acme/widgets/pull/42",
            threads: [thread(id: "T_1")], buildOutputNote: nil)

        XCTAssertFalse(prompt.contains("What this item put out of scope"))
    }

    /// The ids are what a disposition names, so they have to survive into the
    /// prompt verbatim; the pass is told out loud that it is the only one.
    func testThePromptCarriesEveryThreadWithItsIdAndSaysThereIsOnlyOnePass() {
        let prompt = PullRequestComments.prompt(
            item: item(), detail: detail(outOfScope: []),
            branch: "b", url: "https://github.com/acme/widgets/pull/42",
            threads: [thread(id: "T_1", path: "Services/Foo.swift", line: 12),
                      thread(id: "T_2", path: "Services/Bar.swift", line: nil, isOutdated: true)],
            buildOutputNote: nil)

        XCTAssertTrue(prompt.contains("T_1"))
        XCTAssertTrue(prompt.contains("T_2"))
        XCTAssertTrue(prompt.contains("Services/Foo.swift:12"))
        XCTAssertTrue(prompt.contains("the code this was written about has changed since"))
        XCTAssertTrue(prompt.contains("2 unresolved review threads"))
        XCTAssertTrue(prompt.contains("This is the only pass"))
        XCTAssertTrue(prompt.contains(PullRequestComments.outputKey))
    }

    func testThePromptCountsOneThreadInTheSingular() {
        let prompt = PullRequestComments.prompt(
            item: item(), detail: nil, branch: "b",
            url: "https://github.com/acme/widgets/pull/42",
            threads: [thread(id: "T_1")], buildOutputNote: nil)

        XCTAssertTrue(prompt.contains("1 unresolved review thread on it"))
    }

    // MARK: - Clipping

    /// A bot puts its point first and its boilerplate after it, which is the
    /// opposite of a CI log — so this clips the head, where `PullRequestChecks`
    /// clips the tail.
    func testACommentIsClippedFromItsHead() {
        let long = String(repeating: "x", count: 40)

        XCTAssertEqual(PullRequestComments.clip(long, limit: 10), String(repeating: "x", count: 10) + "…")
        XCTAssertEqual(PullRequestComments.clip("short", limit: 10), "short")
    }

    // MARK: - Fixtures

    private func thread(id: String, path: String = "Services/Foo.swift", line: Int? = 1,
                        isResolved: Bool = false, isOutdated: Bool = false)
    -> PullRequestComments.Thread {
        PullRequestComments.Thread(
            id: id, path: path, line: line, isResolved: isResolved, isOutdated: isOutdated,
            comments: [PullRequestComments.Comment(author: "copilot", body: "This could be simpler.")])
    }

    private func disposition(id: String, action: PullRequestComments.Action, reply: String)
    -> PullRequestComments.Disposition {
        PullRequestComments.Disposition(threadID: id, action: action, reply: reply)
    }

    /// The workflow state a pass reads back: `StructuredOutputExtractor`
    /// re-encodes a JSON array into a string field, so this is the shape the
    /// dispositions actually arrive in.
    private func output(_ dispositions: String) -> [String: AnyCodable] {
        [PullRequestComments.outputKey: .string(dispositions)]
    }

    private func item() -> BacklogItem {
        BacklogItem(id: "pr-comments-resolved",
                    title: "One bounded pass over the PR's unresolved review threads",
                    verify: "true", status: .awaitingApproval, type: .local, size: .m)
    }

    private func detail(outOfScope: [String]) -> BacklogItemDetail {
        BacklogItemDetail(id: "pr-comments-resolved",
                          title: "One bounded pass over the PR's unresolved review threads",
                          verifyCommands: [], acceptanceCriteria: [], outOfScope: outOfScope)
    }

    private func threadJSON(id: String, path: String = "a.swift", line: Int? = 1,
                            isResolved: Bool = false, isOutdated: Bool = false,
                            comments: [(String, String)]) -> String {
        let nodes = comments
            .map { #"{"body":"\#($0.1)","author":{"login":"\#($0.0)"}}"# }
            .joined(separator: ",")
        return #"{"id":"\#(id)","path":"\#(path)","line":\#(line.map(String.init) ?? "null"),"# +
               #""isResolved":\#(isResolved),"isOutdated":\#(isOutdated),"# +
               #""comments":{"nodes":[\#(nodes)]}}"#
    }

    private func graphQL(threads: [String]) -> String {
        #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":["# +
        threads.joined(separator: ",") + "]}}}}}"
    }
}
