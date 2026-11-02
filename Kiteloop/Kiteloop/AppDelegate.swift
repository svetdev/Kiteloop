import KiteloopCore
import AppKit
import Darwin
import UserNotifications

/// Lets a waiting quit go exactly once — on whichever of the finalize and its
/// bound arrives first. Both live on the main actor, so "exactly once" needs no
/// lock; a continuation resumed twice is a crash, and a quit is the worst place
/// to find that out.
@MainActor
private final class QuitFinalizeGate {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var primaryWindow: NSWindow?

    /// The fleet-wide hold, handed over by the app once its window exists. Nil
    /// until then, and a quit with it nil is the quit this app always had: it
    /// terminates, and every run in flight is interrupted.
    var fleetQuiesce: FleetQuiesceControl?

    /// Close the run records that have already ended, handed over by the app at
    /// launch. Nil until then, and a quit with it nil is the quit this app always
    /// had: whatever had ended without anyone asking stays open, and the next
    /// launch reads it as `interrupted`.
    var finalizeRuns: (@MainActor () async -> Void)?

    /// How long a quit waits on that pass. It writes a line per ended run and
    /// does nothing else, so this is far more than it needs — and short enough
    /// that one that has wedged costs a quit a moment rather than parking it
    /// behind a beachball with no way out.
    static let finalizeQuitBound: Duration = .seconds(3)

    /// True once a drain the operator asked for has finished, so the terminate
    /// that follows goes straight through instead of asking about a fleet that
    /// has already stopped.
    private var quitApproved = false

    /// True once the drained quit's own finalize pass has already run, so the
    /// re-entrant `applicationShouldTerminate` that `NSApp.terminate(nil)`
    /// triggers from inside that pass answers `.terminateNow` synchronously.
    /// That reentrant call happens nested on the same call stack as the
    /// `NSApp.terminate(nil)` that triggered it — a `.terminateLater` there
    /// waits on a `NSApp.reply` that a blocked stack frame can never deliver.
    private var quitFinalized = false

