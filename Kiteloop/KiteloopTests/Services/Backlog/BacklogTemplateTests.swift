import XCTest
import KiteloopCore
@testable import Kiteloop

/// Backlog templates: the parse, the substitution, and — the point of the whole
/// thing — the refusals.
///
/// A template stamps a *set* of items with `needs:` edges between them, so a
/// partial stamp is worse than none: the missing half is invisible, and the half
/// that landed is waiting on something nobody will ever file. Every refusal here
/// is therefore asserted to be whole-stamp, and the proving template — the real
/// `templates/release.md` in this repo — is stamped end to end.
final class BacklogTemplateTests: XCTestCase {

    // MARK: - Fixtures

    /// Two ordered items, one variable, a constraint on it — the shape the
    /// release checklist has, small enough to assert against.
    private let twoStep = """
    ---
    description: A two-item process
    epic: Releases
    variables:
      - name: version
        description: The version being shipped
        required: true
        pattern: ^\\d+\\.\\d+\\.\\d+$
    ---

    ## Item

    - [ ] step-one-{{version}} | Bump the spec to {{version}} | size:XS | verify:grep -q {{version}} spec.txt

    ## What

    The spec reads {{version}}.

    ## How

    Edit `spec.txt`.

    ## Validation

    - [ ] The spec reads {{version}}

    ## Out of Scope

    - Anything else

    ## Item

    - [ ] step-two-{{version}} | Flip the changelog to {{version}} | size:S | verify:grep -q {{version}} CHANGES.md | needs:step-one-{{version}}

    ## What

    The changelog names {{version}}.

    ## How

    Edit `CHANGES.md`.

    ## Validation

    - [ ] The changelog names {{version}}

    ## Out of Scope

    - Writing new entries
    """

    /// One well-groomed item that waits for `needs` — a checklist step written
    /// against a prerequisite the template did not stamp itself.
    private func dependent(on needs: String) -> String {
        """
        ---
        variables: []
        ---

        ## Item

        - [ ] follow-up | Bump the spec | size:XS | verify:grep -q done spec.txt | needs:\(needs)

        ## What

        The spec reads done.

        ## How

        Edit `spec.txt`.

        ## Validation

        - [ ] The spec reads done

        ## Out of Scope

        - Anything else
        """
    }

    private func parse(_ content: String, name: String = "two-step") throws -> BacklogTemplate {
        try BacklogTemplate.parse(content, name: name)
    }

    // MARK: - Header

