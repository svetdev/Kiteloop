import SwiftUI

@main
struct KiteloopMobileApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var connection = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            RootView(connection: connection)
        }
    }
}

struct RootView: View {
    @Bindable var connection: ConnectionStore

    var body: some View {
        if connection.configured {
            RootTabView(connection: connection)
        } else {
            ConnectView(connection: connection)
        }
    }
}

struct RootTabView: View {
    @Bindable var connection: ConnectionStore
    private let push = PushRegistration.shared

    var client: ControlClient {
        ControlClient(baseURL: connection.baseURL, token: connection.token)
    }

    var body: some View {
        TabView {
            ProjectView(connection: connection)
                .tabItem { Label("Projects", systemImage: "folder") }
            FleetView(connection: connection)
                .tabItem { Label("Fleet", systemImage: "slider.horizontal.3") }
        }
        // Switching Mac rebuilds every screen against the new one, so no view
        // model keeps showing the last Mac's projects.
        .id(connection.currentID)
        // Paired, so ask to notify; the token goes to whichever Mac is current.
        .task { push.start() }
        .task(id: "\(push.deviceToken ?? "")|\(connection.currentID ?? "")") { await push.register(with: client) }
    }
}
