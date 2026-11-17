import Foundation

/// A prompt sent to one agent on a schedule: the morning brief, a poll of the
/// code host, a Friday review.
///
/// A routine starts a chat turn exactly as a person typing the prompt would —
/// same agent, same session, same permission mode — so everything that turn
/// may do is what the agent may already do. What the routine adds is only the
/// *when*, and a check that can decide there is nothing to say.
///
/// Routines live in `~/.kiteloop/routines.json`, outside every project, since
/// a prompt names the people and systems it is about and a project's folder
/// is often a shared repository.
package struct Routine: Codable, Equatable, Sendable, Identifiable {
    /// The name the API and the ledger know it by: lowercase letters, digits
    /// and hyphens.
    package var id: String
    /// What a person calls it.
    package var name: String
    /// The project the agent is in, as the control API names projects.
    package var project: String
    /// The agent the prompt goes to, by name or id.
    package var agent: String
    package var prompt: String
    package var trigger: Trigger
    /// A shell command run in the project's folder before the turn. It decides
    /// whether there is anything to do: a command that fails or prints nothing
    /// skips the turn, at no model cost, and what it prints goes to the agent
    /// under the prompt. Nil sends the prompt every time.
    package var precheck: String?
    /// Off until a person arms it.
    package var armed: Bool
    /// When it was last armed or its trigger last changed: occurrences before
    /// this are not owed.
    package var armedAt: Date?
    /// Which chat the prompt goes into. Nil — every routine saved before
    /// there was a choice — continues the agent's open chat.
    package var conversation: Conversation?
    /// What its scheduled and webhook firings may spend in a day or a month.
    /// Nil — every routine saved before it could have one — is no ceiling of
    /// its own: only the day's budgets bound it.
    package var budget: SpendBudget?

    package init(id: String, name: String, project: String, agent: String, prompt: String,
                 trigger: Trigger, precheck: String? = nil, armed: Bool = false, armedAt: Date? = nil,
                 conversation: Conversation? = nil, budget: SpendBudget? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.agent = agent
        self.prompt = prompt
        self.trigger = trigger
        self.precheck = precheck
        self.armed = armed
        self.armedAt = armedAt
        self.conversation = conversation
        self.budget = budget
    }

    /// Which chat a routine's prompt goes into.
    package enum Conversation: String, Codable, Sendable {
        /// The agent's open chat, as a person typing would.
        case continues
        /// A new chat for each run, opened with a note of the last run's
        /// outcome, so a daily job's context does not grow every day.
        case fresh
    }

    /// Whether each run starts the agent a new chat.
    package var startsFresh: Bool { conversation == .fresh }

    /// When a routine fires, as it is written down: either `at` a time of day,
    /// or `every` so many minutes between `from` and `until`, or `on` an event
    /// of a kind the app's event feed publishes. `days` narrows a schedule to
    /// some weekdays.
    package struct Trigger: Codable, Equatable, Sendable {
        /// A time of day, `HH:mm`, in the Mac's own time zone.
        package var at: String?
        /// Minutes between occurrences.
        package var every: Int?
        /// The first occurrence of a day, `HH:mm`; midnight when absent.
        package var from: String?
        /// The last moment of a day an occurrence may fall on, `HH:mm`; the
        /// day's end when absent.
        package var until: String?
        /// `mon` … `sun`; every day when absent.
        package var days: [String]?
        /// An event kind — a `NotificationItem.NotificationType` raw value —
        /// that fires the routine when its project publishes one. Nil for a
        /// routine on a schedule.
        package var on: String?

        package init(at: String? = nil, every: Int? = nil, from: String? = nil,
                     until: String? = nil, days: [String]? = nil, on: String? = nil) {
            self.at = at
            self.every = every
            self.from = from
            self.until = until
            self.days = days
            self.on = on
        }
    }

    /// Why a routine was not taken: every problem at once, so one round fixes it.
    package struct Refusal: Error, Equatable {
        package let problems: [String]
        package init(problems: [String]) { self.problems = problems }
        package var reason: String { problems.joined(separator: "; ") }
    }

    package static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// The routine as the API returns it.
    package var json: [String: Any] {
        var out: [String: Any] = ["id": id, "name": name, "project": project, "agent": agent,
                                  "prompt": prompt, "trigger": trigger.json, "armed": armed]
        if let precheck { out["precheck"] = precheck }
        out["conversation"] = (conversation ?? .continues).rawValue
        if let budget { out["budget"] = budget.json }
        return out
    }
}

extension Routine.Trigger {
    package var json: [String: Any] {
        var out: [String: Any] = [:]
        if let at { out["at"] = at }
        if let every { out["every"] = every }
        if let from { out["from"] = from }
        if let until { out["until"] = until }
        if let days { out["days"] = days }
        if let on { out["on"] = on }
        return out
    }
}

/// One firing of a routine, as the ledger keeps it.
package struct RoutineRun: Codable, Equatable, Sendable, Identifiable {
    package var id: String
    package var routine: String
    /// The occurrence this answers; nil for a run a person started by hand.
    package var scheduledFor: Date?
    /// When it was handled — later than `scheduledFor` by however long the Mac
    /// was asleep or the app was closed.
    package var at: Date
    package var outcome: Outcome
    /// Why it was skipped or refused; nil for a turn that started.
    package var reason: String?
    package var finishedAt: Date?
    /// The first line of what the agent said.
    package var reply: String?
    package var costUSD: Double?
    /// The webhook that fired it; nil for a scheduled run or one started by hand.
    package var hook: String?
    /// The kind of event that fired it; nil for a run nothing published started.
    package var event: String?

    package enum Outcome: String, Codable, Sendable {
        /// The turn began; `finishedAt` says when it ended.
        case started
        /// The agent was mid-turn, so the prompt waits behind that turn.
        case queued
        /// The check found nothing to do.
        case skipped
        /// The day's budget, the routine's own, or a person's own Run now with nobody to send
        /// it to; `reason` says which. Final: the occurrence is not retried.
        case refused
        /// The agent could not be reached — its project is not open, the
        /// fleet is held. The occurrence stays owed and runs when it can.
        case waiting
    }

    package init(id: String = UUID().uuidString, routine: String, scheduledFor: Date?, at: Date,
                 outcome: Outcome, reason: String? = nil, finishedAt: Date? = nil,
                 reply: String? = nil, costUSD: Double? = nil, hook: String? = nil,
                event: String? = nil) {
        self.id = id
        self.routine = routine
        self.scheduledFor = scheduledFor
        self.at = at
        self.outcome = outcome
        self.reason = reason
        self.finishedAt = finishedAt
        self.reply = reply
        self.costUSD = costUSD
        self.hook = hook
        self.event = event
    }

    /// The run as the API returns it.
    package var json: [String: Any] {
        let stamp = ISO8601DateFormatter()
        var out: [String: Any] = ["id": id, "routine": routine, "at": stamp.string(from: at),
                                  "outcome": outcome.rawValue]
        if let scheduledFor { out["scheduledFor"] = stamp.string(from: scheduledFor) }
        if let reason { out["reason"] = reason }
        if let finishedAt { out["finishedAt"] = stamp.string(from: finishedAt) }
        if let reply { out["reply"] = reply }
        if let costUSD { out["costUSD"] = costUSD }
        if let hook { out["hook"] = hook }
        if let event { out["event"] = event }
        return out
    }
}
