import Foundation
import KiteloopCore

protocol SubscriptionEngineProtocol: Sendable {
    func start(agents: [Agent]) async
    func startWatching(_ agent: Agent) async
    func stopWatching(agentID: String) async
    func stop() async
}

actor SubscriptionEngine: SubscriptionEngineProtocol {
    private let eventBus: EventBusProtocol
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var triggerHandler: (@Sendable (String, KiteloopEvent) async -> Void)?

    init(eventBus: EventBusProtocol, triggerHandler: (@Sendable (String, KiteloopEvent) async -> Void)? = nil) {
        self.eventBus = eventBus
        self.triggerHandler = triggerHandler
    }

    func setTriggerHandler(_ handler: @escaping @Sendable (String, KiteloopEvent) async -> Void) {
        self.triggerHandler = handler
    }

    func start(agents: [Agent]) {
        for agent in agents where !agent.subscriptions.isEmpty {
            startWatching(agent)
        }
    }

    /// Starts watching a single agent, replacing any watch already held under
    /// its id. This is what makes an agent hired into a live project subscribed
    /// from the moment it joins: `start(agents:)` runs once, as the project
    /// opens, so every later arrival comes through here instead.
    func startWatching(_ agent: Agent) {
        let types = Set(agent.subscriptions.compactMap { KiteloopEvent.EventType(rawValue: $0) })
        guard !types.isEmpty else { return }

        let agentID = agent.id
        watchTasks.removeValue(forKey: agentID)?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            let stream = await eventBus.subscribe(agentID: agentID, types: types)
            // A cancel that lands while `subscribe` was in flight has to be
            // caught here: the loop below suspends waiting for an event rather
            // than returning, so the bus would otherwise keep handing events to
            // a subscription nobody reads.
            guard !Task.isCancelled else {
                await eventBus.unsubscribe(agentID: agentID)
                return
            }
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleEvent(event, for: agentID)
            }
        }
        watchTasks[agentID] = task
    }

    /// Stops watching an agent that has left: cancels its task and drops its
    /// subscription from the bus, so neither outlives the agent.
    func stopWatching(agentID: String) async {
        watchTasks.removeValue(forKey: agentID)?.cancel()
        await eventBus.unsubscribe(agentID: agentID)
    }

    /// Stops watching everything — what `stopWatching(agentID:)` does for one
    /// agent, done for every watched id at once. Cancelling the tasks is not
    /// enough on its own: a watch task suspends inside `for await` until its
    /// stream finishes, so without the unsubscribe the task, the engine it
    /// strongly references and the `EventBus` behind it all outlive the closed
    /// project. It all goes with them, so a later `start(agents:)` on the same
    /// engine subscribes afresh rather than carrying anything over.
    func stop() async {
        let watched = Array(watchTasks.keys)
        for (_, task) in watchTasks {
            task.cancel()
        }
        watchTasks.removeAll()
        for agentID in watched {
            await eventBus.unsubscribe(agentID: agentID)
        }
    }

    private func handleEvent(_ event: KiteloopEvent, for agentID: String) {
        Task { await triggerHandler?(agentID, event) }
    }
}
