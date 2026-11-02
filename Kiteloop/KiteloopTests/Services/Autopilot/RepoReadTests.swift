import XCTest
import KiteloopCore
@testable import Kiteloop

/// `RepoRead` — the policy behind the Planner's read-only source access.
///
/// The four claims worth asserting are the four the item is written around, and
/// each is a property of the type rather than of a caller: the grant carries
/// nothing that can act, the grant is the scope, what comes back is bounded and
/// says so, and not having looked stays a legitimate answer.
final class RepoReadTests: XCTestCase {

    // MARK: - No writes, no shell, no network

    func testTheGrantIsThreeReadVerbs() {
        XCTAssertEqual(RepoRead.allowedTools, ["Glob", "Grep", "Read"])
    }

    /// The claim in the item's own words, checked against the classification
    /// rather than restated as a second list: adding `Bash` to `allowedTools`
    /// fails here, which a list-equals-list assertion would not catch on its own.
    func testNothingGrantedCanWriteRunACommandOrReachTheNetwork() {
        for granted in RepoRead.allowedTools {
            XCTAssertFalse(RepoRead.writingTools.contains(granted), "\(granted) writes")
            XCTAssertFalse(RepoRead.executingTools.contains(granted), "\(granted) runs something")
            XCTAssertFalse(RepoRead.networkTools.contains(granted), "\(granted) leaves the machine")
        }
        XCTAssertTrue(Set(RepoRead.allowedTools).isDisjoint(with: RepoRead.forbiddenTools))
    }

    /// "No shell" is not only `Bash`. A tool that can start another agent can
    /// start one holding tools this grant refuses, so the executing class has to
    /// name those too.
    func testExecutingCoversMoreThanBash() {
        for name in ["Bash", "Agent", "Workflow"] {
            XCTAssertTrue(RepoRead.executingTools.contains(name), "\(name) must count as executing")
        }
    }

    /// Every one of the three classes is refused by name as well as withheld by
    /// the allow-list — belt as well as braces, because `ToolScopeResolver` gives
    /// deny precedence over every later layer.
    func testEveryForbiddenToolIsDeniedByName() {
        let denied = Set(RepoRead.deniedTools)
        for forbidden in RepoRead.forbiddenTools where ClaudeCodeCLIRuntime.baseCLITools.contains(forbidden) {
            XCTAssertTrue(denied.contains(forbidden), "\(forbidden) is not refused by name")
        }
    }

    /// The denials are *computed* from the runtime's base set, which is what
    /// makes a tool added there arrive here denied rather than quietly granted.
    /// A hand-written list would have had to be remembered.
    func testDenialsAreEverythingTheBaseSetOffersThatIsNotGranted() {
        XCTAssertEqual(Set(RepoRead.deniedTools),
                       ClaudeCodeCLIRuntime.baseCLITools.subtracting(RepoRead.allowedTools))
        XCTAssertTrue(Set(RepoRead.deniedTools).isDisjoint(with: Set(RepoRead.allowedTools)),
                      "a tool cannot be both granted and refused")
    }

    // MARK: - The grant is the scope

    func testAGrantCanonicalisesItsRoot() {
        let raw = "/tmp/./some-project/"
        let grant = RepoRead.Grant(projectName: "some-project", projectPath: raw)

        XCTAssertEqual(grant.projectPath, KiteloopProject.canonicalPath(raw))
        XCTAssertEqual(grant.root.path(percentEncoded: false), grant.projectPath)
    }

    // MARK: - Bounds

    func testAnAnswerWithinTheBoundComesBackUntouched() {
        let bounded = RepoRead.bound("Foo.swift is still there, at Services/Foo.swift:12.")

        XCTAssertFalse(bounded.wasCapped)
        XCTAssertEqual(bounded.text, "Foo.swift is still there, at Services/Foo.swift:12.")
        XCTAssertEqual(bounded.stated, bounded.text,
                       "an answer that fits must not carry a truncation notice for a cut that didn't happen")
    }

    func testAnAnswerExactlyAtTheBoundIsNotCapped() {
        let bounded = RepoRead.bound(String(repeating: "a", count: 40), limit: 40)

        XCTAssertFalse(bounded.wasCapped)
        XCTAssertEqual(bounded.text.count, 40)
    }

    /// The acceptance criterion, and the reason `Answer` is a type rather than a
    /// `String`: a cut nobody is told about reads exactly like a complete answer.
    func testACappedAnswerSaysItWasCapped() {
        let long = String(repeating: "match ", count: 4000)

        let bounded = RepoRead.bound(long)

        XCTAssertTrue(bounded.wasCapped)
        XCTAssertLessThanOrEqual(bounded.text.count, RepoRead.answerCharacterLimit)
        XCTAssertTrue(bounded.stated.contains(RepoRead.capNotice),
                      "the cap has to be stated in the text a reader is shown")
        XCTAssertTrue(RepoRead.capNotice.lowercased().contains("capped"))
    }

