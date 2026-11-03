import Foundation

/// The account's usage limit standing, as the CLI reports it: a
/// `rate_limit_event` whose status is `rejected`. Kiteloop runs on a
/// subscription, so this — not a broken worker — is what ends most overnight
/// runs, and a run it ended is parked rather than failed.
///
/// Read from the structured event, not the error text: the event names the
/// window and when it resets.
package struct UsageLimitStop: Equatable, Sendable {
    /// When the limit lifts.
    package let resetsAt: Date
    /// The window that ran out — `five_hour`, `seven_day` — when reported.
    package let window: String?
    /// Whether `resetsAt` is the CLI's own, or the session window counted from
    /// the moment the refusal arrived because the event named no time.
    package let resetReported: Bool

    /// The status a reading carries once the limit refuses calls.
    package static let refusedStatus = "rejected"
    /// The subscription's session window: how long a refusal with no reset
    /// time of its own is taken to stand.
    package static let sessionWindow: TimeInterval = 5 * 60 * 60

    package init(resetsAt: Date, window: String?, resetReported: Bool) {
        self.resetsAt = resetsAt
        self.window = window
        self.resetReported = resetReported
    }

    /// The stop a reading reports, or nil for a reading that still lets calls
    /// through (`allowed`, `allowed_warning`).
    package static func stop(from reading: AgentActivityEvent.RateLimitInfo, now: Date) -> UsageLimitStop? {
        guard reading.status == refusedStatus else { return nil }
        if let reset = reading.resetsAt, reset > now {
            return UsageLimitStop(resetsAt: reset, window: reading.window, resetReported: true)
        }
        return UsageLimitStop(resetsAt: now.addingTimeInterval(sessionWindow), window: reading.window,
                              resetReported: false)
    }

    /// Whether the limit still refuses calls at `now`.
    package func stands(at now: Date) -> Bool { resetsAt > now }

    /// "09:00" when the reset is today, "Tue 09:00" when it is not — what the
    /// board and the item's Notes show beside "resumes".
    package func resumeText(now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(resetsAt, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: resetsAt)
    }
}
