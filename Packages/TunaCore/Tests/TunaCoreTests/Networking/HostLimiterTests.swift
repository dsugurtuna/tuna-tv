import Foundation
import XCTest
@testable import TunaCore

final class HostLimiterTests: XCTestCase {
    private typealias Kit = NetTestKit

    func testAtMostMaxConcurrentOperationsPerHost() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 2, minInterval: 0), clock: clock)
        let probe = Kit.ConcurrencyProbe()
        let gate = Kit.Gate()

        let tasks = (0 ..< 5).map { index in
            Task { () -> Int in
                try await limiter.run(host: "image.cdn.test") {
                    await probe.begin(at: clock.now())
                    await gate.wait()
                    await probe.end()
                    return index
                }
            }
        }
        let saturated = await Kit.eventually {
            let active = await probe.active
            let waiting = await limiter.waitingCount(for: "image.cdn.test")
            return active == 2 && waiting == 3
        }
        XCTAssertTrue(saturated)
        let running = await limiter.activeCount(for: "image.cdn.test")
        XCTAssertEqual(running, 2)

        await gate.open()
        var results: [Int] = []
        for task in tasks { results.append(try await task.value) }
        XCTAssertEqual(results.sorted(), [0, 1, 2, 3, 4])
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 2)
        let idle = await limiter.activeCount(for: "image.cdn.test")
        XCTAssertEqual(idle, 0)
    }

    func testHostsDoNotShareSlots() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 1, minInterval: 0), clock: clock)
        let gate = Kit.Gate()
        let probe = Kit.ConcurrencyProbe()

        let tasks = ["a.test", "b.test", "c.test"].map { host in
            Task { try await limiter.run(host: host) { await probe.begin(at: clock.now()); await gate.wait(); await probe.end() } }
        }
        let allRunning = await Kit.eventually { await probe.active == 3 }
        XCTAssertTrue(allRunning)
        await gate.open()
        for task in tasks { try await task.value }
    }

    func testStartsAreSpacedPerHost() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter.standard(clock: clock)
        let probe = Kit.ConcurrencyProbe()

        for _ in 0 ..< 4 {
            try await limiter.run(host: "api.tvmaze.com") { await probe.begin(at: clock.now()); await probe.end() }
        }
        let starts = await probe.starts
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertEqual(gaps.count, 3)
        for gap in gaps { XCTAssertEqual(gap, 0.55, accuracy: 1e-6) }
    }

    func testConcurrentOperationsStillStartSpacedApart() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 2, minInterval: 0.5), clock: clock)
        let probe = Kit.ConcurrencyProbe()
        let gate = Kit.Gate()

        let first = Task { try await limiter.run(host: "api.themoviedb.test") { await probe.begin(at: clock.now()); await gate.wait(); await probe.end() } }
        let firstStarted = await Kit.eventually { await probe.starts.count == 1 }
        XCTAssertTrue(firstStarted)
        let second = Task { try await limiter.run(host: "api.themoviedb.test") { await probe.begin(at: clock.now()); await gate.wait(); await probe.end() } }
        let bothRunning = await Kit.eventually { await probe.active == 2 }
        XCTAssertTrue(bothRunning, "a free slot is used at once, only the start is delayed")

        let starts = await probe.starts
        XCTAssertEqual(starts[1].timeIntervalSince(starts[0]), 0.5, accuracy: 1e-6)
        await gate.open()
        try await first.value
        try await second.value
    }

    func testRulesAreLookedUpByExactHost() async {
        let limiter = HostLimiter.standard(clock: ManualClock())
        let tvmaze = await limiter.rule(for: "api.tvmaze.com")
        XCTAssertEqual(tvmaze, HostLimiter.Rule(maxConcurrent: 1, minInterval: 0.55))
        let uppercase = await limiter.rule(for: "API.TVMAZE.COM")
        XCTAssertEqual(uppercase, tvmaze)
        let tmdb = await limiter.rule(for: "api.themoviedb.org")
        XCTAssertEqual(tmdb, HostLimiter.Rule(maxConcurrent: 8, minInterval: 0.025))
        let images = await limiter.rule(for: "image.tmdb.org")
        XCTAssertEqual(images, HostLimiter.Rule(maxConcurrent: 6, minInterval: 0))
        let omdb = await limiter.rule(for: "www.omdbapi.com")
        XCTAssertEqual(omdb, HostLimiter.Rule(maxConcurrent: 2, minInterval: 0.2))
        let parentDomain = await limiter.rule(for: "tvmaze.com")
        XCTAssertEqual(parentDomain, HostLimiter.Rule(maxConcurrent: 4, minInterval: 0.05), "no suffix matching")

        await limiter.setRule(.providerImages, for: "panel.test:8080")
        let panel = await limiter.rule(for: "panel.test:8080")
        XCTAssertEqual(panel, HostLimiter.Rule(maxConcurrent: 1, minInterval: 1.0))
        let otherPort = await limiter.rule(for: "panel.test")
        XCTAssertEqual(otherPort, HostLimiter.Rule(maxConcurrent: 4, minInterval: 0.05))
    }

    func testProviderImageRuleServesOneImageAtATimeOneSecondApart() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(clock: clock)
        await limiter.setRule(.providerImages, for: "panel.test:8080")
        let probe = Kit.ConcurrencyProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    try await limiter.run(host: "panel.test:8080") {
                        await probe.begin(at: clock.now())
                        for _ in 0 ..< 5 { await Task.yield() }
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1)
        let starts = await probe.starts
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 1.0 - 1e-6)
        }
    }

    func testRaisingTheLimitAdmitsWaiters() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 1, minInterval: 0), clock: clock)
        let gate = Kit.Gate()
        let probe = Kit.ConcurrencyProbe()
        let tasks = (0 ..< 3).map { _ in
            Task { try await limiter.run(host: "h.test") { await probe.begin(at: clock.now()); await gate.wait(); await probe.end() } }
        }
        let oneRunning = await Kit.eventually { await limiter.waitingCount(for: "h.test") == 2 }
        XCTAssertTrue(oneRunning)
        await limiter.setRule(HostLimiter.Rule(maxConcurrent: 3, minInterval: 0), for: "h.test")
        let allRunning = await Kit.eventually { await probe.active == 3 }
        XCTAssertTrue(allRunning)
        await gate.open()
        for task in tasks { try await task.value }
    }

    func testCancelledWaiterLeavesWithoutRunningAndFailuresReleaseTheSlot() async throws {
        let clock = ManualClock()
        let limiter = HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 1, minInterval: 0), clock: clock)
        let gate = Kit.Gate()
        let probe = Kit.ConcurrencyProbe()

        let blocker = Task { try await limiter.run(host: "h.test") { await gate.wait(); throw TunaError.network("boom") } }
        let blocked = await Kit.eventually { await limiter.activeCount(for: "h.test") == 1 }
        XCTAssertTrue(blocked)
        let doomed = Task { try await limiter.run(host: "h.test") { await probe.begin(at: clock.now()); await probe.end() } }
        let waiting = await Kit.eventually { await limiter.waitingCount(for: "h.test") == 1 }
        XCTAssertTrue(waiting)

        doomed.cancel()
        let cancelled = await Kit.thrownError { try await doomed.value }
        XCTAssertEqual(cancelled as? TunaError, .cancelled)
        let gone = await Kit.eventually { await limiter.waitingCount(for: "h.test") == 0 }
        XCTAssertTrue(gone)

        await gate.open()
        let failure = await Kit.thrownError { try await blocker.value }
        XCTAssertEqual(failure as? TunaError, .network("boom"))

        let value = try await limiter.run(host: "h.test") { 42 }
        XCTAssertEqual(value, 42)
        let started = await probe.starts.count
        XCTAssertEqual(started, 0, "the cancelled caller never ran its operation")
        let active = await limiter.activeCount(for: "h.test")
        XCTAssertEqual(active, 0)
    }
}
