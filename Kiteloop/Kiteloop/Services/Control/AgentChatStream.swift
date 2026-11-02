import Foundation
import KiteloopCore
import Observation

/// What the stream reads off a chat: its messages and whether a turn is
/// running, both observable. `ChatViewModel` is the one in the app; the
/// stream names this instead, so Services does not reach up into ViewModels.
@MainActor
protocol AgentChatSource: AnyObject {
    var messages: [Message] { get }
    var isStreaming: Bool { get }
    /// The question the agent stopped to ask, while it waits on one.
    var pendingHumanToolCallID: String? { get }
    /// Whether a plan card waits for an answer.
    var hasOpenPlanCard: Bool { get }
}

extension AgentChatSource {
    /// What a stopped turn waits on, as a Live Activity says it; nil when the
    /// turn simply finished.
    var waitingStatus: String? {
        if pendingHumanToolCallID != nil { return "Waiting for your answer" }
        return hasOpenPlanCard ? "Plan ready for you" : nil
    }
}

/// `GET /v1/agents/events`: an agent's chat as it happens. Each change to the
/// chat — a message arriving, a reply growing as it streams — goes out as the
/// transcript message it flattens to, and the agent starting or ending a turn
/// as a state event. It wakes on the chat's own changes, never on a clock.
@MainActor
enum AgentChatStream {

    static func run(_ vm: some AgentChatSource, agentID: String, after: UUID?, limit: Int,
                    writer: HTTPServer.SSEWriter) async {
        var tracker = AgentTranscript.Tracker(messages: Array(vm.messages.suffix(limit)), after: after)
        var lastWorking: Bool?
        let signal = ChangeSignal()
        writer.whenClosed { Task { @MainActor in signal.close() } }
        while !writer.isClosed && !signal.isClosed {
            if vm.isStreaming != lastWorking {
                lastWorking = vm.isStreaming
                send(["type": "state", "agent": agentID, "working": vm.isStreaming], to: writer)
            }
            for message in tracker.changes(in: Array(vm.messages.suffix(limit))) {
                send(["type": "message", "agent": agentID, "message": message], to: writer)
            }
            withObservationTracking {
                _ = vm.messages
                _ = vm.isStreaming
            } onChange: {
                Task { @MainActor in signal.fire() }
            }
            await signal.wait()
        }
    }

    static func send(_ event: [String: Any], to writer: HTTPServer.SSEWriter) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        writer.send(String(decoding: data, as: UTF8.self))
    }

    /// One waiter woken by the chat changing or the stream closing. A change
    /// that lands while nothing waits is kept, so the next wait returns at once
    /// rather than sleeping through it.
    @MainActor
    final class ChangeSignal {
        private var waiting: CheckedContinuation<Void, Never>?
        private var pending = false
        private(set) var isClosed = false

        func fire() {
            guard let waiting else { pending = true; return }
            self.waiting = nil
            waiting.resume()
        }

        func close() {
            isClosed = true
            fire()
        }

        func wait() async {
            if pending || isClosed { pending = false; return }
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
