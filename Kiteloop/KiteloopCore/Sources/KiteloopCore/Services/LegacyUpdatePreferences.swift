import Foundation

/// What the update check kept in user defaults before Sparkle took the job
/// over: its own on/off switch, the day's allowance and the skipped release.
/// Sparkle keeps all three under keys of its own, so these are retired once —
/// and the one that was a choice, whether to check automatically, is handed
/// back so the caller can carry it across rather than silently turning
/// checking back on for someone who turned it off.
package enum LegacyUpdatePreferences {
    /// App Preferences' "Automatically check for updates", as it was stored.
    package static let automaticCheckKey = "updateCheckAutomatically"

    package static let retiredKeys = [automaticCheckKey, "updateCheckLastAnswered", "updateCheckSkippedVersion"]

    /// Removes every retired key and returns the automatic-check choice the
    /// user had made — nil when they never touched the toggle, which is also
    /// what every call after the first returns.
    package static func retire(from defaults: UserDefaults) -> Bool? {
        let choice = defaults.object(forKey: automaticCheckKey) as? Bool
        for key in retiredKeys {
            defaults.removeObject(forKey: key)
        }
        return choice
    }
}
