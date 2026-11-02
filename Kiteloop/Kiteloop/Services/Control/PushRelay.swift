import Foundation
import KiteloopCore
import os

private let pushLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "push")

/// Tells the phone when something happens on this Mac, through Apple's push
/// service: an item reaches the approval gate, an agent asks something or has
/// a plan ready, a background project's agents finish, or a turn started from
/// the phone ends. Each registered phone gets the push; one whose token the
/// service says is dead is forgotten.
///
/// Nothing is sent until Settings → Control API holds a push key — `problem`
/// then says what is missing, which is what Settings shows.
@MainActor
final class PushRelay {
    static let shared = PushRelay()

    typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    private(set) var devices: PushDeviceStore?
    private var key: () -> PushKeyConfig? = { nil }
    var transport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
    var now: () -> Date = Date.init

    /// Why nothing could be pushed, as Settings shows it; nil when the key is set and loads.
    private(set) var problem: String? = "No push key is set, so phones get no notifications."
    /// The provider token, kept until it is old enough that Apple wants a new one.
    private var providerToken: (value: String, issuedAt: Date, keyID: String)?
    /// Apple accepts a token for an hour and refuses refreshes more often than
    /// every twenty minutes; renewing at forty sits between the two.
    static let tokenLifetime: TimeInterval = 40 * 60

    init() {}

    func configure(devices: PushDeviceStore, key: @escaping () -> PushKeyConfig?) {
        self.devices = devices
        self.key = key
        providerToken = nil
        problem = Self.problem(with: key())
    }

    /// After Settings saves a new key: the old provider token is dropped and
    /// the key checked again, so `problem` reads the key that is set now.
    func keyChanged() {
        providerToken = nil
        problem = Self.problem(with: key())
    }

    static func problem(with key: PushKeyConfig?) -> String? {
        guard let key, key.isComplete else { return "No push key is set, so phones get no notifications." }
        do {
            _ = try APNs.token(pem: try APNs.readKey(at: key.keyPath), keyID: key.keyID, teamID: key.teamID, issuedAt: .now)
            return nil
        } catch APNs.KeyError.unreadable(let reason), APNs.KeyError.notAKey(let reason) {
            return "The push key can't be used: \(reason)."
        } catch {
            return "The push key can't be used: \(error.localizedDescription)."
        }
    }

    // MARK: - What is pushed

    /// A notice the Mac raised, pushed when it is one a person away from the
    /// Mac would act on.
    func relay(_ item: NotificationItem) {
        guard let push = Self.push(for: item) else { return }
        Task { await send(title: push.title, body: push.body, info: push.info) }
    }

    /// What a notice becomes on the phone, or nil for one not worth a push.
    static func push(for item: NotificationItem) -> (title: String, body: String, info: [String: String])? {
        guard let kind = kind(of: item.type) else { return nil }
        var info: [String: String] = ["kind": kind]
        if let path = item.projectPath { info["project"] = URL(fileURLWithPath: path).lastPathComponent }
        if !item.agentID.isEmpty { info["agent"] = item.agentID }
        if kind == "approval", let itemID = item.itemID { info["item"] = itemID }
        return (item.title, String(item.body.prefix(180)), info)
    }

    /// The `kind` a phone opens a push by, or nil for a notice not pushed.
    private static func kind(of type: NotificationItem.NotificationType) -> String? {
        switch type {
        case .approval: "approval"
        case .question: "question"
        case .complete: "finished"
        case .error, .event: nil
        }
    }

    /// A turn started from the phone has ended; the reply's first line goes with it.
    func turnFinished(project: String, agentID: String, agentName: String, reply: String) {
        let firstLine = reply.split(separator: "\n").first.map(String.init) ?? "Done."
        Task {
            await send(title: "\(agentName) finished", body: String(firstLine.prefix(180)),
                       info: ["kind": "finished", "project": project, "agent": agentID])
        }
    }

    // MARK: - Live Activities

    /// The Live Activity a phone started for a turn, by project and agent: the
    /// activity's own push token. Held in memory — an activity lives for one
    /// turn, and one the Mac forgets across a relaunch ends on the phone.
    private var activities: [String: (token: String, environment: APNs.Environment)] = [:]

    private static func activityKey(project: String, agent: String) -> String { "\(project)/\(agent)" }

    func registerActivity(token: String, environment: APNs.Environment, project: String, agent: String) {
        activities[Self.activityKey(project: project, agent: agent)] = (token, environment)
    }

    var activityCount: Int { activities.count }

    /// Moves the activity for this agent on — or ends it, after which it is
    /// forgotten. No activity registered for the agent sends nothing.
    func updateActivity(project: String, agent: String, working: Bool, status: String, line: String, ends: Bool) {
        let key = Self.activityKey(project: project, agent: agent)
        guard let activity = activities[key] else { return }
        if ends { activities[key] = nil }
        let payload = APNs.liveActivityPayload(working: working, status: status, line: String(line.prefix(120)),
                                               ends: ends, at: now())
        guard let token = currentToken(),
              let request = APNs.liveActivityRequest(token: activity.token, environment: activity.environment,
                                                     providerToken: token, payload: payload) else { return }
        let transport = transport
        Task {
            do {
                let (status, _) = try await transport(request)
                if status != 200 { pushLog.error("live activity update answered \(status)") }
            } catch {
                pushLog.error("live activity update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Sending

    /// Sends to every registered phone; answers how many took it.
    @discardableResult
    func send(title: String, body: String, info: [String: String]) async -> Int {
        guard let devices, case let registered = await devices.all(), !registered.isEmpty,
              let token = currentToken() else { return 0 }
        let payload = APNs.payload(title: title, body: body, info: info)
        var delivered = 0
        for device in registered where await deliver(payload, to: device, token: token, in: devices) {
            delivered += 1
        }
        return delivered
    }

    /// One phone's push; a token the service calls dead is forgotten.
    private func deliver(_ payload: Data, to device: PushDevice, token: String, in devices: PushDeviceStore) async -> Bool {
        guard let request = APNs.request(device: device.token, environment: device.environment,
                                         providerToken: token, payload: payload) else { return false }
        do {
            let (status, reply) = try await transport(request)
            if APNs.isDeadToken(status: status, body: reply) { await devices.remove(token: device.token) }
            guard status == 200 else {
                pushLog.error("push to \(device.name, privacy: .public) answered \(status)")
                return false
            }
            return true
        } catch {
            pushLog.error("push to \(device.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func currentToken() -> String? {
        guard let key = key(), key.isComplete else { problem = Self.problem(with: nil); return nil }
        if let cached = providerToken, cached.keyID == key.keyID,
           now().timeIntervalSince(cached.issuedAt) < Self.tokenLifetime {
            return cached.value
        }
        do {
            let issuedAt = now()
            let value = try APNs.token(pem: try APNs.readKey(at: key.keyPath), keyID: key.keyID,
                                       teamID: key.teamID, issuedAt: issuedAt)
            providerToken = (value, issuedAt, key.keyID)
            problem = nil
            return value
        } catch {
            problem = Self.problem(with: key)
            return nil
        }
    }
}
