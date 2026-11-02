import Foundation
import KiteloopCore

/// Where a ledger and git say different things about the same item.
///
/// Shown, never resolved. Smoothing these over is what let five items sit marked
/// done on 2026-08-09 with their work on unmerged branches: every individual
/// source was self-consistent, and the only signal that something was wrong was
/// that they did not agree with each other.
struct ItemDisagreement: Identifiable, Equatable, Sendable {
    /// What the recorded history claims.
    let ledgerSays: String
    /// What git says right now.
    let gitSays: String
    var id: String { ledgerSays + "|" + gitSays }
}

/// The disagreement rules, over values already read.
///
/// Pure, so every rule is exercised without a repository: the git reading is an
/// `ItemGitTruth` value, the ledger side is the item's status and its most
/// recent run.
enum ItemDisagreements {

    /// - Parameters:
    ///   - status: the item's stage, as the backlog file has it.
    ///   - latestRun: the newest recorded run for this item, or nil if it has
    ///     never run.
    ///   - git: what git answered just now.
    static func detect(status: BacklogItemStatus,
                       latestRun: TaskMetricRecord?,
                       git: ItemGitTruth) -> [ItemDisagreement] {
        // Nothing to disagree with. An unreadable repo is not evidence of
        // anything, and reporting it as a conflict would put a permanent false
        // alarm on every non-git project.
        guard !git.isUnreadable else { return [] }

        var out: [ItemDisagreement] = []
        let ahead = git.commitsAhead ?? 0

        // The one that cost five items: accepted, with the work still on a
        // branch nobody merged.
        if status == .done, git.presence == .present, git.merged == false, ahead > 0 {
            out.append(ItemDisagreement(
                ledgerSays: "the item is Done",
                gitSays: "\(git.branch) is not merged — \(commits(ahead)) \(ahead == 1 ? "exists" : "exist") only there"))
        }

        // A run that recorded a merge, against a branch that is still ahead.
        if latestRun?.merged == true, git.merged == false, ahead > 0 {
            out.append(ItemDisagreement(
                ledgerSays: "the last run recorded a merge",
                gitSays: "\(git.branch) is not merged — \(commits(ahead)) \(ahead == 1 ? "exists" : "exist") only there"))
        }

        // Work recorded, and no branch left holding it. The branch may have been
        // deleted by a teardown, in which case the commits are dangling rather
        // than gone — which is exactly the thing a reader has to be told to go
        // look for.
        var saidTheBranchIsGone = false
        if let latestRun, let files = latestRun.changedFileCount, files > 0,
           git.presence == .absent {
            saidTheBranchIsGone = true
            out.append(ItemDisagreement(
                ledgerSays: "the last run recorded \(files) changed file\(files == 1 ? "" : "s")",
                gitSays: "there is no branch \(git.branch) now"))
        }

        // Done, with no branch and this item's commits still in the object store
        // — the unmerged-branch case above minus the ref that would have made it
        // visible. Teardown dropped the branch, the work survived unreferenced,
        // and nothing points at it: the ledger says shipped and git holds
        // commits `HEAD` has never seen.
        //
        // Only said when the clause above has not already reported the missing
        // branch: one absence, one sentence, and the header already carries the
        // "still in the object store" reading (`ItemGitTruth.summary`).
        if status == .done, git.presence == .absent, git.orphanedCommits == true,
           !saidTheBranchIsGone {
            out.append(ItemDisagreement(
                ledgerSays: "the item is Done",
                gitSays: "there is no branch \(git.branch) — its commits are still in "
                    + "the object store, unreferenced"))
        }

        // The mirror image: a run recorded as empty, over a branch that carries
        // commits. `== .empty`, since `.unknown` is "nobody measured", not a claim.
        if let latestRun, latestRun.workEvidence == .empty,
           git.presence == .present, ahead > 0 {
            out.append(ItemDisagreement(
                ledgerSays: "the last run is recorded as having produced no work",
                gitSays: "\(git.branch) carries \(commits(ahead)) HEAD cannot reach"))
        }

        // Merged work under an item nobody moved on.
        if status != .done, git.merged == true {
            out.append(ItemDisagreement(
                ledgerSays: "the item is \(status.displayName)",
                gitSays: "\(git.branch) is already merged into HEAD"))
        }

        return out
    }

    private static func commits(_ n: Int) -> String {
        "\(n) commit\(n == 1 ? "" : "s")"
    }
}

/// One clause of the Definition-of-Ready, as the item detail view shows it.
struct ItemReadinessRow: Identifiable, Equatable, Sendable {

