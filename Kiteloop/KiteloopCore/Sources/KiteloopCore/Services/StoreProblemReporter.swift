import Foundation
import os.log

/// The one place a persistence layer says "I could not read or write X".
///
/// Kiteloop's stores fail silently by construction: `try? AtomicFileWriter.write(…)`
/// at a call site with nowhere to report to discards the error, and the human
/// learns their settings stopped saving by noticing that their settings keep
/// coming back. Every such site needs the same two things — a row in the inbox
/// they already watch, and a Diagnostics line naming the store, the operation and
/// the file — so those two live here rather than being invented once per store.
///
/// Callers are sync failure paths (`catch` arms inside a `save()`), so `report`
/// is sync and returns immediately: the Diagnostics line is written on the
/// caller's thread, and the notification is posted behind it on a serial chain.
///
/// The inbox belongs to a project, and the earliest failures — the settings
/// store at launch, the package scan during bootstrap — happen before one is
/// open. Those reports are held rather than dropped, and filed the moment
/// `configure(notifications:)` attaches an inbox.
package final class StoreProblemReporter: @unchecked Sendable {

    /// The app-wide reporter. A single instance reached from anywhere, like
    /// `PermissionAuditLogger` — injectable for tests via `init(notifications:)`.
    package static let shared = StoreProblemReporter()

    /// What the store was doing. The only two things a persistence layer does.
    package enum Operation: String, Sendable {
        case read
        case write
    }

    /// The Diagnostics category these lines carry, so the window can filter to
    /// them.
    package static let logCategory = "store-problem"

    private let lock = NSLock()
    private var notifications: NotificationStoring?
    /// The row each store+operation already has in the inbox, keyed by
    /// ``key(store:operation:)``. A store failing every autosave refreshes its
    /// one row rather than filing hundreds of identical ones.
    private var posted: [String: String] = [:]
    /// Reports made before any inbox was attached, in the order they were made.
    /// The launch paths — the settings store, the package scan — run before a
    /// project exists, so a failure there had nowhere to go at all; it waits
    /// here and is filed when ``configure(notifications:)`` attaches one. Keyed
    /// like ``posted``, so a store failing in a loop holds one entry rather than
    /// a queue of identical ones.
    private var held: [(key: String, item: NotificationItem)] = []
    /// Notification work runs one at a time, behind whatever was queued before
    /// it: a refresh reads and replaces a row this same chain wrote, so two
    /// failures arriving together must not interleave into two pending rows.
    private var tail: Task<Void, Never>?

    package init(notifications: NotificationStoring? = nil) {
        self.notifications = notifications
    }

    /// Points the reporter at the inbox a project keeps, and files whatever was
    /// reported before there was one.
    ///
    /// The rows remembered for dedup belong to the store being replaced, so they
    /// are forgotten with it: the next failure files a fresh row in the new
    /// inbox rather than trying to refresh one that was never there. Reports
    /// that reached no inbox at all are a different case — they were never
    /// filed anywhere, so they go into this one, in the order they were made.
    package func configure(notifications: NotificationStoring?) {
        let flush: [(key: String, item: NotificationItem)] = lock.withLock {
            self.notifications = notifications
            posted.removeAll()
            // Still no inbox: keep holding rather than dropping what is held.
            guard notifications != nil else { return [] }
            let waiting = held
            held.removeAll()
            return waiting
        }
        for entry in flush {
            enqueue(entry.item, key: entry.key)
        }
    }

    /// Reports that `store` could not `operation` the file at `url`.
    ///
    /// `store` is the store's name as a human would say it — "Settings", not
    /// `GlobalConfigStore` — since it is read in a notification title. It is also
    /// half the dedup key, so one store must spell itself the same way every time.
    package func report(store: String, operation: Operation, url: URL, error: Error) {
        let path = url.path(percentEncoded: false)
        let detail = Self.describe(error)
        kiteloopLog("\(store) could not \(operation.rawValue) \(path): \(detail)",
                    category: Self.logCategory,
                    level: .error)

        // No agent is behind a store failing, and the inbox already spells that
        // as an empty agent id (`MainWindow`'s background-project completions).
        let item = NotificationItem(agentID: "",
                                    type: .error,
                                    title: "Could not \(operation.rawValue) \(store)",
                                    body: "\(path) — \(detail)")
        enqueue(item, key: Self.key(store: store, operation: operation))
    }

    /// Waits for everything queued so far to reach the inbox.
    ///
    /// `report` returns before its notification is posted, so a caller that then
    /// reads the inbox — a test, in practice — needs a point to wait at.
    package func drain() async {
        await lock.withLock { tail }?.value
    }

    /// What identifies a row for refreshing: the store and what it was doing.
    /// A store that cannot write is one problem however many times it recurs,
    /// and one that can neither read nor write has two.
    package static func key(store: String, operation: Operation) -> String {
        "\(store)|\(operation.rawValue)"
    }

    private func enqueue(_ item: NotificationItem, key: String) {
        lock.withLock {
            guard let inbox = notifications else {
                // Nowhere to file it yet. The newest failure for a key replaces
                // the one held for it, in the place that one already holds — the
                // same refresh-rather-than-repeat rule an inbox gets, applied
                // before there is one.
                if let existing = held.firstIndex(where: { $0.key == key }) {
                    held[existing] = (key: key, item: item)
                } else {
                    held.append((key: key, item: item))
                }
                return
            }
            let previous = posted[key]
            posted[key] = item.id
            let earlier = tail
            tail = Task {
                await earlier?.value
                // Only a row still waiting on the human is replaced. One they
                // have already resolved or dismissed is settled history, and a
                // failure after that is news again rather than a refresh of it.
                if let previous, await inbox.pending().contains(where: { $0.id == previous }) {
                    await inbox.dismiss(id: previous)
                }
                await inbox.add(item)
            }
        }
    }

    /// What the error says, in one line.
    ///
    /// `String(describing:)` rather than `localizedDescription`: Kiteloop's own
    /// error types are plain enums, for which Foundation synthesises "The
    /// operation couldn't be completed. (Kiteloop.AtomicFileWriter.WriteError
    /// error 0.)" — which names neither the syscall nor the errno, while the case
    /// itself names both. A bridged `NSError` still carries its localized
    /// description inside what this prints.
    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
