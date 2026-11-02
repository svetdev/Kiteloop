import Foundation
import Observation

/// The last answer an injected probe gave — whether Ollama or the Copilot
/// bridge is up — read again on every `refresh()`. A surface that read the
/// probe once, in a `.task`, kept its first answer for the life of the view, so
/// a runtime started after launch stayed "not running" until a relaunch; the
/// quick-add menu and Settings ▸ General refresh this when they are opened
/// instead. `value` is nil until the first answer arrives.
@MainActor
@Observable
final class RuntimeProbe<Value: Sendable> {
    private(set) var value: Value?
    @ObservationIgnored private let probe: @Sendable () async -> Value

    init(_ probe: @escaping @Sendable () async -> Value) {
        self.probe = probe
    }

    func refresh() async {
        value = await probe()
    }
}
