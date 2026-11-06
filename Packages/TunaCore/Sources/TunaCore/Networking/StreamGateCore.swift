import Foundation

/// The engine behind `StreamGate` (rules: ProviderSafety.swift).
///
/// Opens for one provider are handled strictly one after another (FIFO). Each open, in order:
/// 1. checks the rolling-minute budget (before anything else, so a refused open never stops the current stream);
/// 2. makes room under the provider's cap: throws `streamRateLimited` when `preempt` is false or no preempt
///    handler is registered, otherwise asks the handler to stop the oldest open stream and waits for its `close`;
/// 3. waits until `releaseGrace` has passed since the provider's last close and `minOpenSpacing` since its last
///    open (re-checked after every wait, so a close that happens meanwhile also gets its grace);
/// 4. issues the ticket.
///
/// A caller cancelled while waiting leaves with `TunaError.cancelled` and frees its turn. The preempt handler must
/// not call `open` itself (that open would wait behind the one that called the handler).
actor StreamGateCore {
    private struct TurnWaiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct ProviderState {
        var maxStreams = 1
        /// Open tickets, oldest first.
        var tickets: [StreamTicket] = []
        var lastOpenAt: Date?
        var lastCloseAt: Date?
        /// Grant times inside the rolling window.
        var recentOpens: [Date] = []
        var turnHeld = false
        var turnWaiters: [TurnWaiter] = []
    }

    /// Length of the rolling window for `maxOpensPerMinute`.
    static let window: TimeInterval = 60
    private static let timeEpsilon: TimeInterval = 1e-6

    private let releaseGrace: TimeInterval
    private let minOpenSpacing: TimeInterval
    private let maxOpensPerMinute: Int
    private let clock: TunaClock
    private var providers: [ProviderID: ProviderState] = [:]
    private var preemptHandler: (@Sendable (StreamTicket) async -> Void)?
    private var closeWaiters: [UUID: [Int: CheckedContinuation<Void, Error>]] = [:]
    private var waiterSeed = 0

    init(releaseGrace: TimeInterval, minOpenSpacing: TimeInterval, maxOpensPerMinute: Int, clock: TunaClock) {
        self.releaseGrace = max(0, releaseGrace)
        self.minOpenSpacing = max(0, minOpenSpacing)
        self.maxOpensPerMinute = max(1, maxOpensPerMinute)
        self.clock = clock
    }

    func setMaxStreams(_ count: Int, for providerID: ProviderID) {
        providers[providerID, default: ProviderState()].maxStreams = max(1, count)
    }

    func setPreemptHandler(_ handler: @escaping @Sendable (StreamTicket) async -> Void) {
        preemptHandler = handler
    }

    func open(_ ref: StreamRef, preempt: Bool) async throws -> StreamTicket {
        if Task.isCancelled { throw TunaError.cancelled }
        let providerID = ref.providerID
        try await acquireTurn(providerID)
        defer { releaseTurn(providerID) }
        if Task.isCancelled { throw TunaError.cancelled }
        try checkOpensPerMinute(providerID)
        try await makeRoom(providerID, preempt: preempt)
        try await waitForSpacing(providerID)
        return grant(ref)
    }

    func close(_ ticket: StreamTicket) {
        let providerID = ticket.ref.providerID
        guard var state = providers[providerID],
              let index = state.tickets.firstIndex(where: { $0.id == ticket.id }) else { return }
        state.tickets.remove(at: index)
        state.lastCloseAt = clock.now()
        providers[providerID] = state
        if let waiters = closeWaiters.removeValue(forKey: ticket.id) {
            for continuation in waiters.values { continuation.resume() }
        }
    }

    func openTickets() -> [StreamTicket] {
        providers.values.flatMap(\.tickets).sorted { $0.openedAt < $1.openedAt }
    }

    // MARK: - Steps

    private func checkOpensPerMinute(_ providerID: ProviderID) throws {
        let now = clock.now()
        var state = providers[providerID] ?? ProviderState()
        state.recentOpens.removeAll { now.timeIntervalSince($0) >= StreamGateCore.window }
        providers[providerID] = state
        guard state.recentOpens.count >= maxOpensPerMinute else { return }
        let oldestCounted = state.recentOpens[state.recentOpens.count - maxOpensPerMinute]
        let retryAfter = oldestCounted.addingTimeInterval(StreamGateCore.window).timeIntervalSince(now)
        throw TunaError.streamRateLimited(retryAfter: min(StreamGateCore.window, max(0, retryAfter)))
    }

    private func makeRoom(_ providerID: ProviderID, preempt: Bool) async throws {
        while true {
            let state = providers[providerID] ?? ProviderState()
            guard state.tickets.count >= state.maxStreams, let victim = state.tickets.first else { return }
            guard preempt, let handler = preemptHandler else {
                throw TunaError.streamRateLimited(retryAfter: max(releaseGrace, minOpenSpacing))
            }
            await handler(victim)
            if isOpen(victim) { try await waitForClose(victim) }
            if Task.isCancelled { throw TunaError.cancelled }
        }
    }

    private func waitForSpacing(_ providerID: ProviderID) async throws {
        let longest = max(releaseGrace, minOpenSpacing)
        while true {
            let now = clock.now()
            let state = providers[providerID] ?? ProviderState()
            var earliest = now
            if let closed = state.lastCloseAt { earliest = max(earliest, closed.addingTimeInterval(releaseGrace)) }
            if let opened = state.lastOpenAt { earliest = max(earliest, opened.addingTimeInterval(minOpenSpacing)) }
            // A clock that jumped backwards never stalls an open for longer than the longest rule.
            let wait = min(earliest.timeIntervalSince(now), longest)
            if wait <= StreamGateCore.timeEpsilon { return }
            do {
                try await clock.sleep(seconds: wait)
            } catch {
                throw TunaError.cancelled
            }
            if Task.isCancelled { throw TunaError.cancelled }
        }
    }

    private func grant(_ ref: StreamRef) -> StreamTicket {
        let now = clock.now()
        let ticket = StreamTicket(ref: ref, openedAt: now)
        var state = providers[ref.providerID] ?? ProviderState()
        state.tickets.append(ticket)
        state.lastOpenAt = now
        state.recentOpens.append(now)
        providers[ref.providerID] = state
        return ticket
    }

    private func isOpen(_ ticket: StreamTicket) -> Bool {
        providers[ticket.ref.providerID]?.tickets.contains(where: { $0.id == ticket.id }) ?? false
    }

    // MARK: - Waiting

    private func waitForClose(_ ticket: StreamTicket) async throws {
        waiterSeed += 1
        let waiterID = waiterSeed
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: TunaError.cancelled)
                } else if !isOpen(ticket) {
                    continuation.resume()
                } else {
                    closeWaiters[ticket.id, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCloseWaiter(ticket.id, waiterID: waiterID) }
        }
    }

    private func cancelCloseWaiter(_ ticketID: UUID, waiterID: Int) {
        guard let continuation = closeWaiters[ticketID]?.removeValue(forKey: waiterID) else { return }
        if closeWaiters[ticketID]?.isEmpty == true { closeWaiters[ticketID] = nil }
        continuation.resume(throwing: TunaError.cancelled)
    }

    /// Opens of one provider run one at a time, in arrival order.
    private func acquireTurn(_ providerID: ProviderID) async throws {
        var state = providers[providerID] ?? ProviderState()
        if !state.turnHeld {
            state.turnHeld = true
            providers[providerID] = state
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
                providers[providerID, default: ProviderState()].turnWaiters.append(TurnWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelTurnWaiter(providerID, waiterID: waiterID) }
        }
        // Resumed by `releaseTurn`: the turn was handed over (`turnHeld` stayed true).
    }

    private func releaseTurn(_ providerID: ProviderID) {
        guard var state = providers[providerID] else { return }
        if state.turnWaiters.isEmpty {
            state.turnHeld = false
            providers[providerID] = state
            return
        }
        let next = state.turnWaiters.removeFirst()
        providers[providerID] = state
        next.continuation.resume()
    }

    private func cancelTurnWaiter(_ providerID: ProviderID, waiterID: Int) {
        guard var state = providers[providerID],
              let index = state.turnWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.turnWaiters.remove(at: index)
        providers[providerID] = state
        waiter.continuation.resume(throwing: TunaError.cancelled)
    }
}
