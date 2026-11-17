import Foundation

/// What one sitting of runs in a project came to: the items that landed, the
/// items that stalled — each with its recorded reason on one line and what
/// clears it — and what the sitting spent.
///
/// A sitting is a stretch of runs nobody was watching: the unbroken run of
/// starts the scheduler made in a project until it next held, or one autopilot
/// run over several items. Reading it back used to mean opening each item's
/// notes in turn.
///
/// Built from `PersistedRunRecord` rows and nothing else. It records nothing of
/// its own, so it can only say what the run records already hold — and a run
/// that left no record is not in it.
package struct SittingSummary: Codable, Equatable, Sendable {

    /// An item whose work is on the base branch, or was accepted as done.
    package struct Landed: Codable, Equatable, Sendable {
        package let itemID: String
        package let title: String
        /// The commit the run's own merge produced, when it made one.
        package let mergeCommit: String?
    }

    /// Why an item did not land.
    package enum Stall: String, Codable, Sendable, CaseIterable {
        /// A run reached the item and could not finish it.
        case blocked
        /// A pickup gate refused the item before any work began.
        case refusedAtPickup = "refused_at_pickup"
        /// The work, or a report refuting the item's premise, waits for a person.
        case atGate = "at_gate"

        /// What clears a stall of this kind. Fixed per kind: the record says
        /// how a run ended, not what a person should make of it.
        package var action: String {
            switch self {
            case .blocked: return "re-groom the item or run it again"
            case .refusedAtPickup: return "fix what the reason names, usually a Definition-of-Ready clause, so it can be picked up"
            case .atGate: return "approve or reject it at the gate"
            }
        }

        package var heading: String {
            switch self {
            case .blocked: return "Blocked"
            case .refusedAtPickup: return "Refused at pickup"
            case .atGate: return "Waiting at the gate"
            }
        }
    }

    /// One stalled item: what was recorded about it, cut to a line, and the
    /// action that clears it.
    package struct Stalled: Codable, Equatable, Sendable {
        package let itemID: String
        package let title: String
        package let reason: String
        package let action: String
    }

    package let projectID: String
    package let from: Date
    package let to: Date
    package let landed: [Landed]
    package let blocked: [Stalled]
    package let refusedAtPickup: [Stalled]
    package let atGate: [Stalled]
    /// The sum of every cost the sitting's records carry — every attempt at an
    /// item, not only its last, and runs that ended in none of the lists above.
    /// A record without a cost adds nothing.
    package let totalSpendUSD: Double

    package var stalledCount: Int { blocked.count + refusedAtPickup.count + atGate.count }

    /// Nothing landed and nothing stalled: there is no summary to give.
    package var isEmpty: Bool { landed.isEmpty && stalledCount == 0 }

    // MARK: - Building

    /// The summary of `projectID`'s runs between `from` and `to`.
    ///
    /// A record belongs to the sitting when it started no later than `to` and
    /// had not ended before `from`. Ending counts as well as starting because a
    /// control-API run's record is opened by the request, a moment before the
    /// autopilot run it becomes. An item run more than once appears once, under
    /// its latest record.
    package static func build(records: [PersistedRunRecord], projectID: String,
                              from: Date, to: Date) -> SittingSummary {
        let inWindow = records.filter {
            $0.projectID == projectID && $0.startedAt <= to && ($0.endedAt ?? $0.startedAt) >= from
        }
        var latest: [String: PersistedRunRecord] = [:]
        for record in inWindow {
            if let held = latest[record.itemID], held.startedAt > record.startedAt { continue }
            latest[record.itemID] = record
        }
        let ordered = latest.values.sorted { ($0.startedAt, $0.itemID) < ($1.startedAt, $1.itemID) }
        func stalled(_ kind: Stall) -> [Stalled] {
            ordered.filter { stall(of: $0) == kind }.map {
                Stalled(itemID: $0.itemID, title: $0.title, reason: reasonLine(of: $0), action: kind.action)
            }
        }
        return SittingSummary(
            projectID: projectID, from: from, to: to,
            landed: ordered.filter(hasLanded).map {
                Landed(itemID: $0.itemID, title: $0.title, mergeCommit: $0.mergeCommit)
            },
            blocked: stalled(.blocked),
            refusedAtPickup: stalled(.refusedAtPickup),
            atGate: stalled(.atGate),
            totalSpendUSD: inWindow.compactMap(\.costUSD).reduce(0, +))
    }

    private static func hasLanded(_ record: PersistedRunRecord) -> Bool {
        record.merged == true || record.outcome == .done
    }

    /// Which stall a record is, or nil for one that landed or that ended in a
    /// way that is neither — cancelled, parked on the usage limit, interrupted,
    /// or still open.
    private static func stall(of record: PersistedRunRecord) -> Stall? {
        guard !hasLanded(record), let outcome = record.outcome else { return nil }
        switch outcome {
        case .blocked: return .blocked
        case .didNotRun: return .refusedAtPickup
        case .awaitingApproval, .investigation: return .atGate
        case .done, .cancelled, .usageLimitParked, .interrupted: return nil
        }
    }

    /// The recorded reason's first line that says anything, or what the
    /// record's other fields say when no reason was written down.
    static func reasonLine(of record: PersistedRunRecord) -> String {
        let lines = (record.reason ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = lines.first(where: { !$0.isEmpty }) { return first }
        if record.outcome == .investigation { return "the worker refuted the item's premise; its report is at the gate" }
        if record.merged == false { return "the run's own merge was refused" }
        return noReasonRecorded
    }

    static let noReasonRecorded = "no reason recorded"

    // MARK: - Reading it

    /// The counts and the spend, in a sentence.
    package var headline: String {
        "\(landed.count) landed, \(stalledCount) stalled, \(Self.usd(totalSpendUSD)) spent"
    }

    /// The whole summary as text: the headline, then a list per kind that has
    /// anything in it.
    package var text: String {
        var sections = [headline + "."]
        if !landed.isEmpty {
            sections.append((["Landed:"] + landed.map { "- \($0.itemID): \($0.title)" }).joined(separator: "\n"))
        }
        for kind in Stall.allCases where !rows(kind).isEmpty {
            let lines = rows(kind).map { "- \($0.itemID): \($0.title). \($0.reason). To clear: \($0.action)." }
            sections.append((["\(kind.heading):"] + lines).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    package func rows(_ kind: Stall) -> [Stalled] {
        switch kind {
        case .blocked: return blocked
        case .refusedAtPickup: return refusedAtPickup
        case .atGate: return atGate
        }
    }

    static func usd(_ amount: Double) -> String {
        "$" + amount.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: - The inbox notice

    package static let noticeTitle = "Sitting summary"

    /// What the inbox is told as the sitting ends, or nil for a sitting with
    /// nothing in it. Actionable — it counts in the badge — only when
    /// something stalled; a sitting where everything landed is a report.
    package var notice: (type: NotificationItem.NotificationType, title: String, body: String)? {
        guard !isEmpty else { return nil }
        return (stalledCount > 0 ? .error : .complete, Self.noticeTitle, text)
    }

    // MARK: - The control API payload

    /// `GET /v1/autopilot/sitting-summary`'s body.
    package var payload: [String: Any] {
        func stalledJSON(_ rows: [Stalled]) -> [[String: Any]] {
            rows.map { ["itemId": $0.itemID, "title": $0.title, "reason": $0.reason, "action": $0.action] }
        }
        return [
            "project": projectID,
            "from": from.formatted(.iso8601),
            "to": to.formatted(.iso8601),
            "summary": headline,
            "landed": landed.map {
                ["itemId": $0.itemID, "title": $0.title, "mergeCommit": $0.mergeCommit as Any? ?? NSNull()]
            },
            "blocked": stalledJSON(blocked),
            "refusedAtPickup": stalledJSON(refusedAtPickup),
            "atGate": stalledJSON(atGate),
            "totalSpendUSD": totalSpendUSD,
            "text": text
        ]
    }
}

/// The sittings in progress, by project: when the first run of each began.
///
/// Held in memory by whatever starts the runs. It records nothing — a sitting
/// cut short by the app quitting is simply never summarised — and exists so
/// "the stretch since the first start" has one definition.
package struct OpenSittings: Sendable {

    /// One sitting that has ended, as the window to read back.
    package struct Ended: Equatable, Sendable {
        package let projectID: String
        package let from: Date
        package let to: Date
    }

    private var starts: [String: Date] = [:]

    package init() {}

    package var isEmpty: Bool { starts.isEmpty }

    /// A run began in `projectID`. The first one since the last `end` opens
    /// that project's sitting; later ones are part of it.
    package mutating func started(in projectID: String, at date: Date) {
        if starts[projectID] == nil { starts[projectID] = date }
    }

    /// Closes every open sitting at `date` and returns them, by project id.
    /// Asked again with nothing started since, it returns nothing.
    package mutating func end(at date: Date) -> [Ended] {
        defer { starts.removeAll() }
        return starts.sorted { $0.key < $1.key }.map { Ended(projectID: $0.key, from: $0.value, to: $0.value > date ? $0.value : date) }
    }
}
