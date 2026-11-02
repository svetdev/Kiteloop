import Observation
import UIKit
import UserNotifications

/// Where a tapped notification leads: the project it came from, and the
/// agent's chat for a question or a finished turn.
struct PushRoute: Equatable {
    let project: String
    let agent: String?
    let kind: String

    /// Reads the fields the Mac puts beside the alert (`APNs.payload`).
    init?(userInfo: [AnyHashable: Any]) {
        guard let project = userInfo["project"] as? String, !project.isEmpty else { return nil }
        self.project = project
        agent = (userInfo["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        kind = userInfo["kind"] as? String ?? "finished"
    }

    /// Whether the tap should open the agent's chat rather than just the project.
    var opensChat: Bool { agent != nil && kind != "approval" }
}

/// This phone's push token, sent to the paired Mac so it can tell the phone
/// when something needs it, and the route the last tapped notification asked for.
@Observable @MainActor
final class PushRegistration: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistration()

    private(set) var deviceToken: String?
    /// Set by a tap on a notification; the project screen takes it and clears it.
    var pendingRoute: PushRoute?
    /// Why the last registration with the Mac did not take, for the Fleet screen.
    private(set) var problem: String?

    /// The push service this build's token belongs to: a build run from Xcode
    /// talks to the sandbox, a TestFlight build to production.
    nonisolated static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Asks once for permission to notify, then for a token.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func received(token: Data) {
        deviceToken = Self.hex(token)
    }

    /// Tells the Mac `client` reaches about this phone. Called when the token
    /// arrives or changes and whenever the phone switches Mac.
    func register(with client: ControlClient) async {
        guard let deviceToken else { return }
        do {
            let reply = try await client.post("/v1/devices/push", [
                "token": deviceToken, "environment": Self.environment, "name": UIDevice.current.name,
            ])
            problem = reply["problem"] as? String
        } catch {
            problem = error.localizedDescription
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { pendingRoute = route }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Hands the push token UIKit delivers to the app delegate on to `PushRegistration`.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.received(token: deviceToken) }
    }
}
