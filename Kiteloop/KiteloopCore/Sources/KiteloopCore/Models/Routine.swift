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

    package init(id: String, name: String, project: String, agent: String, prompt: String,
                 trigger: Trigger, precheck: String? = nil, armed: Bool = false, armedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.agent = agent
        self.prompt = prompt
        self.trigger = trigger
        self.precheck = precheck
        self.armed = armed
        self.armedAt = armedAt
    }

    /// When a routine fires, as it is written down: either `at` a time of day,
    /// or `every` so many minutes between `from` and `until`. `days` narrows
    /// either to some weekdays.
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

        package init(at: String? = nil, every: Int? = nil, from: String? = nil,
                     until: String? = nil, days: [String]? = nil) {
            self.at = at
            self.every = every
            self.from = from
            self.until = until
            self.days = days
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

    package enum Outcome: String, Codable, Sendable {
        /// The turn began; `finishedAt` says when it ended.
        case started
        /// The agent was mid-turn, so the prompt waits behind that turn.
        case queued
        /// The check found nothing to do.
        case skipped
        /// The day's budget, or a person's own Run now with nobody to send
        /// it to; `reason` says which. Final: the occurrence is not retried.
        case refused
        /// The agent could not be reached — its project is not open, the
        /// fleet is held. The occurrence stays owed and runs when it can.
        case waiting
    }

    package init(id: String = UUID().uuidString, routine: String, scheduledFor: Date?, at: Date,
                 outcome: Outcome, reason: String? = nil, finishedAt: Date? = nil,
                 reply: String? = nil, costUSD: Double? = nil) {
        self.id = id
        self.routine = routine
        self.scheduledFor = scheduledFor
        self.at = at
        self.outcome = outcome
        self.reason = reason
        self.finishedAt = finishedAt
        self.reply = reply
        self.costUSD = costUSD
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
        return out
    }
}
