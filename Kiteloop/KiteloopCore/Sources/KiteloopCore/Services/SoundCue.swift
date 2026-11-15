import Foundation

/// The moments Kiteloop makes a sound for.
package enum SoundCue: String, CaseIterable, Sendable {
    /// An agent's turn ended.
    case finished
    /// An approval or a question is waiting on a person.
    case needsYou
    /// An agent stopped and could not be restarted.
    case failed

    /// The bundled sound for the cue — written by `scripts/make-sounds.py`.
    package var fileName: String {
        switch self {
        case .finished: "kiteloop-finished.wav"
        case .needsYou: "kiteloop-needs-you.wav"
        case .failed: "kiteloop-failed.wav"
        }
    }

    /// What Settings calls it beside its preview button.
    package var label: String {
        switch self {
        case .finished: "Agent finished"
        case .needsYou: "Needs you"
        case .failed: "Agent stopped"
        }
    }
}

/// Which sounds Kiteloop makes: its own quiet ones, the system's, or none.
package enum SoundTheme: String, CaseIterable, Sendable {
    case soft
    case system
    case silent

    /// The `UserDefaults` key the choice is kept under.
    package static let defaultsKey = "soundTheme"

    /// The stored choice; anything unset or unrecognised is Kiteloop's own.
    package init(stored: String?) {
        self = stored.flatMap(SoundTheme.init(rawValue:)) ?? .soft
    }

    package var label: String {
        switch self {
        case .soft: "Kiteloop"
        case .system: "System"
        case .silent: "Off"
        }
    }

    /// What a banner for a cue sounds like.
    package enum BannerSound: Equatable, Sendable {
        case none
        case systemDefault
        case systemCritical
        case file(String)
    }

    package func bannerSound(for cue: SoundCue) -> BannerSound {
        switch self {
        case .soft: .file(cue.fileName)
        case .system: cue == .failed ? .systemCritical : .systemDefault
        case .silent: .none
        }
    }
}
