import Foundation

/// The engine behind `HostLimiter`: per host key, at most `maxConcurrent` operations at once (FIFO hand-off of
/// free slots) and operation starts spaced by at least `minInterval`.
///
/// Rules are looked up by exact host key (compared case-insensitively, no suffix or wildcard matching);
/// unknown hosts use the default rule. A caller cancelled while waiting for a slot or for its start time leaves
/// with `TunaError.cancelled` without running its operation.
actor HostLimiterCore {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct HostState {
        var active = 0
        /// Earliest start time for the next operation on this host.
        var nextStart: Date?
        var waiters: [Waiter] = []
    }

    private let defaultRule: HostLimiter.Rule
    private var rules: [String: HostLimiter.Rule]
    private let clock: TunaClock
    private var hosts: [String: HostState] = [:]
    private var waiterSeed = 0

    init(defaultRule: HostLimiter.Rule, rules: [String: HostLimiter.Rule], clock: TunaClock) {
        self.defaultRule = defaultRule
        var normalized: [String: HostLimiter.Rule] = [:]
        for (host, rule) in rules { normalized[HostLimiterCore.key(host)] = rule }
        self.rules = normalized
        self.clock = clock
    }

    func run<T: Sendable>(host: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        let key = HostLimiterCore.key(host)
        try await acquireSlot(key)
        do {
            try await waitForStart(key)
            let value = try await operation()
            releaseSlot(key)
            return value
        } catch {
            releaseSlot(key)
            throw error
        }
    }

    func setRule(_ rule: HostLimiter.Rule, for host: String) {
        let key = HostLimiterCore.key(host)
        rules[key] = rule
        admitWaiters(key)
    }

    /// The rule that applies to `host`.
    func rule(for host: String) -> HostLimiter.Rule { rules[HostLimiterCore.key(host)] ?? defaultRule }

    /// Operations currently running for `host` (diagnostics and tests).
    func activeCount(for host: String) -> Int { hosts[HostLimiterCore.key(host)]?.active ?? 0 }

    /// Callers waiting for a slot on `host` (diagnostics and tests).
    func waitingCount(for host: String) -> Int { hosts[HostLimiterCore.key(host)]?.waiters.count ?? 0 }

    // MARK: - Slots

    private func acquireSlot(_ key: String) async throws {
        if Task.isCancelled { throw TunaError.cancelled }
        var state = hosts[key] ?? HostState()
        if state.waiters.isEmpty, state.active < rule(for: key).maxConcurrent {
            state.active += 1
            hosts[key] = state
            return
        }
        waiterSeed += 1
        let waiterID = waiterSeed
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: TunaError.cancelled)
                    return
                }
                hosts[key, default: HostState()].waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        }
        // Resumed by `admitWaiters`: the slot was handed over (already counted in `active`).
    }

    private func releaseSlot(_ key: String) {
        guard var state = hosts[key] else { return }
        state.active = max(0, state.active - 1)
        hosts[key] = state
        admitWaiters(key)
        pruneIfIdle(key)
    }

    private func admitWaiters(_ key: String) {
        guard var state = hosts[key] else { return }
        let limit = rule(for: key).maxConcurrent
        var admitted: [Waiter] = []
        while state.active < limit, !state.waiters.isEmpty {
            admitted.append(state.waiters.removeFirst())
            state.active += 1
        }
        hosts[key] = state
        for waiter in admitted { waiter.continuation.resume() }
    }

    private func cancelWaiter(_ waiterID: Int, key: String) {
        guard var state = hosts[key], let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.waiters.remove(at: index)
        hosts[key] = state
        waiter.continuation.resume(throwing: TunaError.cancelled)
        pruneIfIdle(key)
    }

    /// Forgets hosts with nothing running, nothing waiting and no pending spacing (bounded memory for CDNs).
    private func pruneIfIdle(_ key: String) {
        guard let state = hosts[key], state.active == 0, state.waiters.isEmpty else { return }
        if let next = state.nextStart, next > clock.now() { return }
        hosts[key] = nil
    }

    // MARK: - Spacing

    /// Reserves the next start slot for this host and waits for it.
    private func waitForStart(_ key: String) async throws {
        let rule = rule(for: key)
        let now = clock.now()
        var state = hosts[key] ?? HostState()
        var start = now
        if let next = state.nextStart, next > now {
            // At most `maxConcurrent` reservations can be outstanding; anything further out is a clock jump.
            start = min(next, now.addingTimeInterval(rule.minInterval * Double(rule.maxConcurrent)))
        }
        state.nextStart = start.addingTimeInterval(rule.minInterval)
        hosts[key] = state
        let delay = start.timeIntervalSince(now)
        if delay > 1e-6 {
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                throw TunaError.cancelled
            }
        }
        if Task.isCancelled { throw TunaError.cancelled }
    }

    static func key(_ host: String) -> String { host.tunaTrimmed.lowercased() }
}