    /// The gate clause this row reports. A met size row carries `.size` and a
    /// refused one `.sizeTooLarge`, exactly as the verdict spells them — the row
    /// reports which clause answered, not a display category of its own.
    let requirement: DefinitionOfReady.Requirement

    /// What is being checked, in the few words a checklist line needs.
    let clause: String

    /// The gate's own sentence for why the clause is unmet, verbatim; nil when
    /// it is met.
    ///
    /// Not re-worded here, for the reason `ItemActions.runReason` quotes the
    /// summary rather than paraphrasing it: a second wording of a refusal drifts
    /// from the one that actually decides, and then the screen and the run log
    /// say different things about the same item.
    let unmet: String?

    /// What a met clause is met *by*, where saying so tells the reader
    /// something ("sized M"). Nil when the tick says it all.
    let note: String?

    var isMet: Bool { unmet == nil }

    /// Unique across a verdict's rows: the dependency clause is the one that can
    /// appear more than once, and its rows differ by the id each names.
    var id: String { "\(requirement.rawValue)|\(unmet ?? note ?? "")" }
}

/// The Definition-of-Ready verdict, clause by clause, for someone grooming the
/// item rather than for the run log.
///
/// The gate was already evaluated for every item this view shows — it is what
/// decides whether Run is offered — and its verdict went nowhere but into a
/// tooltip. An item autopilot will skip at pickup looked exactly like one it
/// will run, and which clause failed was learned from the run log afterwards.
///
/// A mapping, not a second opinion: every phrase a reader sees is one
/// `DefinitionOfReady` produced. Nothing here re-checks the item, so this cannot
/// come to a different answer than the gate did.
enum ItemReadinessChecklist {

    /// Whether the checklist is worth showing for an item at this stage.
    ///
    /// Hidden once the item is done: the gate governs pickup, and an item that
    /// has shipped is past it — a checklist there would invite re-grooming work
    /// already delivered. Every other stage keeps it, including `blocked`, which
    /// is precisely where someone is deciding what the item needs before it goes
    /// back to `ready`.
    static func isShown(for status: BacklogItemStatus) -> Bool { status != .done }

    /// - Parameters:
    ///   - item: the backlog line the verdict was reached about.
    ///   - detail: the detail file the verdict was reached with, or nil.
    ///   - verdict: what `DefinitionOfReady.evaluate` answered for exactly those
    ///     two arguments. Passing a verdict from a different reading is how the
    ///     rows and the gate would come apart.
    ///   - judgedDependencies: whether that evaluation was given a backlog to
    ///     resolve `needs:` against. False leaves the dependency row out
    ///     entirely rather than ticking it — an unasked question has no answer,
    ///     and a green row would be a claim nobody made.
    static func rows(item: BacklogItem,
                     detail: BacklogItemDetail?,
                     verdict: DefinitionOfReady.Verdict,
                     judgedDependencies: Bool) -> [ItemReadinessRow] {
        var refusals: [DefinitionOfReady.Requirement: [String]] = [:]
        for (requirement, reason) in zip(verdict.unmet, verdict.reasons) {
            refusals[requirement, default: []].append(reason)
        }

        var rows: [ItemReadinessRow] = []
        func add(_ requirement: DefinitionOfReady.Requirement,
                 _ clause: String,
                 metNote: String? = nil) {
            let unmet = refusals[requirement]?.first
            rows.append(ItemReadinessRow(requirement: requirement, clause: clause,
                                         unmet: unmet, note: unmet == nil ? metNote : nil))
        }

        // The detail file, and — only when there was one for the gate to read —
        // its three sections. With no file the verdict reports `.detail` and
        // says nothing about What, How or Validation, deliberately: the one fix
        // is to write the file, and three more unmet rows beside it would say
        // that four times. An item groomed inline on its line has no file and is
        // ready all the same, so the row says which way it was groomed.
        add(.detail, "Groomed detail file",
            metNote: detail == nil ? "groomed inline on the backlog line" : nil)
        if detail != nil {
            add(.what, "What")
            add(.how, "How")
            add(.validation, "Validation")
        }

        add(.verify, "verify: command")
        add(.verifySeparator, "verify: fits the backlog line")
        add(.titleSeparator, "Title fits the backlog line")

        // One row for the size however it was answered: "no size set" and "size
        // L is too large" are two clauses in the verdict because they need
        // different words, but they are one question to whoever is grooming.
        if let tooLarge = refusals[.sizeTooLarge]?.first {
            rows.append(ItemReadinessRow(requirement: .sizeTooLarge, clause: "Size",
                                         unmet: tooLarge, note: nil))
        } else {
            add(.size, "Size",
                metNote: DefinitionOfReady.effectiveSize(item: item, detail: detail)
                    .map { "sized \($0.rawValue)" })
        }

        // Sequencing last, as the verdict lists it: one row per dependency that
        // is not done, each naming the id it waits for, because "wait for one of
        // these three" is not a thing an item can say.
        if judgedDependencies {
            let waiting = refusals[.dependency] ?? []
            if waiting.isEmpty {
                add(.dependency, "Dependencies",
                    metNote: item.needs.isEmpty
                        ? "nothing to wait for"
                        : "every item it waits for is done")
            } else {
                for reason in waiting {
                    rows.append(ItemReadinessRow(requirement: .dependency, clause: "Dependencies",
                                                 unmet: reason, note: nil))
                }
            }
        }

        return rows
    }
}

