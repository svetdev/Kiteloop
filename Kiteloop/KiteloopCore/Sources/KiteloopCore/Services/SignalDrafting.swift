import Foundation

/// Turns a repo instrument's finding into the item a human groomer would
/// otherwise have to write by hand — deterministically, with no model call.
/// What `CoordinatorQueueRefill` does with the result is unchanged: it maps
/// `Draft` onto its own `QueueRefill.Draft` and runs it through the same
/// Definition-of-Ready and grounding gates, and the same filing path, as
/// anything the LLM drafter proposes.
package enum SignalDrafting {

    /// One finding, turned into a fileable item's fields. Only what a detail
    /// file's frontmatter and What/How/Validation sections need —
    /// `CoordinatorQueueRefill` owns the app's own `QueueRefill.Draft` shape and
    /// maps this onto it.
    package struct Draft: Sendable, Equatable {
        package let id: String
        package let title: String
        package let size: String
        package let verify: String
        package let what: String
        package let how: String
        package let validation: [String]
        package let outOfScope: [String]

        package init(id: String, title: String, size: String, verify: String, what: String,
                    how: String, validation: [String], outOfScope: [String]) {
            self.id = id
            self.title = title
            self.size = size
            self.verify = verify
            self.what = what
            self.how = how
            self.validation = validation
            self.outOfScope = outOfScope
        }
    }

    /// What every signal-drafted item verifies with: compiling the app and its
    /// test bundles is the one check that runs whichever target a finding turns
    /// out to touch, without guessing which one that is from the finding alone
    /// — widened with the rules `.kiteloop/verify-map.json` applies to every
    /// Swift path unconditionally, `./quality/bin/check-complexity.sh` and
    /// `./quality/bin/check-layering.py`, the same way `verify_default` in
    /// `.kiteloop/backlog-tree/BACKLOG.md` has to be — and with the two rules a
    /// drafted fix reaches routinely even though they are not unconditional:
    /// the flake ledger names tests, which is where a flake fix lands, and
    /// `report-hotspots.py` ranks the package's own sources, so
    /// `scripts/run-core-tests.sh` (for `Kiteloop/KiteloopCore/**/*.swift`) and
    /// `./quality/bin/check-test-hygiene.py` (for `Kiteloop/KiteloopTests/**`
    /// and `Kiteloop/KiteloopCore/Tests/**`) belong here too. Without them,
    /// every drafted item that touches Swift — which is every instrument here
    /// — gaps on one of these before a worker even starts.
    ///
    /// Kiteloop's own, and a default only: the refill hands every draft the
    /// project's merge-verify instead (`draft(for:verify:)`).
    package static let defaultVerify: String = {
        let build = "cd \"$(git rev-parse --show-toplevel)/Kiteloop\" && "
            + "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop "
            + "-destination \"platform=macOS\" build-for-testing"
        let widenedRules = VerifyCoverage.Map(rules: [
            VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-complexity.sh"),
            VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-layering.py"),
            VerifyCoverage.Rule(glob: "Kiteloop/KiteloopCore/**/*.swift", command: "scripts/run-core-tests.sh",
                                run: "./scripts/run-core-tests.sh"),
            VerifyCoverage.Rule(glob: "Kiteloop/KiteloopTests/**", command: "./quality/bin/check-test-hygiene.py")
        ])
        return VerifyCoverage.widen(
            verify: build,
            adding: widenedRules.rules.map(\.command),
            map: widenedRules) ?? build
    }()

    /// The `verify:` a signal draft carries in a project whose merge-verify is
    /// `mergeVerify` and whose verify map is `map`. Empty — no copied chain —
    /// when the map has a rule matching every path: the merge gate runs that
    /// rule on any diff, and no instrument's finding has a check of its own,
    /// so copying the chain onto every draft only repeats it, which is how one
    /// backlog came to hold 361 distinct `verify:` lines. Otherwise
    /// `mergeVerify`, as before; nil when there is none, and nothing to draft.
    package static func verify(mergeVerify: String?, map: VerifyCoverage.Map) -> String? {
        hasCatchAll(map) ? "" : mergeVerify
    }

    /// Whether `map` has a rule reaching every path: a file at the root and one
    /// nested under a directory and extension no repo has — the rule
    /// `DefinitionOfReady` lets an item with no `verify:` lean on.
    package static func hasCatchAll(_ map: VerifyCoverage.Map) -> Bool {
        map.rules.contains { rule in
            ["zz-probe-7d1e", "zz-probe-7d1e/nested/zz-probe-7d1e.zz"]
                .allSatisfy { VerifyCoverage.matches(glob: rule.glob, path: $0) }
        }
    }

    /// Every finding turned into a draft, skipping one whose id — the
    /// deterministic id `id(for:)` derives from the finding's own instrument and
    /// stable key — is already in `existingIDs`. Two runs over the same
    /// instrument output produce the same id for the same finding, so an item
    /// already filed for it, ready or done, is not filed again.
    ///
    /// Also skipped: a finding whose *pre-cap* id — the id `id(for:)` would
    /// have returned before its 64-character cap existed — is in
    /// `existingIDs`. Capping renames a finding already filed under its
    /// longer id to a new, shorter one; without this, that finding's next
    /// pass would draft it a second time under the new id rather than
    /// recognizing it as already filed.
    package static func drafts(for findings: [SignalFinding], existingIDs: Set<String>,
                               verify: String = defaultVerify) -> [Draft] {
        findings.compactMap { finding in
            let draft = draft(for: finding, verify: verify)
            guard !existingIDs.contains(draft.id), !existingIDs.contains(preCapID(for: finding)) else { return nil }
            return draft
        }
    }

    /// `verify` is the command the drafted item will run — the project's own
    /// merge-verify, which the refill passes. The default is Kiteloop's, and
    /// it is a default only for a caller that has nothing better: on a Rust
    /// project every one of seven hotspot items drafted with it carried an
    /// `xcodebuild` it could not run.
    package static func draft(for finding: SignalFinding, verify: String = defaultVerify) -> Draft {
        switch finding.instrument {
        case .flake: return flakeDraft(finding, verify: verify)
        case .hotspot: return hotspotDraft(finding, verify: verify)
        case .escapedDefect: return escapedDefectDraft(finding, verify: verify)
        case .redSuite: return redSuiteDraft(finding, verify: verify)
        }
    }

    /// The id a finding would file as — its instrument and stable key, reduced
    /// to what a backlog line and a filename both accept, and capped at 64
    /// characters the same way `QueueRefill.Draft.slug` caps a model-drafted
    /// id. Exposed so a caller checking `existingIDs` for one finding without
    /// drafting the rest of them can ask the same question
    /// `drafts(for:existingIDs:)` answers internally.
    package static func id(for finding: SignalFinding) -> String {
        String(preCapID(for: finding).prefix(64))
    }

    /// `id(for:)` before its 64-character cap. Kept so a finding already
    /// filed under this longer id — from before the cap existed — is still
    /// recognized as filed rather than drafted again under its new, shorter
    /// one; see `drafts(for:existingIDs:)` and `CoordinatorQueueRefill.signalDrafts`,
    /// which widens the same skip outside the package.
    package static func preCapID(for finding: SignalFinding) -> String {
        let prefix = idPrefix(for: finding.instrument)
        var slug = slugSource(for: finding).lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        if finding.instrument == .escapedDefect {
            while slug.hasPrefix("\(prefix)-") { slug.removeFirst(prefix.count + 1) }
        }
        return "\(prefix)-\(slug)"
    }

    /// The word an instrument's ids all begin with, so a filed item says at a
    /// glance which instrument found it.
    private static func idPrefix(for instrument: SignalFinding.Instrument) -> String {
        switch instrument {
        case .flake: return "flaky-test"
        case .hotspot: return "hotspot"
        case .escapedDefect: return "escaped-defect"
        case .redSuite: return "red-suite"
        }
    }

    /// What `id(for:)` slugs. A hotspot's `key` is `file:line`, and the line
    /// moves every time code shifts above the declaration — so the same
    /// function would file a new item every time it does. Slug the file plus
    /// the declared name read out of `title` instead, so the id tracks the
    /// declaration rather than where it currently sits; when no name can be
    /// read, fall back to the whole key so an unparsed row still gets a
    /// unique id rather than colliding with every other unparsed row in its
    /// file.
    private static func slugSource(for finding: SignalFinding) -> String {
        guard finding.instrument == .hotspot else { return finding.key }
        guard let name = declaredName(in: finding.title) else { return finding.key }
        let file = finding.key.lastIndex(of: ":").map { String(finding.key[..<$0]) } ?? finding.key
        return "\(file)-\(name)"
    }

    /// The declaration keywords `report-hotspots.py`'s title line can start
    /// with, once any access modifiers are stripped away. The report is not
    /// Swift-only — `quality.json`'s `complexity.languages` also measures
    /// Python and TypeScript — so `def` and `function` are here beside the
    /// Swift forms, and a hotspot in either language keeps one id across a
    /// line move the way a Swift one does.
    private static let declarationKeywords: Set<String> = [
        "func", "var", "let", "class", "struct", "enum", "protocol", "extension",
        "def", "function"
    ]

    /// The identifier following a declaration keyword in a hotspot's `title`
    /// — `func doThing()` or `private func hotspotFindings(repoRoot: URL) ->
    /// [SignalFinding] {` reads as `doThing` / `hotspotFindings` — stopping
    /// at the first `(`, `<`, `:` or whitespace. The same read serves the
    /// report's other languages, whose declarations name themselves the same
    /// way: `def marathon(client, report` reads as `marathon`, and
    /// `export function activate(context: vscode.ExtensionContext): void {`
    /// as `activate`. An initializer is a special
    /// case: Swift writes `init(` with no space before the paren, so `init`
    /// never stands alone as a token the way `func`'s name does — matched by
    /// prefix instead, and read as its whole signature (`init` plus its
    /// parameter list) rather than the bare word `init`, so two initializers
    /// in the same file — an overload, or a different type's own `init` —
    /// still slug to different ids. Nil when neither is found in `title`.
    private static func declaredName(in title: String) -> String? {
        let tokens = title.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if isInitializerToken(token) { return initializerSignature(in: title, from: token) }
            guard declarationKeywords.contains(token), index + 1 < tokens.count else { continue }
            let name = tokens[index + 1].prefix { $0 != "(" && $0 != "<" && $0 != ":" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// Whether `token` is `init` itself, or `init` immediately followed by
    /// what starts its parameter list or failability marker — `init(`,
    /// `init?(`, `init!(`, `init<T>(` — rather than an identifier that merely
    /// starts with the letters "init", like `initialValue`.
    private static func isInitializerToken(_ token: String) -> Bool {
        guard token.hasPrefix("init") else { return false }
        let boundary = token.index(token.startIndex, offsetBy: 4)
        guard boundary < token.endIndex else { return true }
        let next = token[boundary]
        return next == "(" || next == "?" || next == "!" || next == "<"
    }

    /// `title` from `token`'s own `init` up to the opening brace of its body
    /// (or the end of `title`, for a protocol requirement with none) —
    /// `init(path: String, projectRoot: String)`, parameter labels and types
    /// included, so overloaded initializers slug to distinct ids the way a
    /// differently-named function already does.
    private static func initializerSignature(in title: String, from token: String) -> String {
        guard let start = title.range(of: token)?.lowerBound else { return "init" }
        let rest = title[start...]
        let signature = rest.split(separator: "{", maxSplits: 1).first.map(String.init) ?? String(rest)
        return signature.trimmingCharacters(in: .whitespaces)
    }

    private static func flakeDraft(_ finding: SignalFinding, verify: String) -> Draft {
        let evidence = finding.evidence.joined(separator: "; ")
        return Draft(
            id: id(for: finding),
            title: "Fix flaky test: \(finding.title)",
            size: "S",
            verify: verify,
            what: "\(finding.title) flips outcome with no code change — the flake ledger "
                + "records \(evidence).",
            how: "Read \(finding.title) and find the source of nondeterminism — shared "
                + "state, timing, or an ordering assumption the suite's parallel runs break — "
                + "and make its result independent of when or beside what it runs.",
            validation: [
                "\(finding.title) passes on repeated runs without flipping.",
                "The source of nondeterminism is named, and a test or assertion pins it — "
                    + "failing without the fix, passing with it."
            ],
            outOfScope: ["Any other test the flake ledger does not name."]
        )
    }

    private static func hotspotDraft(_ finding: SignalFinding, verify: String) -> Draft {
        let evidence = finding.evidence.joined(separator: "; ")
        return Draft(
            id: id(for: finding),
            title: "Refactor hotspot: \(finding.title)",
            size: "S",
            verify: verify,
            // Backticked, so `GroundingCheck` looks the file up: a hotspot item
            // was filed on 2026-09-19 for a file that had become a directory,
            // and nothing refused it because its one backticked path was the
            // report script's. The `:line` is stripped before the lookup.
            what: "`\(finding.key)` is both complex and frequently changed — \(evidence).",
            how: "Read `\(finding.key)` and split it so each piece changes for one reason — the "
                + "same split that would drop it out of `quality/bin/report-hotspots.py`'s top ranks.",
            validation: [
                "`\(finding.key)`'s hotspot score has measurably dropped, or it no longer "
                    + "appears in `quality/bin/report-hotspots.py`'s top ranks.",
                "Existing tests covering it still pass."
            ],
            outOfScope: ["Any other function the hotspot report does not name."]
        )
    }

    /// A test the newest recorded row names as not having passed. Deliberately
    /// not worded as a flake: the flake ledger's draft asks for the source of
    /// nondeterminism, and this finding carries no evidence of any — one red
    /// row says the test did not pass on that tree, and whether the code or the
    /// test is the wrong one is exactly what the item asks to be established.
    private static func redSuiteDraft(_ finding: SignalFinding, verify: String) -> Draft {
        let evidence = finding.evidence.joined(separator: "; ")
        return Draft(
            id: id(for: finding),
            title: "Fix failing test: \(finding.title)",
            size: "S",
            verify: verify,
            what: "\(finding.title) did not pass in the newest recorded suite run — \(evidence).",
            how: "Run \(finding.title) and find out why it does not pass — a regression in the "
                + "code it covers, or an assumption the test itself has outlived — then fix "
                + "whichever of the two is actually wrong.",
            validation: [
                "\(finding.title) passes.",
                "Which of the code and the test was wrong is named, and the fix is the one that "
                    + "follows from that."
            ],
            outOfScope: ["Any other test the newest recorded suite row does not name."]
        )
    }

    private static func escapedDefectDraft(_ finding: SignalFinding, verify: String) -> Draft {
        let evidence = finding.evidence.joined(separator: "; ")
        return Draft(
            id: id(for: finding),
            title: "Escaped defect: \(finding.title)",
            size: "S",
            verify: verify,
            what: "\(finding.title) was approved and later reopened — \(evidence). Whatever "
                + "review missed the first time is still there.",
            how: "Read what changed for \(finding.title) and why it came back, then fix the "
                + "defect that escaped rather than only the symptom that reopened it.",
            validation: [
                "The defect that reopened \(finding.title) is fixed.",
                "The fix is covered by a test that would have caught it."
            ],
            outOfScope: ["Any other item the escaped-defect record does not name."]
        )
    }
}
