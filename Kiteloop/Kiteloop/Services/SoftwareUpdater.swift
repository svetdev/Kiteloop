import Combine
import Foundation
import KiteloopCore
import Sparkle

/// In-app updates, by Sparkle: it reads the appcast `SUFeedURL` names, and
/// when that lists a newer version it downloads it, verifies its EdDSA
/// signature against `SUPublicEDKey`, replaces this copy and relaunches. The
/// window, the release notes, Skip This Version and the daily schedule are
/// Sparkle's own — this type is the three things the app says to it: check
/// now, check on a schedule or not, and download in the background or not.
///
/// The relaunch needs nothing of its own for runs in flight. Sparkle quits the
/// app the way Cmd-Q does, so `AppDelegate.applicationShouldTerminate` asks its
/// usual question about them, and an update whose quit was cancelled installs
/// when the app next quits.
@MainActor
@Observable
final class SoftwareUpdater {
    /// Whether this copy updates itself. Not a test host — a dozen of those
    /// run at once and none should ask the network anything — and not a Debug
    /// build, which Xcode replaces on every run and Sparkle would replace with
    /// the release under it.
    nonisolated static var updatesThisCopy: Bool {
        #if DEBUG
        return false
        #else
        return !UITestingSupport.isTesting
        #endif
    }

    /// False while a check is already running, and always in a copy that does
    /// not update itself: what the menu item is enabled by.
    private(set) var canCheckForUpdates = false

    /// App Preferences' "Automatically check for updates".
    var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// App Preferences' "Automatically download updates": a found update is
    /// fetched without asking and installed when the app quits.
    var automaticallyDownloadsUpdates = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    /// Nil in a copy that does not update itself.
    private let controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    /// `startsUpdater` is false only where a test builds the real updater: one
    /// that is never started schedules nothing and asks the network nothing.
    init(updatesThisCopy: Bool = SoftwareUpdater.updatesThisCopy, startsUpdater: Bool = true,
         defaults: UserDefaults = .standard) {
        let legacyChoice = LegacyUpdatePreferences.retire(from: defaults)
        guard updatesThisCopy else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: startsUpdater, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        if let legacyChoice {
            updater.automaticallyChecksForUpdates = legacyChoice
        }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        canCheckObservation = updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    /// The menu item: asks now, and Sparkle always answers — a newer version,
    /// none, or why it could not tell.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Whether the preferences have anything to switch.
    var isAvailable: Bool { controller != nil }
}