/// Something a person can do to an item from its detail view, and — when they
/// cannot — why.
///
/// Unavailable actions are offered and disabled rather than hidden. A hidden
/// action is indistinguishable from one that does not exist, which is the state
/// this view was built to end: the whole point is that the answer and the next
/// step live in the same place, and "you cannot approve this because it is not
/// at the gate" is part of the answer.
struct ItemAction: Identifiable, Equatable, Sendable {

    enum Kind: String, Equatable, Sendable, CaseIterable {
        case run
        case cancel
        case approve
        case reject
        case unblock
        case release
        case regroom
        /// Runs one agent pass over a draft, proposing a `verify:`, a size and a
        /// What/How/Validation/Out of Scope — previewed before anything is
        /// written, the way every other AI backlog edit is. Offered whether or
        /// not the draft already has a detail file: a grooming pass files one
        /// with every draft it parks, so refusing on that clause refused the
        /// action on every draft there was to groom.
        case groom
        /// Moves a draft to Ready. Offered only once the Definition-of-Ready
        /// passes, whether that came from `.groom` or a human's own edit — the
        /// gate, not how the item got there, decides.
        case promote

        var label: String {
            switch self {
            case .run: "Run"
            case .cancel: "Cancel run"
            case .approve: "Approve"
            case .reject: "Reject"
            case .unblock: "Unblock"
            case .release: "Release for Autopilot"
            case .regroom: "Re-groom"
            case .groom: "Groom"
            case .promote: "Promote to Ready"
            }
        }

        var icon: String {
            switch self {
            case .run: "play.fill"
            case .cancel: "stop.fill"
            case .approve: "checkmark.circle"
            case .reject: "arrow.uturn.backward"
            case .unblock: "lock.open"
            case .release: "arrow.clockwise.circle"
            case .regroom: "pencil"
            case .groom: "wand.and.stars"
            case .promote: "arrow.up.circle"
            }
        }
    }

    let kind: Kind
    /// Nil when the action can be taken; otherwise the reason it cannot, in
    /// words that name the condition rather than the code.
    let unavailable: String?

    var isAvailable: Bool { unavailable == nil }
    var id: String { kind.rawValue }
}

/// Which actions an item's current state permits.
///
/// Pure, and deliberately given the state rather than the objects that hold it:
/// the rules are the part worth testing, and they are the part that has to agree
/// with what the buttons actually do.
enum ItemActions {

    struct Context: Equatable, Sendable {
        let itemID: String
        let status: BacklogItemStatus
        /// Stages this project's flow lets autopilot start from.
        let pickupStages: [BacklogItemStatus]
        /// Whether the retry ceiling is currently refusing to start the item.
        let isRetired: Bool
        /// Whether both roles are assigned — autopilot cannot run without them.
        let hasWorkerAndReviewer: Bool
        /// What the Definition-of-Ready gate says about this item, judged with
        /// the same three arguments autopilot passes at pickup so the button and
        /// the gate cannot come to different answers.
        ///
        /// Nil leaves the clause silent rather than passing it, matching the rule
        /// `DefinitionOfReady.Dependencies` already states: somewhere with
        /// nothing to evaluate against has no basis to call an item unready.
        let readiness: DefinitionOfReady.Verdict?
        /// The item autopilot is executing right now, across the project. Nil
        /// when nothing is running.
        let inFlightItemID: String?
        /// Whether the item has a detail file to open.
        let hasDetailFile: Bool
        /// Whether there is a repository to merge from at the gate.
        let hasProjectRoot: Bool
        /// Whether this surface has an agent runtime to run a groom pass
        /// with. False on a surface that never shows a draft — the item's
        /// page still offers the action rather than hiding it, and says why
        /// it can't be taken here. Defaulted true: every existing caller of
        /// this initializer predates the groom action and has one.
        let hasGroomRunner: Bool