    /// True while the offer is on screen. A second Cmd-Q must not stack a second
    /// alert on top of a `terminateLater` that has yet to be answered.
    private var isAskingAboutQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UITestingSupport.isUnitTesting {
            // This process is the XCTest host, not the app: with the suite
            // running in parallel there are a dozen of them at once, and each
            // used to take a Dock tile, set a badge on it and ask Notification
            // Center for permission. An accessory process has no Dock tile to
            // badge, and the notification channel is shut off below in
            // NotificationService, so a test can exercise the code that badges
            // and posts without a person's Dock filling up with clones.
            NSApplication.shared.setActivationPolicy(.accessory)
            Self.raiseFileDescriptorLimit()
            return
        }
        Self.raiseFileDescriptorLimit()
        Self.reapOrphanedSessionFiles()
        UNUserNotificationCenter.current().delegate = self
        PermissionAuditLogger.shared.log(.notification, purpose: "request notification authorization")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.primaryWindow = NSApplication.shared.windows.first { $0.canBecomeMain }
        }
    }

    /// Raise the process's open-file (descriptor) limit. Each autopilot item
    /// restarts the worker + reviewer agents — a `claude` subprocess with several
    /// pipes/FIFOs — and a multi-hour marathon does hundreds of restarts. At the
    /// 256 soft default, leaked descriptors exhausted the limit after ~36 items and
    /// every subsequent item failed at $0 (dead session). Raising the soft limit
    /// toward the hard cap keeps a long run well clear of that wall.
    static func raiseFileDescriptorLimit(target: rlim_t = 8192) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired = min(target, limit.rlim_max)
        if limit.rlim_cur < desired {
            limit.rlim_cur = desired
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    /// Sweep session FIFOs and MCP configs whose owning process is gone.
    /// `applicationWillTerminate` covers an orderly quit, but a crash, a force
    /// quit or the XCTest host displacing the app skips it entirely and strands
    /// four files per live session. Reaping at launch bounds that to one
    /// generation instead of letting it pile up against the descriptor limit.
    static func reapOrphanedSessionFiles() {
        DispatchQueue.global(qos: .utility).async {
            let reaped = SessionTempFiles.reapOrphans()
            if reaped > 0 {
                kiteloopLog("[startup] reaped \(reaped) orphaned session temp file(s)", category: "runtime")
            }
        }
    }

    /// Offer the drain before quitting with runs in flight.
    ///
    /// Quitting mid-item is not free: the run is interrupted, its item comes back
    /// `ready` at the next launch and re-runs from scratch, losing the minutes it
    /// had spent. The fleet-wide drain that avoids that existed only as
    /// `POST /v1/fleet/quiesce`, so the app's own quit relied on
    /// `applicationWillTerminate`'s cleanup instead — which kills the subprocesses
    /// rather than letting the run reach its gate.
    ///
    /// A drained fleet is not asked about at all, and `terminateLater` covers only
    /// the reading and the alert. Choosing the drain *cancels* this quit and asks
    /// for a new one once the fleet is drained: waiting inside the terminate would
    /// park the app for the minutes a run takes with nothing on screen, while
    /// cancelling leaves it alive and answering — the footer shows what is still
    /// finishing, and Resume calls the whole thing off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let fleetQuiesce, !quitApproved else {
            return Self.terminateReply(
                hasFleet: fleetQuiesce != nil,
                quitApproved: quitApproved,
                quitFinalized: quitFinalized,
                hasFinalizer: finalizeRuns != nil
            ) == .terminateNow ? .terminateNow : finalizeThenTerminate()
        }
        guard !isAskingAboutQuit else { return .terminateCancel }
        isAskingAboutQuit = true
        Task { @MainActor in
            defer { isAskingAboutQuit = false }
            await fleetQuiesce.refresh()
            guard let reading = fleetQuiesce.reading,
                  let prompt = FleetQuitPrompt(reading: reading) else {
                await finalizeBeforeQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            switch await Self.present(prompt, on: primaryWindow) {
            case .quitNow:
                await finalizeBeforeQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            case .cancel:
                NSApp.reply(toApplicationShouldTerminate: false)
            case .quiesceThenQuit:
                fleetQuiesce.onDrainedForQuit = { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        // Finalize and mark it done *before* the terminate that
                        // follows: that terminate re-enters this method on the
                        // same call stack, and by then `quitFinalized` must
                        // already say there is nothing left to wait on.
                        self.quitApproved = true
                        await self.finalizeBeforeQuit()
                        self.quitFinalized = true
                        NSApp.terminate(nil)
                    }
                }
                fleetQuiesce.quiesceAndQuitWhenDrained()
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    /// The decision the first two guards of `applicationShouldTerminate` make
    /// once a fleet is wired: whether to short-circuit (`.terminateNow`, for a
    /// drain already finalized, or no finalizer to run) or to defer for
    /// `finalizeThenTerminate`'s async pass (`.terminateLater`) — pulled out so
    /// the table is asserted without going through AppKit's real terminate
    /// handshake.
    static func terminateReply(
        hasFleet: Bool,
        quitApproved: Bool,
        quitFinalized: Bool,
        hasFinalizer: Bool
    ) -> NSApplication.TerminateReply {
        guard hasFleet, !quitApproved else {
            if quitFinalized {
                return .terminateNow
            }
            return hasFinalizer ? .terminateLater : .terminateNow
        }
        return .terminateLater
    }

    /// The quit that has nothing to ask about — no fleet wired, or a drain the
    /// operator already approved. It still has a record to close, so it defers
    /// just long enough to write it.
    ///
    /// `.terminateNow` when there is no finalize hook either: with nothing to do,
    /// deferring the quit would buy an app hop and no closed record.
    private func finalizeThenTerminate() -> NSApplication.TerminateReply {
        guard finalizeRuns != nil else { return .terminateNow }
        Task { @MainActor in
            await finalizeBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Close whatever has ended, then let the quit go — waiting no longer than
    /// `bound` for it.
    ///
    /// Bounded rather than awaited outright because this is the one place a slow
    /// pass cannot be waited out: the quit is already inside a `terminateLater`,
    /// so a finalize that never returns is an app that never closes. Giving up on
    /// it costs exactly what quitting cost before — the records it had yet to
    /// reach stay open, and the next launch calls them `interrupted`.
    func finalizeBeforeQuit(bound: Duration = AppDelegate.finalizeQuitBound) async {
        guard finalizeRuns != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = QuitFinalizeGate(continuation)
            Task { @MainActor [weak self] in
                await self?.finalizeRuns?()
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(for: bound)
                gate.open()
            }
        }
    }

    /// Which of the two ways `present(_:on:)` shows the alert: a sheet never
    /// enters a nested modal run loop, so `KiteloopControlServer` — `@MainActor`,
    /// same as this delegate — keeps answering requests while the prompt is on
    /// screen. `runModal()` blocks that actor until a button is clicked, which
    /// is what made the control API go dark for the length of a quit prompt.
    /// Pulled out as a pure decision so the choice is asserted without an
    /// `NSAlert` on screen: a sheet needs a window to attach to, so the only
    /// time this falls back to the blocking modal is the narrow window at
    /// launch before `primaryWindow` is set.
    enum QuitPromptPresentation: Equatable {
        case sheet
        case modalSession
    }

    nonisolated static func presentation(hasWindow: Bool) -> QuitPromptPresentation {
        hasWindow ? .sheet : .modalSession
    }

    /// The offer as an alert. The copy and the button order are the prompt's, so
    /// what the operator is asked is asserted without a window on screen.
    private static func present(_ prompt: FleetQuitPrompt, on window: NSWindow?) async -> FleetQuitPrompt.Choice {
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        for choice in prompt.choices {
            alert.addButton(withTitle: choice.title)
        }
        let response: NSApplication.ModalResponse
        switch (presentation(hasWindow: window != nil), window) {
        case (.sheet, let window?):
            response = await alert.beginSheetModal(for: window)
        default:
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        // A dismissal that names no button is the escape, not the default: the
        // one reply that costs anything here is interrupting a run nobody asked
        // to interrupt.
        guard prompt.choices.indices.contains(index) else { return .cancel }
        return prompt.choices[index]
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A session already stopped was flushed by stop() on its own runtime.
        // Anything still live at quit — recording sessions killed in place by
        // the terminate below — gets one last chance here, ahead of it.
        RecordingAgentRuntime.flushAllLiveRecordings()
        // Explicitly terminate agent subprocesses — child processes are not
        // killed automatically when the app exits, and orphaned `claude`
        // processes would keep burning tokens.
        ClaudeCodeCLIRuntime.terminateAllProcesses()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.closeDuplicateWindows()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NotificationService.shared.clearBadge()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let primary = primaryWindow {
            primary.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    // Notification displayed while app is in foreground.
    // The delegate protocol is nonisolated and its parameters aren't Sendable,
    // so these entry points stay nonisolated and hop to the main actor
    // themselves (this class is @MainActor, hence Sendable).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    // Notification tapped — show primary window, close any duplicates
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let destination = BannerDestination(userInfo: response.notification.request.content.userInfo)
        await handleNotificationTap(destination)
    }

    /// Raises the window, then — for a gate's banner — asks it to open what the
    /// banner named. A banner with no destination only raises the window.
    private func handleNotificationTap(_ destination: BannerDestination?) async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let primary = primaryWindow {
            primary.makeKeyAndOrderFront(nil)
        }
        // Let the reopened window settle before pruning duplicates.
        try? await Task.sleep(for: .milliseconds(150))
        closeDuplicateWindows()
        if let destination {
            NotificationCenter.default.post(name: .openBannerDestination, object: destination)
        }
    }

    private func closeDuplicateWindows() {
        guard let primary = primaryWindow else { return }
        for window in NSApplication.shared.windows where window !== primary && window.canBecomeMain {
            window.close()
        }
        primary.makeKeyAndOrderFront(nil)
    }
}
