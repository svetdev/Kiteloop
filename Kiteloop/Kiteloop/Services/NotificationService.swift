import AppKit
import Foundation
import KiteloopCore
import os.log
import UserNotifications

private let badgeLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "badge")

/// Where clicking a gate's banner takes the person: the same place the
/// Waiting-on-you drawer's row for that gate goes.
///
/// Carried in the banner's `userInfo`, which only holds property-list values,
/// so it is written out as strings and read back by `init?(userInfo:)`. A
/// banner without one — a hook, a notice that named no project — parses to
/// nil, and a click on it only raises the window.
struct BannerDestination: Equatable, Sendable {
    enum Kind: String, Sendable {
        case approval
        case question
        /// A finished turn: the agent's chat, not a gate.
        case chat
    }

    let kind: Kind
    /// The canonical project id when the caller had one, otherwise the
    /// project's root path. The window matches either.
    let project: String
    /// The item waiting on approval, or the agent asking the question or
    /// whose turn finished.
    let id: String

    private static let kindKey = "bannerDestination.kind"
    private static let projectKey = "bannerDestination.project"
    private static let idKey = "bannerDestination.id"

    init(kind: Kind, project: String, id: String) {
        self.kind = kind
        self.project = project
        self.id = id
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.kindKey] as? String, let kind = Kind(rawValue: raw),
              let project = userInfo[Self.projectKey] as? String,
              let id = userInfo[Self.idKey] as? String else { return nil }
        self.init(kind: kind, project: project, id: id)
    }

    var userInfo: [String: String] {
        [Self.kindKey: kind.rawValue, Self.projectKey: project, Self.idKey: id]
    }

    /// The drawer's gate for the same destination, which is what the window
    /// knows how to open. Nil for a finished turn, which is no gate: the
    /// window opens that agent's chat itself.
    var gate: WaitingOnYou.Row.Gate? {
        switch kind {
        case .approval: .approval(itemID: id)
        case .question: .question(agentID: id)
        case .chat: nil
        }
    }

    /// Where an inbox notice's banner goes. Nil for a notice that named no
    /// project, and for a type that is not a gate.
    static func forNotice(_ item: NotificationItem) -> BannerDestination? {
        guard let path = item.projectPath else { return nil }
        switch item.type {
        case .approval: return BannerDestination(kind: .approval, project: path, id: item.itemID ?? "")
        case .question: return BannerDestination(kind: .question, project: path, id: item.agentID)
        case .complete, .error, .event: return nil
        }
    }
}

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private(set) var pendingCount = 0

    private init() {
        requestPermission()
    }

    /// Whether this process may reach the system — Notification Center, the
    /// Dock tile, the attention request. Under the XCTest host it may not: the
    /// counts and the per-gate ledger still run, which is what the tests
    /// assert, and nothing is posted. Before this, every parallel host clone
    /// badged its own Dock tile and posted real banners while the suite ran.
    private static var reachesTheSystem: Bool { !UITestingSupport.isUnitTesting }

    private func requestPermission() {
        guard Self.reachesTheSystem else { return }
        PermissionAuditLogger.shared.log(.notification, purpose: "notification service init")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            badgeLog.info("Notification auth: granted=\(granted), error=\(String(describing: error))")
        }
    }

    /// An agent's turn ended while the app was in the background. The banner
    /// names the project as well as the agent, and a click opens that chat.
    func notifyTaskComplete(agentName: String, projectName: String, summary: String,
                            destination: BannerDestination) {
        guard !NSApplication.shared.isActive else { return }

        requestAttention()

        pendingCount += 1
        updateDockBadge()

        let banner = Self.finishedBanner(agentName: agentName, projectName: projectName, reply: summary)
        let content = Self.bannerContent(title: banner.title, body: banner.body, badge: pendingCount,
                                         destination: destination)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        deliver(request)
    }

    /// The longest body a finished banner quotes before it cuts.
    static let finishedBodyLimit = 100

    /// What the finished banner says: the agent and its project, and the
    /// reply's first line of prose with its markdown symbols taken out, cut at
    /// a word boundary.
    static func finishedBanner(agentName: String, projectName: String, reply: String) -> (title: String, body: String) {
        let line = reply.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("~~~") } ?? ""
        return (title: "\(agentName) finished in \(projectName)",
                body: truncatedAtWord(plainText(line), limit: finishedBodyLimit))
    }

    /// One line of markdown without heading hashes, a list marker, emphasis
    /// asterisks and underscores, or backticks.
    private static func plainText(_ line: String) -> String {
        var text = line
        for pattern in [#"^#{1,6}\s+"#, #"^(?:[-*+]|\d+[.)])\s+"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"[*`]"#, with: "", options: .regularExpression)
        // An underscore only as emphasis — at a word's edge — so `snake_case` stays whole.
        text = text.replacingOccurrences(of: #"(?<!\w)_+|_+(?!\w)"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `text` whole when it fits, otherwise cut at the last space before
    /// `limit` with an ellipsis.
    private static func truncatedAtWord(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Hooks

    /// What a Notify User hook puts on screen, and under which key.
    ///
    /// The title is the person's own words, verbatim — a hook titled "Build
    /// broken" says "Build broken". The key is the rule, so a hook that fires
    /// again replaces its own banner instead of stacking a column of them.
    static func hookBanner(ruleID: String, title: String, body: String) -> (title: String, body: String, key: String) {
        (title: title, body: String(body.prefix(140)), key: "hook|\(ruleID)")
    }

    /// A Notify User hook firing. Unlike the gates, this is raised whether or
    /// not the app is frontmost: a hook the person wrote by hand is an
    /// instruction, and it has no inbox row to fall back to.
    func notifyHookFired(ruleID: String, title: String, body: String) {
        let banner = Self.hookBanner(ruleID: ruleID, title: title, body: body)
        self.banner(title: banner.title, body: banner.body, gate: banner.key)
    }

    func clearBadge() {
        guard pendingCount > 0 else { return }
        pendingCount = 0
        updateDockBadge()
        // The user has come back to the app and seen what was waiting, so the
        // gates already banner-ed are settled as far as this channel goes. A
        // gate reached again after this point is news again.
        deliveredGates.reset()
        guard Self.reachesTheSystem else { return }
        UNUserNotificationCenter.current().setBadgeCount(0)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Human gates

    /// Remembers which gates have already produced a banner.
    ///
    /// A gate — a run parked at Awaiting Approval, an agent stopped on a
    /// question — can be re-emitted as the state it produced is re-observed;
    /// the human is blocked once, so they get told once.
    struct GateLedger {
        private var seen: Set<String> = []

        /// True the first time a gate is seen, false for every re-emission of it.
        mutating func shouldDeliver(_ gate: String) -> Bool {
            seen.insert(gate).inserted
        }

        mutating func reset() {
            seen.removeAll()
        }
    }

    private var deliveredGates = GateLedger()

    /// The gates the leaving-the-app catch-up has already bannered.
    ///
    /// Deliberately not `deliveredGates`: `clearBadge` resets that one a couple
    /// of seconds after the app becomes active, so reusing it would re-banner
    /// every gate still open on every single app switch. This one is never
    /// reset, so a gate the operator has already been told about stays told for
    /// the rest of the launch.
    private var gatesBanneredOnLeaving = GateLedger()

    /// Which inbox notification types also reach the macOS system channel.
    ///
    /// Only the two the human has to act on *right now*: a run waiting on their
    /// approval, and an agent waiting on their answer. `.complete` and `.event`
    /// are things to read later, and a banner for them is what trains someone to
    /// ignore banners. (`.complete` and `.error` still have their own entry
    /// points — `notifyTaskComplete`, `notifyError` — for callers that are not
    /// going through the inbox; this decides only what an inbox item triggers.)
    static func usesSystemChannel(_ type: NotificationItem.NotificationType) -> Bool {
        switch type {
        case .approval, .question: return true
        case .complete, .error, .event: return false
        }
    }

    /// Identifies the *gate*, not the emission — everything but the item's id
    /// and timestamp, which are fresh on every re-emission of the same gate.
    static func gateKey(for item: NotificationItem) -> String {
        "\(item.type.rawValue)|\(item.agentID)|\(item.title)|\(item.body)"
    }

    /// Posts the system-channel half of an inbox notification.
    ///
    /// Called from `Orchestrator.notify` — the one place inbox items are made —
    /// so *whether* a notification is warranted is decided once and both
    /// channels follow from that decision.
    func deliverSystemNotification(for item: NotificationItem) {
        guard Self.usesSystemChannel(item.type) else { return }
        let gate = Self.gateKey(for: item)
        let destination = BannerDestination.forNotice(item)
        switch item.type {
        case .approval:
            notifyApprovalNeeded(headline: item.title, detail: item.body, gate: gate, destination: destination)
        case .question:
            notifyQuestion(headline: item.title, question: item.body, gate: gate, destination: destination)
        case .complete, .error, .event:
            break
        }
    }

    /// A run parked at a human gate. `headline` names the project, `detail` the
    /// item waiting on the human.
    func notifyApprovalNeeded(headline: String, detail: String, gate: String,
                              destination: BannerDestination? = nil) {
        post(title: headline, body: String(detail.prefix(120)), gate: gate, destination: destination)
    }

    /// An agent that stopped mid-turn to ask the human something. `headline`
    /// names the agent, `question` is quoted back (truncated).
    func notifyQuestion(headline: String, question: String, gate: String,
                        destination: BannerDestination? = nil) {
        post(title: headline, body: String(question.prefix(140)), gate: gate, destination: destination)
    }

    /// One banner per gate, and only when the user isn't already looking at the
    /// app — a focused user has the in-app inbox and its badge.
    private func post(title: String, body: String, gate: String, destination: BannerDestination?) {
        guard !NSApplication.shared.isActive else { return }
        guard deliveredGates.shouldDeliver(gate) else { return }
        banner(title: title, body: body, gate: gate, destination: destination)
    }

    /// The banner itself. Judges nothing about focus or novelty — each caller
    /// has already made that call, and they do not make it the same way.
    private func banner(title: String, body: String, gate: String, destination: BannerDestination? = nil) {
        requestAttention()

        pendingCount += 1
        updateDockBadge()

        let content = Self.bannerContent(title: title, body: body, badge: pendingCount, destination: destination)

        // The gate is the identifier too, so a re-post replaces rather than
        // stacks even if the ledger was reset in between.
        let request = UNNotificationRequest(identifier: gate, content: content, trigger: nil)
        deliver(request)
    }

    /// What a gate's banner carries. The destination, when there is one, rides
    /// in `userInfo` for `AppDelegate` to read back when the banner is clicked.
    static func bannerContent(title: String, body: String, badge: Int,
                              destination: BannerDestination?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badge)
        if let destination {
            content.userInfo = destination.userInfo
        }
        return content
    }

    // MARK: - Leaving the app

    /// Identifies a gate read off the live waiting list, for the ledger that
    /// decides whether leaving the app should banner it.
    ///
    /// Built from the kind, the project and what is waiting rather than from
    /// the row's own id, which carries a project uuid a reopened project does
    /// not keep. Nil for `.stale`: a flag is nothing a person approves or
    /// answers, so there is no gate to raise them for.
    ///
    /// An approval keys on the row's title, which is the item's and so already
    /// distinct per item. A question keys on its own words instead: a question
    /// row's title is the notice headline, which `pauseForHuman` writes as
    /// "<agent> needs input" every time — keyed on that, every question after
    /// an agent's first would be the gate already bannered, and the ledger,
    /// which is never reset by design, would swallow it for the rest of the
    /// launch. Two different questions from one agent are two gates.
    static func gateKey(for row: WaitingOnYou.Row) -> String? {
        switch row.gate {
        case .approval: "leaving|approval|\(row.projectName)|\(row.title)"
        case .question: "leaving|question|\(row.projectName)|\(row.detail ?? row.subtitle)"
        case .stale: nil
        }
    }

    /// Banners every gate that is still open as the app leaves the foreground.
    ///
    /// A gate that opened while the operator happened to be looking at Kiteloop
    /// never reached the system channel — `post`'s frontmost guard dropped it,
    /// and the approval summons is emitted exactly once, so nothing re-raises
    /// it. Switching away is the moment that drop becomes a silence, so the
    /// gates still open are read off the live waiting list and raised here.
    ///
    /// `post`'s guard is bypassed on purpose rather than loosened: the app is
    /// on its way out of focus and `isActive` can still read true at this
    /// point.
    func notifyOpenGatesOnLeaving(_ rows: [WaitingOnYou.Row]) {
        for row in rows {
            guard let gate = Self.gateKey(for: row) else { continue }
            guard gatesBanneredOnLeaving.shouldDeliver(gate) else { continue }
            switch row.gate {
            case .approval(let itemID):
                banner(title: "Approval needed in \(row.projectName)",
                       body: String("\(itemID) — \(row.title)".prefix(120)), gate: gate,
                       destination: BannerDestination(kind: .approval, project: row.projectID, id: itemID))
            case .question(let agentID):
                banner(title: row.title,
                       body: String((row.detail ?? row.subtitle).prefix(140)), gate: gate,
                       destination: BannerDestination(kind: .question, project: row.projectID, id: agentID))
            case .stale:
                break
            }
        }
    }

    /// An agent's process died and every reconnect attempt failed while the
    /// app was in the background. Like the finished banner, it names the
    /// project as well as the agent, and a click opens that chat.
    func notifyError(agentName: String, projectName: String, reason: String?,
                     destination: BannerDestination) {
        guard !NSApplication.shared.isActive else { return }

        requestAttention()

        pendingCount += 1
        updateDockBadge()

        let banner = Self.crashedBanner(agentName: agentName, projectName: projectName, reason: reason)
        let content = Self.bannerContent(title: banner.title, body: banner.body, badge: pendingCount,
                                         destination: destination)
        content.sound = .defaultCritical

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        deliver(request)
    }

    /// What the crashed banner says: the agent and its project, and why the
    /// last restart failed, cut at a word boundary.
    static func crashedBanner(agentName: String, projectName: String, reason: String?) -> (title: String, body: String) {
        (title: "\(agentName) stopped in \(projectName)",
         body: truncatedAtWord(reason ?? "It could not be restarted, and no reason was given.",
                               limit: finishedBodyLimit))
    }

    private func updateDockBadge() {
        let label = pendingCount > 0 ? "\(pendingCount)" : nil
        guard Self.reachesTheSystem else { return }
        NSApplication.shared.dockTile.badgeLabel = label
        badgeLog.info("Dock badge set to: \(label ?? "nil"), pendingCount=\(self.pendingCount)")
    }

    private func deliver(_ request: UNNotificationRequest) {
        guard Self.reachesTheSystem else { return }
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAttention() {
        guard Self.reachesTheSystem else { return }
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }
}
