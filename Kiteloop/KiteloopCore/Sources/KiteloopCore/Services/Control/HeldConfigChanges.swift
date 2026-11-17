import Foundation
import Observation

/// A configuration change an agent asked for over the control API, waiting on
/// a person: who asked, which call, and what it would change, secrets left out.
package struct HeldConfigChange: Identifiable, Equatable, Sendable {

    /// The open project a change is about.
    package struct Project: Equatable, Sendable {
        package let id: String
        package let name: String
        package let path: String

        package init(id: String, name: String, path: String) {
            self.id = id
            self.name = name
            self.path = path
        }
    }

    package let id: String
    /// The credential's name, as the access log writes it: `operator`, or a
    /// scoped token's name and scope.
    package let caller: String
    /// The method and path, e.g. `PUT /v1/settings`.
    package let route: String
    /// `ConfigChangeSummary.text` of the request.
    package let summary: String
    /// The project the call names, when it names an open one; nil for a change
    /// to the app as a whole.
    package let project: Project?
    package let askedAt: Date
    /// Whether the caller hung up before an answer. The card stays so a person
    /// sees what was asked; answering it applies nothing.
    package var callerGone = false

    package init(id: String = UUID().uuidString, caller: String, route: String, summary: String,
                 project: Project?, askedAt: Date) {
        self.id = id
        self.caller = caller
        self.route = route
        self.summary = summary
        self.project = project
        self.askedAt = askedAt
    }

    /// The line `ConfigChangeLog` keeps of what was decided.
    package func record(_ decision: ConfigChangeLog.Decision, at: Date) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(caller: caller, route: route, summary: summary, decision: decision, at: at)
    }
}

/// The configuration changes waiting on a person, and the callers suspended
/// until each is answered.
///
/// A caller files its change with `outcome(of:)` and is resumed when a person
/// answers — nothing here reads a clock, so a change waits for as long as the
/// person takes (the pattern `AttemptDecisions` set). The decision is written
/// to the log before the caller is resumed: an approval that cannot be
/// recorded resumes it with `.unrecorded`, and the change is not applied.
@MainActor
@Observable
package final class HeldConfigChanges {

    /// What the suspended caller is told.
    package enum Outcome: Equatable, Sendable {
        case approved
        case declined
        /// The caller hung up; its request is over and nothing applies.
        case callerGone
        /// Approved, but the log line could not be written — the reason.
        case unrecorded(String)
    }

    /// What the person answering is told.
    package enum Answer: Equatable, Sendable {
        case approved
        case declined
        /// The caller had gone: the card is cleared and nothing applied.
        case abandoned
        /// The approval could not be logged, so the change was refused.
        case unrecorded(String)
        /// No change with that id is waiting.
        case unknown
    }

    /// Every change waiting, oldest first.
    package private(set) var waiting: [HeldConfigChange] = []
    @ObservationIgnored private var callers: [String: CheckedContinuation<Outcome, Never>] = [:]

    package init() {}

    /// Files `change` and suspends until it is answered or its caller leaves.
    /// Called from the main actor it is on the list before it suspends.
    package func outcome(of change: HeldConfigChange) async -> Outcome {
        waiting.append(change)
        return await withCheckedContinuation { callers[change.id] = $0 }
    }

    /// The caller of `id` hung up: its request ends, its card stays.
    package func callerLeft(_ id: String) {
        guard let index = waiting.firstIndex(where: { $0.id == id }),
              let caller = callers.removeValue(forKey: id) else { return }
        waiting[index].callerGone = true
        caller.resume(returning: .callerGone)
    }

    /// A person's answer to `id`. `record` appends the decision to the log;
    /// it runs before the caller is resumed, and an approval it throws on is
    /// refused rather than applied unrecorded.
    package func answer(_ id: String, approve: Bool, at now: Date = Date(),
                        record: (HeldConfigChange, ConfigChangeLog.Record) throws -> Void) -> Answer {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return .unknown }
        let change = waiting.remove(at: index)
        guard let caller = callers.removeValue(forKey: id) else {
            try? record(change, change.record(.abandoned, at: now))
            return .abandoned
        }
        guard approve else {
            try? record(change, change.record(.denied, at: now))
            caller.resume(returning: .declined)
            return .declined
        }
        do {
            try record(change, change.record(.approved, at: now))
        } catch {
            let reason = error.localizedDescription
            caller.resume(returning: .unrecorded(reason))
            return .unrecorded(reason)
        }
        caller.resume(returning: .approved)
        return .approved
    }
}
