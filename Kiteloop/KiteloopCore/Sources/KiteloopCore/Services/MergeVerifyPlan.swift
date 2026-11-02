import Foundation

/// What must pass on the merged tree before a merge into `main` is kept.
///
/// A project's `autoMergeVerifyCommand` used to be read as a *replacement* for
/// the item's own `verify:` — `configured ?? item.verify` — so the last gate
/// before `main` could be weaker than the one the work was built against, and
/// nothing said so.
///
/// That shipped. On 2026-08-10 a Rust-and-web project's merge command was a web-only
/// `npm test` while the item changed only Rust — one API route and its test.
/// The merge gate ran the web suite
/// against a Rust diff, passed, and merged. The item's own verify was the full
/// local CI script that compiles the Rust; it never ran, because the
/// project-level command won. The advisory quality judge scored that run
/// `verify_passed: 0.15` — the subjective check caught what the objective gate
/// missed, which is exactly the wrong way round.
///
/// So a project-level command is an **addition** to the item's verify, never a
/// substitute: both run, both must pass, and the plan names what it ran so a
/// merge validated by an unrelated suite is visible in the log afterwards
/// instead of needing the diff and the config compared by hand.
///
/// This is the floor. Whether a command actually *covers* what the diff touched
/// is `VerifyCoverage`'s question, and it needs a map a project has to write;
/// this holds with nothing configured at all.
package struct MergeVerifyPlan: Equatable, Sendable {

    /// Where a command in the plan came from. Recorded rather than derived,
    /// because "which command gated this merge" is the question the incident
    /// above could not be answered from.
    package enum Source: String, Equatable, Sendable {
        /// The item's own `verify:` — the bar the work was built against, and
        /// the floor no merge may clear less of.
        case item = "item verify"
        /// The project's `autoMergeVerifyCommand`.
        case project = "merge-verify"
    }

    /// One command the merged tree has to survive.
    package struct Step: Equatable, Sendable {
        package let source: Source
        /// Exactly as configured — this is what gets run.
        package let command: String

        /// `item verify: swift build` — how the step is named in a run log, a
        /// refusal reason and a metric record. The command is collapsed to one
        /// line and bounded so a chained CI script can't turn a log line into a
        /// paragraph; the whole of it is still in `command`.
        package var label: String {
            "\(source.rawValue): \(MergeVerifyPlan.condense(command))"
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(source: Source, command: String) {
            self.source = source
            self.command = command
        }
    }

    /// In the order they run.
    package let steps: [Step]

    package var isEmpty: Bool { steps.isEmpty }
    /// The commands themselves, in run order.
    package var commands: [String] { steps.map(\.command) }
    /// The steps as they are named in logs and records, in run order.
    package var labels: [String] { steps.map(\.label) }

    /// One line naming what gated the merge. `none` when nothing did — a merge
    /// nothing checked is precisely the fact worth having in the log.
    package var summary: String { steps.isEmpty ? "none" : labels.joined(separator: " + ") }

    /// Nothing to run: no project command and no item verify.
    package static let none = MergeVerifyPlan(steps: [])

    /// The plan for one merge.
    ///
    /// The item's verify runs **first**: it is the check the diff was built
    /// against, so it is the one most likely to have something to say about it,
    /// and a failure there costs nothing more than the broader project suite it
    /// would otherwise have waited behind. Blank commands are dropped, and a
    /// project command identical to the item's runs once — the same work twice
    /// is only a slower gate, not a stronger one.
    package static func resolve(projectCommand: String?, itemVerify: String?) -> MergeVerifyPlan {
        resolve(rules: projectCommand.map { [catchAll($0)] } ?? [], paths: nil, itemVerify: itemVerify)
    }

    /// `command` as a rule matching every path — how a project with no map
    /// says what its gate runs.
    package static func catchAll(_ command: String) -> VerifyCoverage.Rule {
        VerifyCoverage.Rule(glob: "**", command: command)
    }

    /// The plan for one merge, read off the verify map: the item's own checks,
    /// then every rule whose glob one of the diff's `paths` matches, in map
    /// order — each command once.
    ///
    /// A project without a map passes the command it has always run as one
    /// rule matching every path (`**`), so what its gate runs is unchanged.
    /// `paths` nil means the diff could not be read; then every rule runs,
    /// because a gate that cannot tell what changed must not run less.
    package static func resolve(rules: [VerifyCoverage.Rule], paths: [String]?,
                                itemVerify: String?) -> MergeVerifyPlan {
        let matched = rules.filter { rule in
            paths?.contains { VerifyCoverage.matches(glob: rule.glob, path: $0) } ?? true
        }
        var steps: [Step] = []
        var seen: Set<String> = []
        let candidates = [(Source.item, itemVerify)] + matched.map { (Source.project, $0.runnable) }
        for (source, raw) in candidates {
            let command = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, seen.insert(collapsed(command)).inserted else { continue }
            steps.append(Step(source: source, command: command))
        }
        return MergeVerifyPlan(steps: steps)
    }

    /// The one line worth logging when the project's merge-verify is the
    /// item's own verify **plus flags** — `gate.py` for the work, `gate.py
    /// --strict` at the gate. The judge and the run score the work against the
    /// first; the merge is then refused by the second, and the refusal reads
    /// as the item's fault. Nil when the two commands share no such prefix.
    /// Extra flags are only ever a stricter bar, so the plan still runs both;
    /// this only says so out loud, once, where the gate is configured.
    package var flagDriftWarning: String? {
        guard let item = steps.first(where: { $0.source == .item }),
              let project = steps.first(where: { $0.source == .project }) else { return nil }
        let base = Self.collapsed(item.command)
        let full = Self.collapsed(project.command)
        guard full.hasPrefix(base + " ") else { return nil }
        let extra = String(full.dropFirst(base.count)).trimmingCharacters(in: .whitespaces)
        return "merge-verify is the item's verify with extra flags (\(extra)) — the work was built and "
             + "judged against the weaker bar, so a refusal here is the project's gate, not the item"
    }

    /// How much of a command a label carries. Enough to tell an `npm --prefix
    /// apps/web test` from a `./scripts/ci.sh` at a glance, short enough to sit
    /// in a log line beside everything else the merge is reporting.
    package static let maxLabelCommandLength = 160

    /// A command as a single line, whole: whitespace runs collapsed so a command
    /// written across two lines reads the same as one written across one.
    ///
    /// This, and not `condense`, is what deciding whether two commands are the
    /// same has to compare. `condense` truncates, so comparing on it made every
    /// pair of commands agreeing on their first `maxLabelCommandLength`
    /// characters — two long CI invocations differing only in a trailing flag,
    /// say — a duplicate, and the second one silently never ran. That is the
    /// same silently-weaker merge gate this type exists to stop, reached from
    /// the other end.
    package static func collapsed(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A command as a single **bounded** line — `collapsed`, then truncated with
    /// an ellipsis past `maxLabelCommandLength`. For labels only; the whole
    /// command is always in `Step.command`.
    package static func condense(_ command: String) -> String {
        let oneLine = collapsed(command)
        guard oneLine.count > maxLabelCommandLength else { return oneLine }
        return oneLine.prefix(maxLabelCommandLength) + "…"
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(steps: [Step]) {
        self.steps = steps
    }
}
