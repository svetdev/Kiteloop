import AppKit
import KiteloopCore
import UserNotifications

/// Plays Kiteloop's sounds and names them for banners, by the theme chosen in
/// Settings → General → Sounds.
@MainActor
enum SoundCues {
    /// The theme in force, read where it is used so a change in Settings
    /// applies to the next sound.
    static var theme: SoundTheme {
        SoundTheme(stored: UserDefaults.standard.string(forKey: SoundTheme.defaultsKey))
    }

    /// The sound a banner for `cue` carries; nil for a silent one.
    static func notificationSound(for cue: SoundCue, theme: SoundTheme = SoundCues.theme) -> UNNotificationSound? {
        switch theme.bannerSound(for: cue) {
        case .none: nil
        case .systemDefault: .default
        case .systemCritical: .defaultCritical
        case .file(let name): UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }

    /// The cue's bundled sound, loaded; nil when the bundle does not carry it.
    static func bundledSound(for cue: SoundCue) -> NSSound? {
        let name = (cue.fileName as NSString).deletingPathExtension
        let kind = (cue.fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: kind) else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }

    /// Plays a cue in the app itself — a turn ending while the person is
    /// looking at Kiteloop, where no banner is posted.
    static func play(_ cue: SoundCue, theme: SoundTheme = SoundCues.theme) {
        switch theme {
        case .soft: bundledSound(for: cue)?.play()
        case .system: NSSound(named: "Pop")?.play()
        case .silent: break
        }
    }
}