    func testACappedAnswerIsCutAtAWordBoundary() {
        let bounded = RepoRead.bound("alpha beta gamma delta", limit: 14)

        XCTAssertTrue(bounded.wasCapped)
        XCTAssertEqual(bounded.text, "alpha beta",
                       "cut back to the last whitespace rather than mid-word")
    }

    /// One unbroken token has nowhere kinder to be cut, so it still gets the hard
    /// cut — and still says it was cut.
    func testAnUnbrokenTokenStillGetsTheHardCut() {
        let bounded = RepoRead.bound(String(repeating: "x", count: 50), limit: 10)

        XCTAssertTrue(bounded.wasCapped)
        XCTAssertEqual(bounded.text, String(repeating: "x", count: 10))
    }

    // MARK: - What the model is told

    func testTheContractNamesTheOneProjectItMayRead() {
        let grant = RepoRead.Grant(projectName: "alpha", projectPath: "/tmp/alpha")

        let contract = RepoRead.contract(for: grant)

        XCTAssertTrue(contract.contains("alpha"))
        XCTAssertTrue(contract.contains(grant.projectPath))
        XCTAssertTrue(contract.contains("Another project's files are not yours to read"),
                      "the scope has to be stated, not left implied by the cwd")
    }

    func testTheContractForbidsWritingRunningAndTheNetwork() {
        let contract = RepoRead.contract(for: RepoRead.Grant(projectName: "alpha",
                                                             projectPath: "/tmp/alpha"))

        XCTAssertTrue(contract.contains("cannot write a file, run a command, or reach the network"))
        for granted in RepoRead.allowedTools {
            XCTAssertTrue(contract.contains("`\(granted)`"), "\(granted) is not named as available")
        }
    }

    /// The behaviour the item asks to *preserve*: the tool-less Planner refused
    /// to comment on a repository it could not see, and a Planner that can see
    /// one still has to say when it has not looked.
    func testTheContractKeepsTheRefusalWhenNothingWasRead() {
        let contract = RepoRead.contract(for: RepoRead.Grant(projectName: "alpha",
                                                             projectPath: "/tmp/alpha"))

        XCTAssertTrue(contract.contains("If you did not read something, say you did not read it"))
        XCTAssertTrue(contract.contains("a confident guess is neither"))
    }

    func testTheContractAsksForBoundedResults() {
        let contract = RepoRead.contract(for: RepoRead.Grant(projectName: "alpha",
                                                             projectPath: "/tmp/alpha"))

        XCTAssertTrue(contract.contains("\(RepoRead.searchMatchLimit) matches"))
        XCTAssertTrue(contract.contains("\(RepoRead.fileLineLimit) lines"))
    }

    func testThePromptCarriesTheQuestionAndTheScope() {
        let grant = RepoRead.Grant(projectName: "alpha", projectPath: "/tmp/alpha")

        let prompt = RepoRead.prompt(question: "  does Foo exist?  ", grant: grant)

        XCTAssertTrue(prompt.contains("does Foo exist?"))
        XCTAssertFalse(prompt.contains("  does"), "the question is trimmed")
        XCTAssertTrue(prompt.contains(grant.projectPath))
    }

    // MARK: - Outcome

    func testEveryOutcomeHasSomethingToSay() {
        let answered = RepoRead.Outcome.answered(
            project: "alpha", answer: RepoRead.bound("it is still there"), costUSD: 0.4)

        XCTAssertEqual(answered.message, "it is still there")
        XCTAssertEqual(answered.answer?.wasCapped, false)
        XCTAssertEqual(RepoRead.Outcome.unknownProject("no such project").message, "no such project")
        XCTAssertEqual(RepoRead.Outcome.budgetExhausted("spent").message, "spent")
        XCTAssertEqual(RepoRead.Outcome.unavailable("unwired").message, "unwired")
        XCTAssertEqual(RepoRead.Outcome.noAnswer("empty").message, "empty")
        XCTAssertNil(RepoRead.Outcome.unknownProject("x").answer)
    }

    /// A capped answer reaches the caller stated, so a surface that prints
    /// `message` and nothing else still reports the cap.
    func testACappedOutcomeStatesTheCapInItsMessage() {
        let outcome = RepoRead.Outcome.answered(
            project: "alpha",
            answer: RepoRead.bound(String(repeating: "match ", count: 4000)),
            costUSD: 1)

        XCTAssertTrue(outcome.message.contains(RepoRead.capNotice))
    }
}