        init(itemID: String, status: BacklogItemStatus, pickupStages: [BacklogItemStatus],
             isRetired: Bool, hasWorkerAndReviewer: Bool, readiness: DefinitionOfReady.Verdict?,
             inFlightItemID: String?, hasDetailFile: Bool, hasProjectRoot: Bool,
             hasGroomRunner: Bool = true) {
            self.itemID = itemID
            self.status = status
            self.pickupStages = pickupStages
            self.isRetired = isRetired
            self.hasWorkerAndReviewer = hasWorkerAndReviewer
            self.readiness = readiness
            self.inFlightItemID = inFlightItemID
            self.hasDetailFile = hasDetailFile
            self.hasProjectRoot = hasProjectRoot
            self.hasGroomRunner = hasGroomRunner
        }
    }

    /// Every action, in the order the view shows them. Always the same seven —
    /// what changes is which of them carry a reason.
    static func offered(_ context: Context) -> [ItemAction] {
        ItemAction.Kind.allCases.map { ItemAction(kind: $0, unavailable: reason($0, context)) }
    }

    private static func reason(_ kind: ItemAction.Kind, _ context: Context) -> String? {
        switch kind {
        case .run, .cancel, .approve, .reject:
            return runLifecycleReason(kind, context)
        case .unblock:
            // The one stage nothing else lifts. Back to draft from here: a
            // person decides whether it is ready, and the page's Run says why
            // it is not.
            return context.status == .blocked
                ? nil
                : "the item is \(context.status.displayName), not blocked"
        case .release:
            return context.isRetired
                ? nil
                : "not retired — the retry ceiling has nothing to release"
        case .regroom:
            return context.hasDetailFile ? nil : "this item has no detail file to open"
        case .groom:
            return groomReason(context)
        case .promote:
            return promoteReason(context)
        }
    }

    /// The four actions that revolve around a run itself: starting one,
    /// stopping one, and the human gate at its far end.
    private static func runLifecycleReason(_ kind: ItemAction.Kind, _ context: Context) -> String? {
        switch kind {
        case .run:
            return runReason(context)
        case .cancel:
            // This item, not any item: cancelling stops the project's whole
            // queue, so offering it from an item nobody is running would let a
            // reader stop a run they were not looking at.
            guard context.inFlightItemID == context.itemID else {
                return context.inFlightItemID == nil
                    ? "nothing is running for this item"
                    : "the run in flight is on \(context.inFlightItemID!), not this item"
            }
            return nil
        case .approve, .reject:
            guard context.status == .awaitingApproval else {
                return "the item is \(context.status.displayName), not at the approval gate"
            }
            if kind == .approve, !context.hasProjectRoot {
                return "no project root — there is no repository to merge from"
            }
            return nil
        default:
            return nil
        }
    }

    private static func groomReason(_ context: Context) -> String? {
        guard context.hasGroomRunner else { return "no agent runtime available from this panel" }
        guard context.status == .draft else {
            return "the item is \(context.status.displayName), not Draft"
        }
        return nil
    }

    private static func promoteReason(_ context: Context) -> String? {
        guard context.status == .draft else {
            return "the item is \(context.status.displayName), not Draft"
        }
        if let readiness = context.readiness, !readiness.isReady { return readiness.summary }
        return nil
    }

    private static func runReason(_ context: Context) -> String? {
        // Named before the stage check, which would otherwise report the
        // item's `active` stage and say nothing about the run holding it.
        if let inFlight = context.inFlightItemID {
            return inFlight == context.itemID
                ? "a run for this item is in flight"
                : "a run is already in flight on \(inFlight) — one at a time per project"
        }
        guard context.pickupStages.contains(context.status) else {
            let stages = context.pickupStages.map(\.displayName).joined(separator: ", ")
            return stages.isEmpty
                ? "this project's flow gives autopilot no stage to pick items up from"
                : "autopilot starts items at \(stages) — this one is \(context.status.displayName)"
        }
        // The ODD gate, in the gate's own words. Autopilot would accept the
        // start and drop the item at pickup, leaving "Started a run" on screen
        // and the only explanation buried in the run log — so the refusal is
        // quoted verbatim here rather than paraphrased into a second wording
        // that could drift from what actually decides.
        if let readiness = context.readiness, !readiness.isReady {
            return readiness.summary
        }
        if context.isRetired {
            return "retired by the retry ceiling — release it before it runs again"
        }
        if !context.hasWorkerAndReviewer {
            return "assign a worker and a reviewer in the Autopilot panel first"
        }
        return nil
    }
}
