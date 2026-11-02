import Foundation
import KiteloopCore

/// The trust ladder, as a value: which rung of autonomy this portfolio stands
/// on, and what the next rung needs — in the words the gates already use.
///
/// Autonomy here is five rungs — manual tool; startable projects; grooming;
/// consented unattended running; unattended shipping
/// — and every rung's rule already exists as a switch, a gate or a hold. This
/// type renders no opinion of its own: each unmet rung carries the sentence its
/// own gate produces (`AutonomyArming`, `RunScheduling.Hold`), so the ladder
/// can never disagree with the control it points at. Pure, so every rung is
/// exercised without a registry.
enum AutonomyLadder {

    /// One project's autonomy-relevant switches, as plain values.
    struct Project: Sendable, Equatable {
        let name: String
        let autopilotReady: Bool
        let autonomousWorkEnabled: Bool
        let approveReviewPassedRuns: Bool
        let autoMergeOnApproval: Bool
    }

    struct Inputs: Sendable, Equatable {
        var projects: [Project] = []
        var refillEnabled = false
        var schedulerEnabled = false
        /// The one daily ceiling — grooming and running together.
        var dailyBudgetUSD: Double?
    }

    struct Rung: Sendable, Equatable, Identifiable {
        let id: Int
        let title: String
        let met: Bool
        /// What meets it, or what it needs — one sentence.
        let detail: String
        /// The control that advances it; only carried by the first unmet rung,
        /// which is the one a reader acts on.
        let advance: String?
    }

    static func assess(_ x: Inputs) -> [Rung] {
        let ready = x.projects.filter(\.autopilotReady)
        let consented = ready.filter(\.autonomousWorkEnabled)
        let shipping = consented.filter { $0.approveReviewPassedRuns && $0.autoMergeOnApproval }

        // Each rung: met, the fact or the need, and the advancing control.
        var rungs: [(String, Bool, String, String)] = []

        rungs.append(("Use Kiteloop by hand", true,
                      "Run starts an item; nothing runs by itself.", ""))

        rungs.append(("Projects that can run", !ready.isEmpty,
                      ready.isEmpty
                        ? "No project has both a worker and a reviewer."
                        : "\(names(ready)) can be started.",
                      "a project's Autopilot tab — assign a worker and a reviewer"))

        let groomingNeed = AutonomyArming.armGrooming(dailyBudgetUSD: x.dailyBudgetUSD)?.message
            ?? "Grooming is off — drafts wait for someone to write them."
        rungs.append(("Grooming", x.refillEnabled,
                      x.refillEnabled
                        ? "Drafts that clear both gates are filed, within the shared daily ceiling."
                        : groomingNeed,
                      "Planner panel — Groom the backlog"))

        let runningMet = x.schedulerEnabled && !consented.isEmpty
        let runningDetail: String
        if runningMet {
            runningDetail = "\(names(consented)) consented"
                + (x.dailyBudgetUSD.map { String(format: " — within $%.2f a day.", $0) } ?? ".")
                + " " + Self.permissionFact
        } else if let refusal = AutonomyArming.armScheduling(dailyBudgetUSD: x.dailyBudgetUSD) {
            runningDetail = refusal.message
        } else if !x.schedulerEnabled {
            runningDetail = "The switch is off — nothing starts unattended."
        } else {
            runningDetail = RunScheduling.Hold.noProjectOptedIn.reason
        }
        rungs.append(("Running work unattended", runningMet, runningDetail,
                      "Fleet drawer — Run work unattended, and each project's Include in autonomous work"))

        rungs.append(("Shipping unattended", !shipping.isEmpty,
                      shipping.isEmpty
                        ? "Every merge still waits for a person at the approval gate."
                        : "\(names(shipping)) approve and merge review-passed runs themselves.",
                      "a consented project's Autopilot tab — Approve review-passed runs, and auto-merge"))

        let firstUnmet = rungs.firstIndex { !$0.1 }
        return rungs.enumerated().map { index, rung in
            Rung(id: index + 1, title: rung.0, met: rung.1, detail: rung.2,
                 advance: index == firstUnmet && !rung.3.isEmpty ? rung.3 : nil)
        }
    }

    /// How an unattended run is permitted, stated on the rung that starts them
    /// rather than left as a default nobody reads: runs use Claude Code's auto
    /// mode, whose classifier decides each tool call, and what bounds a run
    /// beyond that is the worktree, the gate and a person.
    static var permissionFact: String {
        "Runs use Claude Code's auto mode, whose classifier decides each tool call; "
            + "the worktree, the gate and a person are the boundaries."
    }

    private static func names(_ projects: [Project]) -> String {
        let sorted = projects.map(\.name).sorted()
        let shown = sorted.prefix(4).joined(separator: ", ")
        let more = sorted.count - min(4, sorted.count)
        return more > 0 ? "\(shown) +\(more) more" : shown
    }
}

@MainActor
extension AutonomyLadder.Inputs {
    /// The live state, read from the same objects the Coordinator panel holds.
    /// Reading captures values; nothing here can act.
    static func capture(registry: ControlSessionRegistry?,
                        refill: CoordinatorQueueRefill,
                        scheduler: CoordinatorRunScheduler?,
                        store: GlobalConfigStore?) -> Self {
        var inputs = AutonomyLadder.Inputs()
        inputs.projects = (registry?.openProjects ?? []).map { entry in
            AutonomyLadder.Project(
                name: entry.session.project.rootURL.lastPathComponent,
                autopilotReady: entry.autopilot.workerAgentID != nil
                    && entry.autopilot.reviewerAgentID != nil,
                autonomousWorkEnabled: entry.autopilot.autonomousWorkEnabled,
                approveReviewPassedRuns: entry.autopilot.approveReviewPassedRuns,
                autoMergeOnApproval: entry.autopilot.autoMergeOnApproval)
        }
        inputs.refillEnabled = refill.enabled
        inputs.schedulerEnabled = scheduler?.enabled ?? false
        inputs.dailyBudgetUSD = store?.config.dailyBudgetUSD
        return inputs
    }
}
