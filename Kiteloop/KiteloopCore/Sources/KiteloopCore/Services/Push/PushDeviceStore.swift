import Foundation

/// A phone that asked to be told when something happens on this Mac.
package struct PushDevice: Codable, Sendable, Equatable {
    package let token: String
    package let environment: APNs.Environment
    package var name: String
    package var registeredAt: Date

    package init(token: String, environment: APNs.Environment, name: String, registeredAt: Date) {
        self.token = token
        self.environment = environment
        self.name = name
        self.registeredAt = registeredAt
    }
}

/// The phones registered for pushes, in `~/.kiteloop/push-devices.json`,
/// readable by this user only. A token registered again replaces its entry,
/// so a phone that re-registers on every launch stays one row.
package actor PushDeviceStore {
    private let url: URL
    private var devices: [PushDevice]

    package init(url: URL) {
        self.url = url
        devices = PrivateJSONFile.load([PushDevice].self, from: url) ?? []
    }

    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/push-devices.json")
    }

    package func all() -> [PushDevice] { devices }

    package func register(_ device: PushDevice) {
        devices.removeAll { $0.token == device.token }
        devices.append(device)
        save()
    }

    package func remove(token: String) {
        let before = devices.count
        devices.removeAll { $0.token == token }
        if devices.count != before { save() }
    }

    private func save() {
        PrivateJSONFile.save(devices, to: url)
    }
}
