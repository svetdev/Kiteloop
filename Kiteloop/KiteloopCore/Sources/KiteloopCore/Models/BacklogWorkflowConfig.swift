import Foundation

/// Per-project configuration of the backlog stage flow. Stored at
/// `.kiteloop/backlog-workflow.json`; edited in Project Settings → Backlog Flow.
///
/// The stage order is fixed (draft → ready → active → inReview →
/// awaitingApproval → done) because it encodes a dependency chain, but which
/// stages are *enabled* is up to the team: a solo user who trusts the reviewer
/// agent can turn off the approval gate and have items land in Done, while a
/// team can require a stakeholder sign-off before anything is called finished.
package struct BacklogWorkflowConfig: Codable, Sendable, Equatable {
    /// Optional stages, in flow order. `active` and `done` are always present.
    package static let optionalStages: [BacklogItemStatus] = [.draft, .inReview, .awaitingApproval]

    /// New items land here. When `draft` is enabled this is `.draft`, so
    /// ungroomed items can't be picked up by an agent by accident.
    package var newItemStage: BacklogItemStatus

    /// Stages an autopilot run is allowed to pull items from.
    package var autopilotPickupStages: [BacklogItemStatus]

    /// Whether the worker→reviewer handoff shows as its own stage.
    package var useReviewStage: Bool

    /// Whether a human must approve before an item reaches Done. When false,
    /// a passing agent review sends the item straight to Done.
    package var requireHumanApproval: Bool

    /// Whether new items start as drafts that must be groomed first.
    package var useDraftStage: Bool

    package static let `default` = BacklogWorkflowConfig(
        newItemStage: .draft,
        autopilotPickupStages: [.ready],
        useReviewStage: true,
        requireHumanApproval: true,
        useDraftStage: true
    )

    /// The stages actually shown and used, in flow order.
    package var activeStages: [BacklogItemStatus] {
        var stages: [BacklogItemStatus] = []
        if useDraftStage { stages.append(.draft) }
        stages.append(.ready)
        stages.append(.active)
        if useReviewStage { stages.append(.inReview) }
        if requireHumanApproval { stages.append(.awaitingApproval) }
        stages.append(.done)
        return stages
    }

    /// Where an item goes when an agent finishes work and its review passes.
    package var stageAfterAgentReview: BacklogItemStatus {
        requireHumanApproval ? .awaitingApproval : .done
    }

    /// Where a newly created item starts, honoring the draft toggle.
    package var effectiveNewItemStage: BacklogItemStatus {
        useDraftStage ? .draft : .ready
    }

    /// Whether autopilot may pull items from a stage at all — the one
    /// definition, read by `sanitized()` and by the Backlog Flow settings tab.
    /// A human-only stage (`draft`, `done`) is not an agent's to start, and
    /// `awaitingApproval` is the gate the ODD leans on: an item parked there is
    /// waiting for a person, not for another run. Being pickable is separate
    /// from being *active* — a stage the toggles removed is filtered out too.
    package static func isPickable(_ stage: BacklogItemStatus) -> Bool {
        stage != .awaitingApproval && !stage.isHumanOnly
    }

    /// The stages autopilot could pull from given these toggles, in flow order.
    package var pickableStages: [BacklogItemStatus] {
        activeStages.filter(Self.isPickable)
    }

    /// Normalizes a config loaded from disk so toggles and stage lists agree.
    package func sanitized() -> BacklogWorkflowConfig {
        var config = self
        // Both halves matter: `activeStages` drops a stage the toggles removed,
        // `isPickable` drops one no agent may pull from however the toggles
        // stand. A config hand-edited outside the app used to name `done` or
        // `awaiting-approval` here and have autopilot re-run finished items and
        // work parked at the human gate.
        let pickable = config.pickableStages
        let pickup = config.autopilotPickupStages.filter { pickable.contains($0) }
        config.autopilotPickupStages = pickup.isEmpty ? [.ready] : pickup
        if !config.activeStages.contains(config.newItemStage) {
            config.newItemStage = config.effectiveNewItemStage
        }
        return config
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(newItemStage: BacklogItemStatus, autopilotPickupStages: [BacklogItemStatus], useReviewStage: Bool, requireHumanApproval: Bool, useDraftStage: Bool) {
        self.newItemStage = newItemStage
        self.autopilotPickupStages = autopilotPickupStages
        self.useReviewStage = useReviewStage
        self.requireHumanApproval = requireHumanApproval
        self.useDraftStage = useDraftStage
    }
}

/// Loads and saves the per-project backlog flow config.
package struct BacklogWorkflowConfigStore {
    package let url: URL
    package var reporter: StoreProblemReporter = .shared

    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the reporter's dedup key, so it is spelled once —
    /// the words Project Settings shows above this store's controls.
    package static let storeName = "Backlog Flow"

    package func load() -> BacklogWorkflowConfig {
        // A config the decoder refuses is kept, not dropped: `try?` here read a
        // truncated file as "no config at all", and the next save from Project
        // Settings → Backlog Flow wrote the defaults over it for good.
        guard let config = QuarantiningJSONFile.load(BacklogWorkflowConfig.self,
                                                      from: url,
                                                      store: Self.storeName,
                                                      reporter: reporter) else {
            return .default
        }
        return config.sanitized()
    }

    package func save(_ config: BacklogWorkflowConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config.sanitized())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(url: URL, reporter: StoreProblemReporter = .shared) {
        self.url = url
        self.reporter = reporter
    }
}
