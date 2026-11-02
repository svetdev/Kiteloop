import Foundation

/// An elapsed time as a short phrase, on one scale everywhere the app shows
/// one: "42s" under a minute, "12m 5s" under an hour, "2h 5m" from an hour up
/// and "1d 3h" from a day up. A negative interval reads "0s".
package enum DurationPhrase {
    package static func phrase(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let (days, hours, minutes, secs) = (whole / 86_400, whole / 3600 % 24, whole / 60 % 60, whole % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// How long ago something happened, on the same scale but to its largest
    /// unit only: "40s ago", "3m ago", "2h ago", "1d ago".
    package static func age(_ seconds: TimeInterval) -> String {
        let largest = phrase(seconds).split(separator: " ").first.map(String.init) ?? "0s"
        return "\(largest) ago"
    }
}
