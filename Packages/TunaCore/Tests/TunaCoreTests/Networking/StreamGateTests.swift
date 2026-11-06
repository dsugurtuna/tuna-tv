import Foundation
import XCTest
@testable import TunaCore

final class StreamGateTests: XCTestCase {
    private typealias Kit = NetTestKit

    private func ref(_ id: String, provider: ProviderID = "p1") -> StreamRef {
        StreamRef(providerID: provider, kind: .live, streamID: id)
    }

    /// Collects the tickets the gate asked the "player" to give up.
    private actor PreemptLog {
        private(set) var tickets: [StreamTicket] = []
        func add(_ ticket: StreamTicket) { tickets.append(ticket) }
    }

    func testCapReachedWithoutPreemptionThrows() async throws {
        let gate = StreamGate(clock: ManualClock())
        let first = try await gate.open(ref("1"), preempt: false)
        let error = await Kit.thrownError { try await gate.open(self.ref("2"), preempt: false) }
        XCTAssertEqual(error as? TunaError, .streamRateLimited(retryAfter: 1.5))
        let open = await gate.openTickets()
        XCTAssertEqual(open, [first])
    }

    func testPreemptionWithoutAHandlerIsRefused() async throws {
        let gate = StreamGate(clock: ManualClock())
        _ = try await gate.open(ref("1"))
        let error = await Kit.thrownError { try await gate.open(self.ref("2"), preempt: true) }
        XCTAssertEqual(error as? TunaError, .streamRateLimited(retryAfter: 1.5))
    }

    func testPreemptStopsTheOldStreamAndWaitsOutTheReleaseGrace() async throws {
        let clock = ManualClock()
        let gate = StreamGate(clock: clock)
        let log = PreemptLog()
        await gate.setPreemptHandler { ticket in
            await log.add(ticket)
            await gate.close(ticket) // the player stopped
        }

        let first = try await gate.open(ref("1"))
        clock.advance(30)
        let closedAt = clock.now()
        let second = try await gate.open(ref("2"))

        let preempted = await log.tickets
        XCTAssertEqual(preempted, [first])
        XCTAssertEqual(second.openedAt.timeIntervalSince(closedAt), 1.5, accuracy: 1e-6)
        let open = await gate.openTickets()
        XCTAssertEqual(open, [second])
    }

    func testPreemptingOpenWaitsUntilTheOldTicketIsClosed() async throws {
        let clock = ManualClock()
        let gate = StreamGate(clock: clock)
        let log = PreemptLog()
        await gate.setPreemptHandler { ticket in await log.add(ticket) } // the player stops later

        let first = try await gate.open(ref("1"))
        let pending = Task { try await gate.open(self.ref("2")) }
        let asked = await Kit.eventually { await log.tickets.count == 1 }
        XCTAssertTrue(asked)
        for _ in 0 ..< 20 { await Task.yield() }
        var open = await gate.openTickets()
        XCTAssertEqual(open, [first], "never two connections at once")

        clock.advance(10)
        let closedAt = clock.now()
        await gate.close(first)
        let second = try await pending.value
        XCTAssertGreaterThanOrEqual(second.openedAt.timeIntervalSince(closedAt), 1.5 - 1e-6)
        open = await gate.openTickets()
        XCTAssertEqual(open, [second])
    }

    func testOpensAreSpacedByMinOpenSpacing() async throws {
        let clock = ManualClock()
        let gate = StreamGate(releaseGrace: 0, minOpenSpacing: 1.5, clock: clock)
        await gate.setMaxStreams(3, for: "p1")
        let t0 = clock.now()

        let a = try await gate.open(ref("a"), preempt: false)
        let b = try await gate.open(ref("b"), preempt: false)
        let c = try await gate.open(ref("c"), preempt: false)
        XCTAssertEqual(a.openedAt, t0)
        XCTAssertEqual(b.openedAt.timeIntervalSince(a.openedAt), 1.5, accuracy: 1e-6)
        XCTAssertEqual(c.openedAt.timeIntervalSince(b.openedAt), 1.5, accuracy: 1e-6)
        let open = await gate.openTickets()
        XCTAssertEqual(open, [a, b, c])
    }