    func testTheHeaderDeclaresTheVariablesAndTheEpic() throws {
        let template = try parse(twoStep)

        XCTAssertEqual(template.name, "two-step")
        XCTAssertEqual(template.description, "A two-item process")
        XCTAssertEqual(template.epic, "Releases")
        XCTAssertEqual(template.items.count, 2)
        XCTAssertEqual(template.variables.count, 1)
        let version = try XCTUnwrap(template.variable(named: "version"))
        XCTAssertEqual(version.description, "The version being shipped")
        XCTAssertTrue(version.required)
        XCTAssertEqual(version.pattern, #"^\d+\.\d+\.\d+$"#)
    }

    /// `required: false` is the only value that makes a variable optional —
    /// anything else, including a missing line, leaves it required. Silently
    /// optional variables would stamp empty strings into filed items.
    func testAVariableIsRequiredUnlessItSaysOtherwise() throws {
        let template = try parse("""
        ---
        variables:
          - name: a
          - name: b
            required: false
        ---

        ## Item

        - [ ] x | t {{a}}{{b}} | size:XS | verify:true
        """)

        XCTAssertEqual(template.variable(named: "a")?.required, true)
        XCTAssertEqual(template.variable(named: "b")?.required, false)
    }

    // MARK: - Substitution

    func testEveryPlaceholderInTheLineAndTheBodyIsSubstituted() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])

        XCTAssertEqual(stamped.map(\.draft.id), ["step-one-1.2.3", "step-two-1.2.3"])
        XCTAssertEqual(stamped[0].draft.title, "Bump the spec to 1.2.3")
        XCTAssertEqual(stamped[0].draft.verify, "grep -q 1.2.3 spec.txt")
        XCTAssertEqual(stamped[0].draft.what, "The spec reads 1.2.3.")
        XCTAssertEqual(stamped[0].draft.validation, ["The spec reads 1.2.3"])
        XCTAssertFalse(stamped.contains { $0.draft.detailMarkdown().contains("{{") },
                       "a filed detail file must hold no placeholders")
    }

    /// The line is read by `BacklogParser.parseItemLine` — the same parser that
    /// reads BACKLOG.md — so a template is literally the fragment it becomes, and
    /// `size:`, `verify:` and `needs:` need no second dialect.
    func testTheItemLineIsReadByTheBacklogParser() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])

        XCTAssertEqual(stamped[0].draft.size, "XS")
        XCTAssertEqual(stamped[1].draft.size, "S")
        XCTAssertEqual(stamped[0].draft.needs, [], "the first step waits for nothing")
        XCTAssertEqual(stamped[1].draft.needs, ["step-one-1.2.3"],
                       "the second step waits for the first, with the variable substituted")
    }

    /// The detail body is read by `BacklogParser.parseDetail`, so what a stamped
    /// item files is the layout the Definition-of-Ready reads back.
    func testTheDetailBodyBecomesTheGroomedFile() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])
        let markdown = stamped[1].draft.detailMarkdown()

        XCTAssertTrue(markdown.contains("id: step-two-1.2.3"))
        XCTAssertTrue(markdown.contains("## What"))
        XCTAssertTrue(markdown.contains("## How"))
        XCTAssertTrue(markdown.contains("- [ ] The changelog names 1.2.3"))
        XCTAssertTrue(markdown.contains("- Writing new entries"))
    }

    /// An optional variable nobody supplied substitutes to nothing rather than
    /// being left as `{{name}}` in a filed item.
    func testAnOmittedOptionalVariableSubstitutesToNothing() throws {
        let template = try parse("""
        ---
        variables:
          - name: suffix
            required: false
        ---

        ## Item

        - [ ] item{{suffix}} | A title{{suffix}} | size:XS | verify:true
        """)

        let stamped = try template.stamp(values: [:], existingIDs: [])
        XCTAssertEqual(stamped.map(\.draft.id), ["item"])
        XCTAssertEqual(stamped[0].draft.title, "A title")
    }

    /// Substituted text is never rescanned, so a value carrying braces cannot
    /// become a placeholder — but such a value is refused before that matters.
    func testSubstitutionDoesNotRescanWhatItInserted() {
        XCTAssertEqual(BacklogTemplate.substitute("{{a}}", values: ["a": "{{b}}", "b": "no"]),
                       "{{b}}")
    }

    // MARK: - Constraint refusal

    func testAValueFailingItsPatternRefusesTheWholeStampNamingTheVariable() throws {
        let template = try parse(twoStep)

        XCTAssertThrowsError(try template.stamp(values: ["version": "next"], existingIDs: [])) { error in
            guard case .constraintViolated(let name, let value, let pattern) =
                    error as? BacklogTemplateError else {
                return XCTFail("expected a constraint violation, got \(error)")
            }
            XCTAssertEqual(name, "version")
            XCTAssertEqual(value, "next")
            XCTAssertEqual(pattern, #"^\d+\.\d+\.\d+$"#)
            // The message has to name the variable and what it wanted, or the
            // fix is a re-read of the template.
            let message = (error as! BacklogTemplateError).message
            XCTAssertTrue(message.contains("version"), message)
            XCTAssertTrue(message.contains(#"^\d+\.\d+\.\d+$"#), message)
        }
    }

    /// The pattern is matched **whole**: a value that merely contains something
    /// acceptable is not acceptable.
    func testThePatternMustMatchTheWholeValue() throws {
        let template = try parse(twoStep)
        XCTAssertThrowsError(try template.stamp(values: ["version": "v1.2.3-rc1"], existingIDs: []))
        XCTAssertNoThrow(try template.stamp(values: ["version": "1.2.3"], existingIDs: []))
    }

    func testAMissingRequiredVariableIsRefused() throws {
        XCTAssertThrowsError(try parse(twoStep).stamp(values: [:], existingIDs: [])) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .missingVariable("version"))
        }
    }

    /// A misspelled variable name would otherwise leave `{{version}}` standing in
    /// three verify commands — refused, naming what was sent.
    func testAVariableTheTemplateNeverDeclaredIsRefused() throws {
        XCTAssertThrowsError(
            try parse(twoStep).stamp(values: ["version": "1.2.3", "verison": "1.2.3"],
                                     existingIDs: [])
        ) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .unknownVariable("verison"))
        }
    }

    /// A backlog line is one line, and a value carrying braces would stamp
    /// something that looks like a placeholder into a filed item. Both are
    /// structural and refused whatever the pattern says.
    func testAValueCannotCarryANewlineOrBraces() throws {
        let template = try parse("""
        ---
        variables:
          - name: text
        ---

        ## Item

        - [ ] item | {{text}} | size:XS | verify:true
        """)

        for bad in ["one\ntwo", "{{nested}}", "trailing}}"] {
            XCTAssertThrowsError(try template.stamp(values: ["text": bad], existingIDs: [])) { error in
                XCTAssertEqual(error as? BacklogTemplateError, .unusableValue("text"), bad)
            }
        }
    }

    // MARK: - Collision refusal

    /// The guard against filing the same release twice — and the reason it is
    /// whole-stamp: the first item of a checklist landing on its own leaves the
    /// rest waiting on an id nobody will file.
    func testAnIDAlreadyInTheBacklogRefusesTheWholeStamp() throws {
        let template = try parse(twoStep)

        XCTAssertThrowsError(
            try template.stamp(values: ["version": "1.2.3"], existingIDs: ["step-two-1.2.3"])
        ) { error in
            guard case .idRejected(let reason) = error as? BacklogTemplateError else {
                return XCTFail("expected an id rejection, got \(error)")
            }
            XCTAssertTrue(reason.contains("step-two-1.2.3"), reason)
        }
        // A different version does not collide, which is what makes the refusal a
        // guard rather than a wall.
        XCTAssertNoThrow(try template.stamp(values: ["version": "1.2.4"],
                                            existingIDs: ["step-two-1.2.3"]))
    }

    /// The collision is checked across the stamp as well as against the backlog:
    /// two blocks that resolve to one id would file one item and silently drop
    /// the other.
    func testTwoBlocksResolvingToTheSameIDRefuse() throws {
        let template = try parse("""
        ---
        variables:
          - name: v
        ---

        ## Item

        - [ ] item-{{v}} | First | size:XS | verify:true

        ## Item

        - [ ] item-{{v}} | Second | size:XS | verify:true
        """)

        XCTAssertThrowsError(try template.stamp(values: ["v": "1"], existingIDs: [])) { error in
            guard case .idRejected(let reason) = error as? BacklogTemplateError else {
                return XCTFail("expected an id rejection, got \(error)")
            }
            XCTAssertTrue(reason.contains("item-1"), reason)
        }
    }

    /// An id becomes `backlog/<id>.md`, so a value that escapes the directory is
    /// refused by the same bound a coordinator filing faces.
    func testAnIDThatIsNotASafeFileNameIsRefused() throws {
        let template = try parse("""
        ---
        variables:
          - name: v
        ---

        ## Item

        - [ ] release-{{v}} | Title | size:XS | verify:true
        """)

        XCTAssertThrowsError(try template.stamp(values: ["v": "../../etc/passwd"], existingIDs: []))
    }

    // MARK: - Template authoring errors, caught at parse

    func testAPlaceholderNoVariableDeclaresIsRefusedAtParse() {
        XCTAssertThrowsError(try parse("""
        ---
        variables:
          - name: version
        ---

        ## Item

        - [ ] item-{{version}} | Ship {{verison}} | size:XS | verify:true
        """)) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .undeclaredPlaceholder("verison"))
        }
    }

    func testAnUnreadablePatternIsRefusedAtParse() {
        XCTAssertThrowsError(try parse("""
        ---
        variables:
          - name: v
            pattern: "[unterminated"
        ---

        ## Item

        - [ ] item | Title | size:XS | verify:true
        """)) { error in
            guard case .badPattern(let name, _) = error as? BacklogTemplateError else {
                return XCTFail("expected a bad pattern, got \(error)")
            }
            XCTAssertEqual(name, "v")
        }
    }

    func testATemplateWithNoItemBlocksIsRefused() {
        XCTAssertThrowsError(try parse("""
        ---
        description: empty
        ---

        Just prose about a process nobody wrote down.
        """)) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .noItems)
        }
    }

    func testABlockThatDoesNotOpenWithAnItemLineIsRefused() {
        XCTAssertThrowsError(try parse("""
        ## Item

        ## What

        A block that forgot its line.
        """)) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .blockWithoutAnItemLine)
        }
    }

    func testAVariableDeclaredTwiceIsRefused() {
        XCTAssertThrowsError(try parse("""
        ---
        variables:
          - name: v
          - name: v
        ---

        ## Item

        - [ ] item | {{v}} | size:XS | verify:true
        """)) { error in
            XCTAssertEqual(error as? BacklogTemplateError, .duplicateVariable("v"))
        }
    }

    /// A `## Validation` checkbox is written `- [ ] …` too. Splitting blocks on
    /// the item line rather than on `## Item` would cut a block in half at its
    /// own acceptance criteria.
    func testValidationCheckboxesDoNotOpenANewItem() throws {
        XCTAssertEqual(try parse(twoStep).items.count, 2)
    }

    // MARK: - The `needs:` ids

    /// A template is written once and stamped for years, so the id it names as a
    /// prerequisite can be renamed or deleted out from under it. Left on the line
    /// it names nothing for ever: the pickup gate withholds the item on every
    /// pass and nothing returns it to the groomer. Dropped, and said.
    func testANeedsIDThatNamesNothingIsDroppedAndWrittenDown() throws {
        let stamped = try parse(dependent(on: "groundwork")).stamp(values: [:], existingIDs: [])

        XCTAssertEqual(stamped[0].draft.needs, [])
        XCTAssertEqual(stamped[0].notes.count, 1, "\(stamped[0].notes)")
        let note = try XCTUnwrap(stamped[0].notes.first)
        XCTAssertTrue(note.contains("groundwork"), note)
        XCTAssertTrue(note.contains("dropped needs:"), note)
    }

    /// The other half: an id the backlog does have is a real prerequisite, and is
    /// kept exactly as the template spelled it.
    func testANeedsIDAlreadyInTheBacklogIsKept() throws {
        let stamped = try parse(dependent(on: "groundwork"))
            .stamp(values: [:], existingIDs: ["groundwork", "something-else"])

        XCTAssertEqual(stamped[0].draft.needs, ["groundwork"])
        XCTAssertEqual(stamped[0].notes, [])
    }

    /// The ordering a checklist writes between its own steps: the items are filed
    /// together, so an id stamped by the same call resolves even though the
    /// backlog has never heard of it.
    func testANeedsIDStampedByTheSameCallIsKept() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])

        XCTAssertEqual(stamped[1].draft.needs, ["step-one-1.2.3"],
                       "the second step waits for the first, which this stamp files")
        XCTAssertEqual(stamped.flatMap(\.notes), [])
    }

    /// Dropping an invented prerequisite must not park the item: a `draft` nobody
    /// picks up is the same never-runs failure by another route. The item is
    /// `ready` when the gates are happy, with the sentence in its `## Notes`.
    func testADroppedNeedsIDDoesNotParkTheItem() throws {
        let stamped = try parse(dependent(on: "groundwork")).stamp(values: [:], existingIDs: [])
        let gated = BacklogTemplate.gate(stamped, sources: sources(paths: ["spec.txt"]))

        XCTAssertEqual(gated[0].status, .ready)
        XCTAssertTrue(gated[0].notes.contains { $0.contains("dropped needs:groundwork") },
                      "\(gated[0].notes)")
        let markdown = gated[0].draft.detailMarkdown(notes: gated[0].notes)
        XCTAssertTrue(markdown.contains("## Notes"), markdown)
        XCTAssertTrue(markdown.contains("groundwork"), markdown)
    }

    // MARK: - The gates

    /// The same two gates a coordinator filing faces. A well-groomed stamp whose
    /// citations resolve is `ready`.
    func testAGroundedWellGroomedStampIsReady() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])
        let gated = BacklogTemplate.gate(stamped, sources: sources(paths: ["spec.txt", "CHANGES.md"]))

        XCTAssertEqual(gated.map(\.status), [.ready, .ready])
        XCTAssertEqual(gated.flatMap(\.notes), [])
    }

    /// A template is written once and stamped for years, so a stamp is exactly
    /// where a checklist goes stale — a `verify:` naming a file that has since
    /// moved. Parked as `draft` with the reason, never queued.
    func testAStampWhoseCitationsNoLongerResolveIsParkedAsDraft() throws {
        let stamped = try parse(twoStep).stamp(values: ["version": "1.2.3"], existingIDs: [])
        let gated = BacklogTemplate.gate(stamped, sources: sources(paths: []))

        XCTAssertEqual(gated[0].status, .draft)
        XCTAssertTrue(gated[0].notes.contains { $0.contains("grounding check failed") },
                      "\(gated[0].notes)")
        XCTAssertTrue(gated[0].draft.detailMarkdown(notes: gated[0].notes).contains("## Notes"),
                      "the reason has to travel with the parked item")
    }

    /// An item missing a section the Definition-of-Ready asks for is parked too,
    /// rather than queued to fail at pickup.
    func testAStampMissingValidationIsParkedAsDraft() throws {
        let template = try parse("""
        ---
        variables: []
        ---

        ## Item

        - [ ] thin | An item with no acceptance criteria | size:XS | verify:true

        ## What

        Something.

        ## How

        Somehow.
        """)
        let gated = BacklogTemplate.gate(try template.stamp(values: [:], existingIDs: []),
                                         sources: sources(paths: []))

        XCTAssertEqual(gated[0].status, .draft)
        XCTAssertTrue(gated[0].notes.contains { $0.contains("self-check failed") }, "\(gated[0].notes)")
    }

    /// Where stamped items go: the epic the template names when the backlog has
    /// one by that name, its first section otherwise.
    func testTheSectionIsTheNamedEpicWhenTheBacklogHasIt() throws {
        let template = try parse(twoStep)
        let withReleases = BacklogFile(project: "p", sections: [
            BacklogSection(name: "Now", items: []), BacklogSection(name: "Releases", items: [])
        ])
        let without = BacklogFile(project: "p", sections: [BacklogSection(name: "Now", items: [])])

        XCTAssertEqual(template.section(in: withReleases), "Releases")
        XCTAssertEqual(template.section(in: without), "Now")
        XCTAssertEqual(template.section(in: nil), "Now")
    }

    // MARK: - Grooming skeletons

    /// Every kind's skeleton is a real, parseable single-item template — the
    /// same shape a hand-authored `templates/*.md` is read in.
    func testEveryGroomingSkeletonParses() {
        for kind in BacklogTemplate.ItemKind.allCases {
            XCTAssertEqual(kind.skeleton.items.count, 1, "\(kind)")
        }
    }

    /// Validation: "The three templates exist and each carries its kind's
    /// clause" — a bug states a repro, a feature states what a user sees
    /// change, tooling states the check or script it serves, and each is
    /// judged `ready` once its clause and the rest of the shape are filled in.
    func testEachGroomingSkeletonCarriesItsKindsClauseWhenStamped() throws {
        for kind in BacklogTemplate.ItemKind.allCases {
            let stamped = try kind.skeleton.stamp(
                values: values(for: kind, clause: "something concrete"), existingIDs: [])
            XCTAssertTrue(kind.carriesClause(stamped[0].draft.what),
                          "\(kind): \(stamped[0].draft.what)")

            let gated = kind.gate(stamped, sources: sources(paths: []))
            XCTAssertEqual(gated[0].status, .ready, "\(kind): \(gated[0].notes)")
            XCTAssertEqual(gated[0].notes, [], "\(kind)")
        }
    }

    /// Validation: "...a feature detail without [its outcome sentence] is a
    /// draft, not ready." Internal polish has no honest answer to "what does
    /// someone using the app see change" — the sentence is the steering
    /// lever, and this is what makes it structural rather than a suggestion:
    /// the item still files, but parked, with the reason attached.
    func testAFeatureSkeletonMissingItsOutcomeSentenceIsParkedAsDraftNotReady() throws {
        let stamped = try BacklogTemplate.ItemKind.feature.skeleton.stamp(
            values: values(for: .feature, clause: nil), existingIDs: [])
        XCTAssertFalse(BacklogTemplate.ItemKind.feature.carriesClause(stamped[0].draft.what))

        let gated = BacklogTemplate.ItemKind.feature.gate(stamped, sources: sources(paths: []))

        XCTAssertEqual(gated[0].status, .draft)
        XCTAssertTrue(gated[0].notes.contains { $0.contains("User-visible outcome") },
                      "\(gated[0].notes)")
    }

    /// The other two kinds are parked the same way, for the same reason —
    /// this is a property of `ItemKind.gate`, not a special case for feature.
    func testABugOrToolingSkeletonMissingItsClauseIsAlsoParkedAsDraft() throws {
        for kind: BacklogTemplate.ItemKind in [.bug, .tooling] {
            let stamped = try kind.skeleton.stamp(values: values(for: kind, clause: nil), existingIDs: [])
            let gated = kind.gate(stamped, sources: sources(paths: []))
            XCTAssertEqual(gated[0].status, .draft, "\(kind)")
        }
    }

    private func values(for kind: BacklogTemplate.ItemKind, clause: String?) -> [String: String] {
        var values: [String: String] = [
            "id": "\(kind.rawValue)-example",
            "title": "An example \(kind.rawValue) item",
            "size": "XS",
            "verify": "true",
            "what": "Something worth doing.",
            "how": "Do it.",
            "validation": "It is done.",
            "outOfScope": "Anything else."
        ]
        guard let clause else { return values }
        switch kind {
        case .bug: values["repro"] = clause
        case .feature: values["outcome"] = clause
        case .tooling: values["serves"] = clause
        }
        return values
    }

    // MARK: - The proving template

    /// `templates/release.md` in this repo, stamped end to end — the process that
    /// motivated the feature, encoded as the feature.
    func testTheReleaseTemplateStampsTheShipABuildChecklist() throws {
        let template = try releaseTemplate()

        XCTAssertEqual(template.variables.map(\.name), ["version"])
        let stamped = try template.stamp(values: ["version": "9.9.9"], existingIDs: [])

        XCTAssertEqual(stamped.map(\.draft.id), [
            "release-9.9.9-spec", "release-9.9.9-pbxproj", "release-9.9.9-changelog"
        ])
        // The ordering CLAUDE.md states in prose, as edges a machine reads: the
        // pbxproj is generated from the spec, and the CHANGELOG flip comes last.
        // Every one of them names an item of this same stamp, so nothing is
        // dropped and the checklist keeps its order.
        XCTAssertEqual(stamped.map(\.draft.needs), [
            [], ["release-9.9.9-spec"], ["release-9.9.9-pbxproj"]
        ])
        XCTAssertEqual(stamped.flatMap(\.notes), [])
        XCTAssertEqual(Set(stamped.map(\.draft.size)), ["XS"])

        // The three MARKETING_VERSION sites and the CHANGELOG heading, each
        // checked by its own item's verify.
        XCTAssertTrue(stamped[0].draft.verify.contains("Kiteloop/project.yml"),
                      stamped[0].draft.verify)
        XCTAssertTrue(stamped[1].draft.verify.contains("Kiteloop/Kiteloop.xcodeproj/project.pbxproj"),
                      stamped[1].draft.verify)
        XCTAssertTrue(stamped[2].draft.verify.contains("CHANGELOG.md"), stamped[2].draft.verify)
        XCTAssertTrue(stamped.allSatisfy { !$0.draft.verify.contains(" | ") },
                      "a spaced pipe is the backlog line's field separator — the command would truncate")
    }

    /// The constraint on the one variable, on the real template: `version=next`
    /// would otherwise be stamped into three verify commands looking for a tag
    /// nobody will push.
    func testTheReleaseTemplateRefusesSomethingThatIsNotAVersion() throws {
        let template = try releaseTemplate()

        // Surrounding whitespace is trimmed before the pattern is applied, so
        // "1.2.3 " is a version — a trailing space from a shell is not a typo
        // worth refusing a release over.
        XCTAssertNoThrow(try template.stamp(values: ["version": "1.2.3 "], existingIDs: []))

        for bad in ["next", "v1.2.3", "1.2", "1.2.3.4"] {
            XCTAssertThrowsError(try template.stamp(values: ["version": bad], existingIDs: []),
                                 "\"\(bad)\" is not a version") { error in
                guard case .constraintViolated(let name, _, _) = error as? BacklogTemplateError else {
                    return XCTFail("expected a constraint violation for \"\(bad)\", got \(error)")
                }
                XCTAssertEqual(name, "version")
            }
        }
    }

    /// Re-stamping the same release collides on every id and refuses — which is
    /// the correct guard against double-filing a release, and is the whole
    /// mechanism, since a stamped item keeps no link back to its template.
    func testReStampingTheSameReleaseRefuses() throws {
        let template = try releaseTemplate()
        let first = try template.stamp(values: ["version": "9.9.9"], existingIDs: [])

        XCTAssertThrowsError(try template.stamp(values: ["version": "9.9.9"],
                                                existingIDs: Set(first.map(\.draft.id))))
    }

    // MARK: - The store

    func testTemplatesAreReadBesideTheBacklogAndFromTheProjectRoot() throws {
        let root = try makeTempDir()
        let vault = try makeTempDir()
        try write(twoStep, to: vault.appending(path: "templates/beside-backlog.md"))
        try write(twoStep, to: root.appending(path: "templates/in-the-repo.md"))
        let backlogURL = vault.appending(path: "Backlog.md")

        let names = BacklogTemplateStore.list(backlogURL: backlogURL, projectRoot: root).map(\.name)

        XCTAssertEqual(names, ["beside-backlog", "in-the-repo"])
        XCTAssertNotNil(BacklogTemplateStore.load(named: "in-the-repo",
                                                  backlogURL: backlogURL, projectRoot: root))
        XCTAssertNil(BacklogTemplateStore.load(named: "absent",
                                               backlogURL: backlogURL, projectRoot: root))
    }

    /// The directory beside the backlog wins, so a project-local template shadows
    /// a repo one rather than both appearing under the same name.
    func testATemplateBesideTheBacklogShadowsTheRepoOne() throws {
        let root = try makeTempDir()
        let vault = try makeTempDir()
        try write(twoStep.replacingOccurrences(of: "epic: Releases", with: "epic: Beside"),
                  to: vault.appending(path: "templates/release.md"))
        try write(twoStep, to: root.appending(path: "templates/release.md"))

        let entries = BacklogTemplateStore.list(backlogURL: vault.appending(path: "Backlog.md"),
                                                projectRoot: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].template?.epic, "Beside")
    }

    /// A template that doesn't parse is listed with its reason rather than
    /// dropped: a missing name reads as "no such template" and sends whoever
    /// wrote it looking in the wrong directory.
    func testAnUnparseableTemplateIsListedWithItsError() throws {
        let root = try makeTempDir()
        try write("Just prose.", to: root.appending(path: "templates/broken.md"))

        let entries = BacklogTemplateStore.list(backlogURL: nil, projectRoot: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "broken")
        XCTAssertNil(entries[0].template)
        XCTAssertEqual(entries[0].error, BacklogTemplateError.noItems.message)
    }

    func testATemplateWithOneBadByteIsStillParsed() throws {
        let root = try makeTempDir()
        let parts = twoStep.components(separatedBy: "The spec reads {{version}}.")
        XCTAssertEqual(parts.count, 2, "the fixture's prose moved; put the bad byte somewhere else")
        var bytes = Data(parts[0].utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data(("The spec reads {{version}}." + parts[1]).utf8))
        let url = root.appending(path: "templates/bad-byte.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url)

        let entries = BacklogTemplateStore.list(backlogURL: nil, projectRoot: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].template, "a template with one bad byte was listed as \(entries[0].error ?? "nil")")
        XCTAssertNil(entries[0].error)
        let loaded = BacklogTemplateStore.load(named: "bad-byte", backlogURL: nil, projectRoot: root)
        XCTAssertEqual(loaded?.template?.items.count, 2)
    }

    // MARK: - Helpers

    /// The repo's own `templates/release.md`. This test file sits at
    /// found by walking up from this file to the checkout.
    private func releaseTemplate(file: StaticString = #filePath,
                                 line: UInt = #line) throws -> BacklogTemplate {
        let root = RepositoryRoot.of(file: file)
        let url = root.appending(path: "templates/release.md")
        let content = try String(contentsOf: url, encoding: .utf8)
        return try BacklogTemplate.parse(content, name: "release")
    }

    /// A repo holding exactly `paths`, with `grep` runnable and nothing else.
    private func sources(paths: Set<String>) -> GroundingCheck.Sources {
        GroundingCheck.Sources(
            pathExists: { paths.contains($0) },
            definesSymbol: { _ in true },
            resolvesExecutable: { $0 == "grep" || $0 == "true" },
            pathsNamed: { name in paths.filter { $0.hasSuffix(name) }.sorted() }
        )
    }

    private func makeTempDir() throws -> URL {
        try makeTemporaryDirectory(prefix: "backlog-template")
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
