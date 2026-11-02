import Foundation

/// The Operational Design Domain gate: what a backlog item has to carry before
/// autopilot will run it unattended.
///
/// The rules are Kiteloop's Definition-of-Ready (`CLAUDE.md` → Autonomy) — a
/// groomed detail file with What/How/Validation, a `verify:` command, and a size
/// of M or smaller. They were prose a groomer was trusted to have followed, and
/// only the size half was ever enforced. An ungroomed item that slipped through
/// spent a full worker/reviewer cycle discovering it had nothing to build
/// against, then blocked on its own vagueness. Checking the list at pickup turns
/// that into a skip with a reason.
///
/// The fourth ODD bullet — an explicit out-of-scope list — is deliberately not
/// enforced here. An empty one is a legitimate statement ("nothing is off
/// limits") and reads identically to an unwritten one, so blocking on it would
/// fail items that are genuinely ready. A missing What, verify or size cannot be
/// read that way: each is unambiguously ungroomed.
///
/// A `verify:` also has to be *writable on a backlog line*, which is why the
/// spaced-pipe clause sits alongside the one that asks whether there is a
/// command at all: a command the line would truncate is worse than none, since
/// the shortened half still passes and the merge gate still opens. The title has
/// to be writable there too, and is refused on the same grounds: a title the
/// line splits is filed shorter than the one that was groomed.
///
/// A line's `needs:<id>` is judged here too, when the caller supplies the
/// backlog to resolve it against: an item whose prerequisite isn't `done` is not
/// ready however well it is written. That used to be prose in an epic preamble
/// and cost the same kind of run — a worker sent to build on something that
/// didn't exist yet.
///
/// Pure and free of run state on purpose. The verdict is a function of the item,
/// its detail file and the backlog it sits in, so the autopilot's queue filter
/// and anything reporting *why* an item can't run reach the same answer.
package enum DefinitionOfReady {

    /// One clause of the Definition-of-Ready. Declared in the order a verdict
    /// lists them — the detail file, then its sections, then the item line's own
    /// fields — so the same ungroomed item always reads the same way.
    package enum Requirement: String, CaseIterable, Sendable {
        /// A groomed `backlog/<id>.md` exists and parses. Reported instead of the
        /// three section requirements below when there is no file at all: the one
        /// fix is to write it, and listing its missing sections as well would say
        /// that four times.
        case detail
        case what
        case how
        case validation
        /// A `verify:` command — from the detail's frontmatter, or the item line
        /// (which already inherits the backlog's `verify_default` at parse time).
        /// Met without one when the project's verify map has a rule matching
        /// every path: the merge gate runs that rule on every diff, so an item's
        /// own `verify:` only adds checks particular to it.
        case verify
        /// The item line's `verify:` holds the line's own field separator, so
        /// what it says is not what would run. Reported beside `.verify` rather
        /// than as part of it: the command is there, it is just written in a way
        /// the line cannot carry.
        case verifySeparator
        /// The title holds the line's own field separator, so the title on disk
        /// would be shorter than the one that was groomed. Same shape as
        /// `.verifySeparator`, one field to the left.
        case titleSeparator
        /// A size is set at all. An unsized item can't be shown to be ≤ M, and an
        /// item nobody sized is one nobody groomed.
        case size
        /// Sized L or XL: real work, but not for an unattended run.
        case sizeTooLarge
        /// Marked `flow:qa` in a project with no usable `kiteloop-qa.json`: the
        /// QA stages would have nothing to run the app with.
        case qaProfile
        /// A `needs:<id>` on the line naming an item that isn't `done`. The only
        /// clause that isn't about how the item is written, so it is reported
        /// last — and the only one that can fail more than once, once per unmet
        /// dependency, because "wait for one of these three" is not a thing an
        /// item can say.
        case dependency
    }

    /// The rest of the backlog, as the dependency clause has to see it.
    ///
    /// Every other clause is a function of the item and its detail file alone;
    /// `needs:` is the one that has to ask about ids the item merely names, so a
    /// caller that can answer that supplies this and a caller that can't leaves
    /// it out. Omitting it doesn't pass dependencies — it makes the clause
    /// silent. Somewhere with no backlog to resolve against (grading a proposed
    /// draft, say) has no basis to call a dependency unmet, and inventing one
    /// would refuse every drafted item that states a sequence.
    package struct Dependencies: Sendable {
        private let statusByID: [String: BacklogItemStatus]
        private let needsByID: [String: [String]]

        package init(items: [BacklogItem]) {
            var statuses: [String: BacklogItemStatus] = [:]
            var needs: [String: [String]] = [:]
            for item in items where statuses[item.id] == nil {
                // First line wins on a repeated id, which is what the parser's
                // own duplicate-id issue already tells the user is ambiguous.
                statuses[item.id] = item.status
                needs[item.id] = item.needs
            }
            statusByID = statuses
            needsByID = needs
        }

        package init(file: BacklogFile) {
            self.init(items: file.sections.flatMap(\.items))
        }

        /// One phrase per dependency of `item` that is not satisfied, in the order
        /// the line lists them. Empty when every id it names is `done` — the only
        /// state that satisfies a dependency, since a `ready`, `active` or
        /// `blocked` prerequisite is precisely the thing that isn't built yet.
        ///
        /// A satisfied dependency is answered before any path is walked. The cycle
        /// probe used to run first, so the one state that *clears* the clause was
        /// never consulted once a loop was found: two items naming each other kept
        /// reading as a cycle after one of them shipped, and the survivor was
        /// withheld at every pass with a reason no edit to it could clear.
        package func unmet(for item: BacklogItem) -> [String] {
            item.needs.compactMap { dependency in
                guard statusByID[dependency] != .done else { return nil }
                if let cycle = cycle(from: item.id, through: dependency) {
                    return "needs \(dependency) — dependency cycle: \(cycle.joined(separator: " → "))"
                }
                guard let status = statusByID[dependency] else {
                    return "needs \(dependency) — no such item"
                }
                return "needs \(dependency) — not done (\(status.rawValue))"
            }
        }

        /// The shortest path `start → dependency → … → start`, when following
        /// `needs:` from `dependency` leads back to the item that named it.
        ///
        /// Two items waiting on each other are both stuck forever, and reported as
        /// merely "not done" that reads like a queue that will sort itself out.
        /// Walking breadth-first also means a cycle is detected rather than
        /// followed, so a self-referential backlog can't hang the gate.
        ///
        /// Package-visible so the item page can refuse a `needs:` edit that
        /// would close a loop before it is written, with the path it would close.
        package func cycle(from start: String, through dependency: String) -> [String]? {
            var queue: [[String]] = [[dependency]]
            var seen: Set<String> = [dependency]
            while !queue.isEmpty {
                let path = queue.removeFirst()
                guard let tail = path.last else { continue }
                if tail == start { return [start] + path }
                for next in needsByID[tail] ?? [] {
                    if next == start { return [start] + path + [start] }
                    guard !seen.contains(next) else { continue }
                    seen.insert(next)
                    queue.append(path + [next])
                }
            }
            return nil
        }
    }

    /// The gate's answer, with the unmet clauses both as values (for a caller
    /// that wants to branch on them) and as phrasing (for the run log and the
    /// control API's error body).
    package struct Verdict: Equatable, Sendable {
        /// Empty when the item is inside the ODD.
        package let unmet: [Requirement]
        /// One phrase per unmet requirement, in `unmet` order, written for
        /// whoever has to groom the item rather than for the check that failed.
        package let reasons: [String]

        package var isReady: Bool { unmet.isEmpty }

        /// The whole verdict on one line — what a skip log entry quotes.
        package var summary: String { reasons.joined(separator: "; ") }

        package static let ready = Verdict(unmet: [], reasons: [])
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(unmet: [Requirement], reasons: [String]) {
            self.unmet = unmet
            self.reasons = reasons
        }
    }

    /// Judges one item against the Definition-of-Ready.
    ///
    /// - Parameters:
    ///   - item: the backlog line, whose `verify` and `size` are already resolved
    ///     against the file's defaults by the parser.
    ///   - detail: its groomed `backlog/<id>.md`, or nil when it has none.
    ///   - dependencies: the rest of the backlog, for resolving the line's
    ///     `needs:`. Nil leaves that clause unjudged — see `Dependencies`.
    ///   - verifyMapCoversEveryPath: whether the project's verify map has a rule
    ///     matching every path. When it does, the merge gate checks every diff
    ///     whether or not the item names a command, so the `verify` clause
    ///     passes without one.
    ///   - qaProfile: what reading the project's `kiteloop-qa.json` found. Nil
    ///     leaves the QA clause unjudged, as `dependencies` does; a `flow:qa`
    ///     item fails it when the project has no usable profile.
    package static func evaluate(item: BacklogItem, detail: BacklogItemDetail?,
                         dependencies: Dependencies? = nil, verifyMapCoversEveryPath: Bool = false,
                         qaProfile: QAProfile.Load? = nil) -> Verdict {
        var unmet: [Requirement] = []
        var reasons: [String] = []
        func fail(_ requirement: Requirement, _ reason: String) {
            unmet.append(requirement)
            reasons.append(reason)
        }

        if let detail {
            if isBlank(detail.what) { fail(.what, "detail file has no What section") }
            if isBlank(detail.approach) { fail(.how, "detail file has no How section") }
            if !detail.acceptanceCriteria.contains(where: { !isBlank($0) }) {
                fail(.validation, "detail file has no Validation criteria")
            }
        } else if !isGroomedInline(item) {
            fail(.detail, "no groomed detail file — write backlog/\(item.id).md with What/How/Validation")
        }

        if !isVerifyMet(item: item, detail: detail, verifyMapCoversEveryPath: verifyMapCoversEveryPath) {
            fail(.verify, "no verify: command — nothing objective for the run to pass")
        }
        for (requirement, reason) in separatorFailures(item) { fail(requirement, reason) }

        switch effectiveSize(item: item, detail: detail) {
        case nil:
            fail(.size, "no size set — autopilot runs XS/S/M")
        case let size? where size.isTooLargeForAutopilot:
            fail(.sizeTooLarge, "size \(size.rawValue) is too large for autopilot — break it down first")
        default:
            break
        }

        if item.flow == .qa, let reason = qaProfileReason(qaProfile) { fail(.qaProfile, reason) }

        // Sequencing last: an item can be groomed to the letter and still have to
        // wait, and the fix for that is time rather than an edit — so it reads
        // after everything the groomer could act on.
        if let dependencies {
            for reason in dependencies.unmet(for: item) { fail(.dependency, reason) }
        }

        return Verdict(unmet: unmet, reasons: reasons)
    }

    /// The fields on the item's line that hold the line's own separator, each
    /// with what to do about it — a `verify:` or a title that would split.
    static func separatorFailures(_ item: BacklogItem) -> [(Requirement, String)] {
        var failures: [(Requirement, String)] = []
        if verifyHoldsFieldSeparator(item) {
            failures.append((.verifySeparator,
                 "verify: contains the field separator \"\(fieldSeparator)\" — write the pipe "
                 + "unspaced (`a|b`), or the line splits there and a shorter command runs"))
        }
        if titleHoldsFieldSeparator(item) {
            failures.append((.titleSeparator,
                 "title contains the field separator \"\(fieldSeparator)\" — write the title "
                 + "without it, or the line splits there and a shorter title is filed"))
        }
        return failures
    }

    /// Why a `flow:qa` item cannot run in a project whose profile read as
    /// `load`, or nil when it can — or when nobody asked (`load` nil).
    static func qaProfileReason(_ load: QAProfile.Load?) -> String? {
        switch load {
        case nil, .profile?: return nil
        case .absent?: return "flow:qa needs the project onboarded for QA — add \(QAProfile.fileName) at the root"
        case .unreadable(let reason)?: return "flow:qa cannot run: \(reason)"
        }
    }

    /// Some projects groom **inline** rather than in a detail file — the item
    /// line itself carries `WHAT: … HOW: … VALIDATE: …`. That is the convention
    /// another project uses, and it produced 10 of 11 merged items on
    /// 2026-08-06, so it is a groomed item by any meaningful standard. The gate
    /// must not refuse it for putting the same content in the line rather than
    /// in a separate file.
    package static func isGroomedInline(_ item: BacklogItem) -> Bool {
        let haystack = item.title.uppercased()
        return haystack.contains("WHAT:") && haystack.contains("HOW:")
            && (haystack.contains("VALIDATE") || haystack.contains("VALIDATION"))
    }

    /// The size the gate judges: the backlog line's, falling back to the detail
    /// frontmatter's when the line carries none — `size: m` in the groomed file is
    /// the same statement, and shouldn't cost the item its run for being written
    /// in one place rather than the other.
    package static func effectiveSize(item: BacklogItem, detail: BacklogItemDetail?) -> ItemSize? {
        if let size = item.size { return size }
        let raw = (detail?.size ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return ItemSize(rawValue: raw.uppercased())
    }

    /// Whether anything would actually be run to check the work. A groomed
    /// command wins; the item line's own `verify:` is the fallback, matching how
    /// `BacklogAutopilot.salvageVerifyCommand` picks one.
    package static func hasVerifyCommand(item: BacklogItem, detail: BacklogItemDetail?) -> Bool {
        if let detail, detail.verifyCommands.contains(where: { !isBlank($0.cmd) }) { return true }
        return !isBlank(item.verify)
    }

    /// The `verify` clause: a command to run, or a verify map whose rule
    /// matching every path the merge gate runs in its place.
    private static func isVerifyMet(item: BacklogItem, detail: BacklogItemDetail?,
                                    verifyMapCoversEveryPath: Bool) -> Bool {
        verifyMapCoversEveryPath || hasVerifyCommand(item: item, detail: detail)
    }

    /// What `BacklogParser.parseItemLine` splits an item line's fields on, and
    /// therefore what a `verify:` or a title may not contain. Not the parser's constant
    /// because the parser has none — it splits on the literal — but the same
    /// three characters, and changing either without the other is the bug.
    package static let fieldSeparator = " | "

    /// Whether the item line's own `verify:` is written with a spaced shell
    /// pipe, which *is* the field separator.
    ///
    /// The cost is silent. `BacklogParser` splits the line on `" | "`, so the
    /// command is truncated at the pipe and its tail dropped as an unrecognised
    /// field — no error, no warning — and `BacklogAutopilot.mergeVerifyPlan` then
    /// gates the auto-merge on the first half of what the author wrote.
    /// `CLAUDE.md` has stated the rule for anyone writing a `verify:` since
    /// before this clause existed; nothing enforced it.
    ///
    /// Only `item.verify` is inspected. A detail file's verify commands are read
    /// from YAML rather than a split line, so a spaced pipe there runs exactly as
    /// written and is legitimate — refusing it would refuse a command that works.
    /// That also makes this clause inert at pickup: a `verify` the parser
    /// produced cannot hold the string it split on. It fires at grooming, where
    /// the drafted command is still verbatim.
    package static func verifyHoldsFieldSeparator(_ item: BacklogItem) -> Bool {
        (item.verify ?? "").contains(fieldSeparator)
    }

    /// Whether the title holds the field separator, which the line cannot carry
    /// any more than a `verify:` can.
    ///
    /// The same silence, one field to the left. `BacklogSerializer.serializeItem`
    /// writes the title as the second field of a `" | "`-joined line and
    /// `BacklogParser` reads it back as `parts[1]`, so everything past the
    /// separator is collected as an unrecognised field and dropped on the next
    /// write-back: the title on disk is shorter than the one that was groomed,
    /// with no error and no warning, and the tail may be read as a field it was
    /// never meant to be.
    ///
    /// Inert at pickup for the same reason `verifyHoldsFieldSeparator` is — a
    /// title the parser produced cannot hold the string it split on — so it fires
    /// at grooming, where the drafted title is still verbatim.
    package static func titleHoldsFieldSeparator(_ item: BacklogItem) -> Bool {
        item.title.contains(fieldSeparator)
    }

    private static func isBlank(_ text: String?) -> Bool {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
