import SwiftUI

/// The non-modal notice behind **Check for Updates…**, and what a passive
/// check at launch opens when the public repository has published something
/// newer. Opened any other way — the Window menu, a window restored at
/// launch — it asks for itself, so it always ends on an answer. A window
/// rather than an alert so it never stands between the user and their work,
/// and a link rather than a download: installing is a separate job this app
/// does not do yet.
struct SoftwareUpdateView: View {
    /// The scene id `openWindow` reaches this view by.
    static let windowID = "software-update"

    let service: UpdateCheckService

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            Text("Software Update")
                .font(.headline)
            message
            Spacer(minLength: 0)
            HStack(spacing: KiteloopTokens.Spacing.md) {
                if case .available(let release) = service.state {
                    Link("Download on GitHub", destination: release.url)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("update-download-link")
                }
                Spacer()
                Button("Check Again") { Task { await service.checkNow() } }
                    .disabled(service.state == .checking)
            }
        }
        .padding(KiteloopTokens.Spacing.xl)
        .frame(minWidth: 380, minHeight: 160)
        // The window is also in the Window menu and is restored at launch, so
        // it can appear with no check behind it. Asking here means no caller
        // has to start one beside `openWindow`, and a window that already has
        // an answer keeps it.
        .task { await service.checkIfNothingToShow() }
    }

    @ViewBuilder
    private var message: some View {
        switch service.state {
        case .idle, .checking:
            HStack(spacing: KiteloopTokens.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            Text("Kiteloop \(service.installedVersion) is the latest version.")
        case .available(let release):
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                Text("Kiteloop \(release.version) is available.")
                    .font(.body.weight(.semibold))
                Text("You have \(service.installedVersion).")
                    .foregroundStyle(.secondary)
                if !release.notes.isEmpty {
                    ScrollView {
                        SelectableMarkdownView(markdown: release.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 80, maxHeight: 240)
                    .accessibilityIdentifier("update-release-notes")
                }
            }
            .accessibilityIdentifier("update-available-notice")
        case .unreachable(let failure):
            Text(Self.sentence(for: failure))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("update-failure-notice")
        }
    }

    /// What the notice says for each way a check can come back empty.
    static func sentence(for failure: UpdateCheckFailure) -> String {
        switch failure {
        case .endpointUnreachable: return "Couldn't reach GitHub to check for updates."
        case .noReleasePublished: return "No release of Kiteloop has been published yet."
        case .rateLimited: return "GitHub is limiting requests right now. Try again later."
        case .malformedRelease: return "GitHub answered, but its release information couldn't be read."
        }
    }
}
