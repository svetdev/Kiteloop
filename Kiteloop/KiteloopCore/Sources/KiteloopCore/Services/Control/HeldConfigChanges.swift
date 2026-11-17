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
    /// Which credential asked, as `ConfigChangeReader.key` spells it — what
    /// the same credential presents again to read what became of the change.
    /// A name is not enough: two scoped tokens may share one.
    package let asker: String
    /// The method and path, e.g. `PUT /v1/settings`.
    package let route: String
    /// `ConfigChangeSummary.text` of the request.
    package let summary: String
    /// The project the call names, when it names an open one; nil for a change
    /// to the app as a whole.
    package let project: Project?
    package let askedAt: Date
    /// Whether the caller hung up before an answer. The card stays, and
    /// approving it still applies the change: the caller reads what became
    /// of it afterwards (`HeldConfigChanges.outcome(_:for:)`).
    package var callerGone = false

    package init(id: String = UUID().uuidString, caller: String, asker: String? = nil, route: String,
                 summary: String, project: Project?, askedAt: Date) {
        self.id = id
        self.caller = caller
        self.asker = asker ?? caller
        self.route = route
        self.summary = summary
        self.project = project
        self.askedAt = askedAt
    }

    /// The line `ConfigChangeLog` keeps of what was decided.
    package func record(_ decision: ConfigChangeLog.Decision, at: Date) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(caller: caller, route: route, summary: summary, decision: decision, at: at,
                               project: project?.path)
    }
}

/// Who is asking what became of a held change: the person, who may read any,
/// or a credential, which may read only what it asked for itself.
package struct ConfigChangeReader: Equatable, Sendable {
    package let isThePerson: Bool
    /// What tells this credential from every other: `operator` for the
    /// operator token, a scoped token's id for a scoped one.
    package let key: String

    package init(isThePerson: Bool, key: String) {
        self.isThePerson = isThePerson
        self.key = key
    }

    package func mayRead(_ change: HeldConfigChange) -> Bool {
        isThePerson || key == change.asker
    }
}

