import KiteloopCore
import SwiftUI

/// Settings → General → Sounds: which sounds Kiteloop makes, and a way to hear
/// its own before choosing them.
struct SoundSettingsSection: View {
    @AppStorage(SoundTheme.defaultsKey) private var stored = SoundTheme.soft.rawValue

    /// What the section says under the picker for a theme.
    static func explanation(for theme: SoundTheme) -> String {
        switch theme {
        case .soft: "Kiteloop's own short, quiet sounds: one when an agent finishes, one when something needs you, one when an agent stops."
        case .system: "The macOS alert sound on every banner, and a pop when an agent finishes while you are in the app."
        case .silent: "Banners and finished turns make no sound. The Dock badge and the banners themselves still appear."
        }
    }

    var body: some View {
        Section("Sounds") {
            Picker("Sounds", selection: $stored) {
                ForEach(SoundTheme.allCases, id: \.rawValue) { theme in
                    Text(theme.label).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings-sound-theme")

            if SoundTheme(stored: stored) == .soft {
                HStack {
                    ForEach(SoundCue.allCases, id: \.rawValue) { cue in
                        Button {
                            SoundCues.play(cue, theme: .soft)
                        } label: {
                            Label(cue.label, systemImage: "speaker.wave.2")
                        }
                        .accessibilityIdentifier("settings-sound-preview-\(cue.rawValue)")
                    }
                    Spacer()
                }
                .controlSize(.small)
            }

            Text(Self.explanation(for: SoundTheme(stored: stored)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