    func testReleaseGraceAfterACloseAppliesToTheNextOpen() async throws {
        let clock = ManualClock()
        let gate = StreamGate(releaseGrace: 2, minOpenSpacing: 0, clock: clock)
        let first = try await gate.open(ref("1"), preempt: false)
        clock.advance(60)
        await gate.close(first)
        let closedAt = clock.now()
        let second = try await gate.open(ref("2"), preempt: false)
        XCTAssertEqual(second.openedAt.timeIntervalSince(closedAt), 2, accuracy: 1e-6)

        // Closing twice (or an unknown ticket) changes nothing.
        await gate.close(first)
        let open = await gate.openTickets()
        XCTAssertEqual(open, [second])
    }

    func testOpensPerMinuteAreLimitedOnARollingWindow() async throws {
        let clock = ManualClock()
        let gate = StreamGate(releaseGrace: 0, minOpenSpacing: 0, maxOpensPerMinute: 3, clock: clock)
        for index in 0 ..< 3 {
            let ticket = try await gate.open(ref("\(index)"), preempt: false)
            await gate.close(ticket)
            clock.advance(10)
        }
        // Opens at t0, t0+10, t0+20; now t0+30: the oldest leaves the window at t0+60.
        let error = await Kit.thrownError { try await gate.open(self.ref("x"), preempt: false) }
        guard case .streamRateLimited(let retryAfter)? = error as? TunaError else { return XCTFail("expected streamRateLimited, got \(String(describing: error))") }
        XCTAssertEqual(retryAfter, 30, accuracy: 1e-6)

        clock.advance(29)
        let stillLimited = await Kit.thrownError { try await gate.open(self.ref("x"), preempt: false) }
        XCTAssertNotNil(stillLimited)
        clock.advance(1)
        let allowed = try await gate.open(ref("x"), preempt: false)
        XCTAssertEqual(allowed.ref, ref("x"))
    }

    func testTheRateLimitIsCheckedBeforeAnythingIsPreempted() async throws {
        let clock = ManualClock()
        let gate = StreamGate(releaseGrace: 0, minOpenSpacing: 0, maxOpensPerMinute: 1, clock: clock)
        let log = PreemptLog()
        await gate.setPreemptHandler { ticket in
            await log.add(ticket)
            await gate.close(ticket)
        }
        let playing = try await gate.open(ref("1"))
        let error = await Kit.thrownError { try await gate.open(self.ref("2")) }
        XCTAssertNotNil(error)
        let preempted = await log.tickets
        XCTAssertEqual(preempted, [], "a refused open must not stop the stream that is playing")
        let open = await gate.openTickets()
        XCTAssertEqual(open, [playing])
    }

    func testProvidersAreIndependentAndCapsAreConfigurable() async throws {
        let clock = ManualClock()
        let gate = StreamGate(clock: clock)
        let one = try await gate.open(ref("1", provider: "p1"), preempt: false)
        let other = try await gate.open(ref("1", provider: "p2"), preempt: false)
        XCTAssertEqual(one.openedAt, other.openedAt, "spacing and grace are per provider")

        await gate.setMaxStreams(2, for: "p1")
        let two = try await gate.open(ref("2", provider: "p1"), preempt: false)
        XCTAssertEqual(two.openedAt.timeIntervalSince(one.openedAt), 1.5, accuracy: 1e-6)
        let refused = await Kit.thrownError { try await gate.open(self.ref("3", provider: "p1"), preempt: false) }
        XCTAssertNotNil(refused)
        let open = await gate.openTickets()
        XCTAssertEqual(Set(open), Set([one, other, two]))
    }

    func testCancelledPendingOpenLeavesWithoutATicket() async throws {
        let clock = ManualClock()
        let gate = StreamGate(clock: clock)
        let log = PreemptLog()
        await gate.setPreemptHandler { ticket in await log.add(ticket) } // never closes by itself

        let first = try await gate.open(ref("1"))
        let pending = Task { try await gate.open(self.ref("2")) }
        let asked = await Kit.eventually { await log.tickets.count == 1 }
        XCTAssertTrue(asked)
        // A third open queues behind the pending one.
        let queued = Task { try await gate.open(self.ref("3"), preempt: false) }
        for _ in 0 ..< 20 { await Task.yield() }

        pending.cancel()
        let error = await Kit.thrownError { try await pending.value }
        XCTAssertEqual(error as? TunaError, .cancelled)
        // The queued open now gets its turn and is refused (cap reached, no preemption).
        let refused = await Kit.thrownError { try await queued.value }
        XCTAssertEqual(refused as? TunaError, .streamRateLimited(retryAfter: 1.5))

        await gate.close(first)
        let next = try await gate.open(ref("4"), preempt: false)
        let open = await gate.openTickets()
        XCTAssertEqual(open, [next])
    }
}
