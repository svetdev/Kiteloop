import Foundation
import KiteloopCore
import Darwin

final class HealthMonitor: @unchecked Sendable {
    static let shared = HealthMonitor()

    struct Hitch: Identifiable {
        let id: UInt64
        let timestamp: Date
        let durationMs: Double
    }

    struct Snapshot {
        /// `nil` when the kernel refused the reading — which is not the same as
        /// a process using no memory at all.
        let processMemoryMB: Double?
        let activeSubprocessCount: Int
        let mainThreadLatencyMs: Double
        let hitches: [Hitch]
        let agentWorking: Int
        let agentIdle: Int
        let agentCrashed: Int

        /// What the Health tab's memory gauge shows, and whether it reads as
        /// healthy. A reading nobody could take stays unknown rather than
        /// showing `0 MB` in green, the healthiest figure the gauge has.
        struct MemoryGauge: Equatable {
            enum Level { case healthy, high, unknown }

            let text: String
            let level: Level
        }

        var memoryGauge: MemoryGauge {
            guard let mb = processMemoryMB else {
                return MemoryGauge(text: "—", level: .unknown)
            }
            return MemoryGauge(text: String(format: "%.0f MB", mb),
                               level: mb > Self.memoryHighThresholdMB ? .high : .healthy)
        }

        static let memoryHighThresholdMB: Double = 500

        /// What the Health tab's Main Thread gauge shows, and whether it reads
        /// as healthy. The level is at-or-above `HealthMonitor.hitchThresholdMs`
        /// — the same comparison `/health` uses — so the two never disagree at
        /// the boundary the way a strictly-above check would.
        struct LatencyGauge: Equatable {
            enum Level { case healthy, degraded }

            let text: String
            let level: Level
        }

        var latencyGauge: LatencyGauge {
            LatencyGauge(text: String(format: "%.0f ms", mainThreadLatencyMs),
                         level: mainThreadLatencyMs >= HealthMonitor.hitchThresholdMs ? .degraded : .healthy)
        }
    }

    /// Whether a timer tick should dispatch a new latency probe: `false`
    /// while an earlier probe is still waiting on the main thread, so a
    /// stall spanning several ticks queues one probe — and yields one
    /// hitch, at its full length — instead of one per tick it lasted.
    struct ProbeScheduler {
        private(set) var outstanding = false
        private var dispatchedAt: DispatchTime?

        mutating func shouldDispatch(now: DispatchTime = .now()) -> Bool {
            guard !outstanding else { return false }
            outstanding = true
            dispatchedAt = now
            return true
        }

        mutating func probeCompleted() {
            outstanding = false
            dispatchedAt = nil
        }

        /// How long the outstanding probe has been waiting, as of `now` — `nil`
        /// once it has completed, or if none was ever dispatched.
        func outstandingElapsedMs(now: DispatchTime = .now()) -> Double? {
            guard let dispatchedAt else { return nil }
            return Double(now.uptimeNanoseconds - dispatchedAt.uptimeNanoseconds) / 1_000_000
        }
    }

    private let lock = NSLock()
    private var _latestLatencyMs: Double = 0
    private var _hitches: [Hitch] = []
    private var _nextHitchID: UInt64 = 0
    private let hitchCapacity = 100
    /// A static, not a private instance constant: `/health` reads this to decide
    /// `degraded` from the same snapshot this monitor takes, so the endpoint and
    /// the monitor cannot come to disagree about what a hitch is.
    static let hitchThresholdMs: Double = 200

    private var timer: DispatchSourceTimer?
    private var subprocessCountProvider: (() -> Int)?
    private var orchestratorProvider: (@MainActor () -> Orchestrator?)?
    private var _cachedAgentWorking = 0
    private var _cachedAgentIdle = 0
    private var _cachedAgentCrashed = 0
    private var probeScheduler = ProbeScheduler()

    private init() {}

    func start(subprocessCountProvider: @escaping () -> Int, orchestratorProvider: @escaping @MainActor () -> Orchestrator?) {
        lock.lock()
        self.subprocessCountProvider = subprocessCountProvider
        self.orchestratorProvider = orchestratorProvider
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + 1, repeating: 1.0)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        lock.lock()
        self.timer = source
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let latency = Self.reportedLatencyMs(latest: _latestLatencyMs, scheduler: probeScheduler)
        let hitches = _hitches
        let working = _cachedAgentWorking
        let idle = _cachedAgentIdle
        let crashed = _cachedAgentCrashed
        let countProvider = subprocessCountProvider
        lock.unlock()

        return Snapshot(
            processMemoryMB: Self.residentMemoryMB(),
            activeSubprocessCount: countProvider?() ?? 0,
            mainThreadLatencyMs: latency,
            hitches: hitches,
            agentWorking: working,
            agentIdle: idle,
            agentCrashed: crashed
        )
    }

    /// The latency a snapshot should report: the last probe that actually
    /// completed, or — while one is still outstanding longer than that —
    /// how long it has been waiting. An outstanding reading never survives
    /// the probe that produced it: `probeCompleted()` clears it, so once the
    /// probe returns this falls back to `latest` again.
    static func reportedLatencyMs(latest: Double, scheduler: ProbeScheduler, now: DispatchTime = .now()) -> Double {
        max(latest, scheduler.outstandingElapsedMs(now: now) ?? 0)
    }

    private func tick() {
        let sent = DispatchTime.now()
        let shouldDispatch = lock.withLock { probeScheduler.shouldDispatch(now: sent) }
        if shouldDispatch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
                self.lock.withLock { self.probeScheduler.probeCompleted() }
                self.recordLatency(elapsed)
            }
        }

        lock.lock()
        let provider = orchestratorProvider
        lock.unlock()

        if let provider {
            Task { @MainActor in
                guard let orchestrator = provider() else { return }
                let agents = orchestrator.agents
                let working = agents.filter { $0.state == .working }.count
                let crashed = agents.filter { $0.state == .crashed }.count
                let idle = agents.count - working - crashed

                self.lock.withLock {
                    self._cachedAgentWorking = working
                    self._cachedAgentIdle = idle
                    self._cachedAgentCrashed = crashed
                }
            }
        }
    }

    private func recordLatency(_ ms: Double) {
        lock.lock()
        _latestLatencyMs = ms
        if ms >= Self.hitchThresholdMs {
            _nextHitchID &+= 1
            let hitch = Hitch(id: _nextHitchID, timestamp: Date(), durationMs: ms)
            _hitches.append(hitch)
            if _hitches.count > hitchCapacity {
                _hitches.removeFirst(_hitches.count - hitchCapacity)
            }
            lock.unlock()
            kiteloopLog("Main thread hitch: \(Int(ms))ms", category: "health", level: .error)
        } else {
            lock.unlock()
        }
    }

    /// Resident size of this process, or `nil` when `task_info` refused to answer.
    static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