/// What became of a held change, kept so that a caller whose request ended
/// before the answer can come back for it.
package struct ConfigChangeOutcome: Equatable, Sendable {

    /// What the call answered once it was approved and ran: exactly what the
    /// held request would have been sent.
    package struct Applied: Equatable, Sendable {
        package let status: Int
        package let headers: [String: String]
        package let body: Data

        package init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    package enum State: Equatable, Sendable {
        /// Nobody has answered the card yet.
        case waiting
        /// Approved and logged. `nil` for the moment the call is still
        /// running; then what it answered.
        case approved(Applied?)
        /// The person said no; nothing changed.
        case declined
        /// Approved, but the log line could not be written, so nothing
        /// changed — the reason.
        case unrecorded(String)
    }

    package let change: HeldConfigChange
    package var state: State

    package init(change: HeldConfigChange, state: State) {
        self.change = change
        self.state = state
    }
}

/// The configuration changes waiting on a person, the callers suspended until
/// each is answered, and what became of the ones already answered.
///
/// A caller files its change with `outcome(of:applying:)` and is resumed when
/// a person answers — nothing here reads a clock, so a change waits for as
/// long as the person takes (the pattern `AttemptDecisions` set). The decision
/// is written to the log before anything applies: an approval that cannot be
/// recorded resumes the caller with `.unrecorded`, and the change is not
/// applied.
///
/// A change does not depend on its request staying open. Approved, it is
/// applied here whether or not the caller is still connected, and what it
/// answered is kept — in memory, the newest `kept` of them, gone at a restart
/// — for the credential that asked to read back.
@MainActor
@Observable
package final class HeldConfigChanges {

    /// Carries an approved change out and says what it answered.
    package typealias Apply = @MainActor () async -> ConfigChangeOutcome.Applied

    /// What the suspended caller is told.
    package enum Outcome: Equatable, Sendable {
        /// Approved, logged and applied: what the call answered.
        case approved(ConfigChangeOutcome.Applied)
        case declined
        /// The caller hung up; its request is over. The card still waits.
        case callerGone
        /// Approved, but the log line could not be written — the reason.
        case unrecorded(String)
        /// The app is quitting with the card unanswered; nothing applies.
        case abandoned
    }

    /// What the person answering is told.
    package enum Answer: Equatable, Sendable {
        case approved
        case declined
        /// The approval could not be logged, so the change was refused.
        case unrecorded(String)
        /// No change with that id is waiting.
        case unknown
    }

    /// Every change waiting, oldest first.
    package private(set) var waiting: [HeldConfigChange] = []
    /// How many answered changes are kept for their callers to read.
    package let kept: Int
    @ObservationIgnored private var decided: [ConfigChangeOutcome] = []
    @ObservationIgnored private var callers: [String: CheckedContinuation<Outcome, Never>] = [:]
    @ObservationIgnored private var appliers: [String: Apply] = [:]

    /// `kept` defaults to what the app's event feed holds for a client that
    /// reconnects — the same kind of thing, bounded the same way.
    package init(keeping kept: Int = AppEventFeed.defaultCapacity) {
        self.kept = max(1, kept)
    }

    /// Files `change` and suspends until it is answered or its caller leaves.
    /// `apply` is what an approval runs — at once if the caller is still
    /// here, and just the same if it has gone. Called from the main actor the
    /// change is on the list before it suspends.
    package func outcome(of change: HeldConfigChange, applying apply: @escaping Apply) async -> Outcome {
        waiting.append(change)
        appliers[change.id] = apply
        return await withCheckedContinuation { callers[change.id] = $0 }
    }

    /// The caller of `id` hung up: its request ends, its card stays, and an
    /// approval still applies the change.
    package func callerLeft(_ id: String) {
        guard let index = waiting.firstIndex(where: { $0.id == id }),
              let caller = callers.removeValue(forKey: id) else { return }
        waiting[index].callerGone = true
        caller.resume(returning: .callerGone)
    }

    /// A person's answer to `id`. `record` appends the decision to the log;
    /// it runs before anything applies, and an approval it throws on is
    /// refused rather than applied unrecorded. An approved change is then
    /// applied — after this returns — and its caller, if still there, resumed
    /// with what it answered.
    package func answer(_ id: String, approve: Bool, at now: Date = Date(),
                        record: (HeldConfigChange, ConfigChangeLog.Record) throws -> Void) -> Answer {
        guard let index = waiting.firstIndex(where: { $0.id == id }),
              let apply = appliers.removeValue(forKey: id) else { return .unknown }
        let change = waiting.remove(at: index)
        let caller = callers.removeValue(forKey: id)
        guard approve else {
            try? record(change, change.record(.denied, at: now))
            keep(change, .declined)
            caller?.resume(returning: .declined)
            return .declined
        }
        do {
            try record(change, change.record(.approved, at: now))
        } catch {
            let reason = error.localizedDescription
            keep(change, .unrecorded(reason))
            caller?.resume(returning: .unrecorded(reason))
            return .unrecorded(reason)
        }
        keep(change, .approved(nil))
        Task { await self.carryOut(id, apply, resuming: caller) }
        return .approved
    }

    /// Runs an approved change, keeps what it answered and tells the caller.
    private func carryOut(_ id: String, _ apply: Apply,
                          resuming caller: CheckedContinuation<Outcome, Never>?) async {
        let applied = await apply()
        if let index = decided.firstIndex(where: { $0.change.id == id }) {
            decided[index].state = .approved(applied)
        }
        caller?.resume(returning: .approved(applied))
    }

    /// The app is quitting: every card still waiting is logged as abandoned
    /// and its caller, if any, let go with nothing applied.
    package func abandonWaiting(at now: Date = Date(),
                                record: (HeldConfigChange, ConfigChangeLog.Record) throws -> Void) {
        for change in waiting {
            try? record(change, change.record(.abandoned, at: now))
            callers.removeValue(forKey: change.id)?.resume(returning: .abandoned)
        }
        waiting = []
        appliers = [:]
    }

    private func keep(_ change: HeldConfigChange, _ state: ConfigChangeOutcome.State) {
        decided.append(ConfigChangeOutcome(change: change, state: state))
        if decided.count > kept { decided.removeFirst(decided.count - kept) }
    }

    // MARK: - Reading what became of a change

    /// What became of `id`, for a reader who may know: nil for a change that
    /// is not held and not kept, and — so an id tells a stranger nothing —
    /// for one another credential asked for.
    package func outcome(_ id: String, for reader: ConfigChangeReader) -> ConfigChangeOutcome? {
        outcomes(for: reader).first { $0.change.id == id }
    }

    /// Every change `reader` may read: the answered ones still kept, then
    /// the ones waiting, each oldest first.
    package func outcomes(for reader: ConfigChangeReader) -> [ConfigChangeOutcome] {
        (decided + waiting.map { ConfigChangeOutcome(change: $0, state: .waiting) })
            .filter { reader.mayRead($0.change) }
    }
}
