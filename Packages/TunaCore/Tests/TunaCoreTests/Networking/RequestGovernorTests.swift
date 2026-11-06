import Foundation
import XCTest
@testable import TunaCore

final class RequestGovernorTests: XCTestCase {
    private typealias Kit = NetTestKit

    private func makeGovernor(_ client: Kit.FakeHTTPClient, clock: ManualClock,
                              policy: GovernorPolicy = GovernorPolicy(minInterval: 1.5, jitter: 0.5),
                              persistence: GovernorPersistence? = nil, providerID: ProviderID = "provider-1",
                              random: @escaping @Sendable () -> Double = { 0.5 }) -> RequestGovernor {
        RequestGovernor(providerID: providerID, policy: policy, client: client, clock: clock, persistence: persistence, random: random)
    }

    // MARK: - Serialization, pacing, priority, coalescing

    func testAtMostOneRequestInFlightUnderTwentyConcurrentCallers() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    let priority: RequestPriority = index.isMultiple(of: 3) ? .userInitiated : .background
                    let request = Kit.request("/player_api.php?action=get_live_streams&category_id=\(index)")
                    return try await governor.perform(request, priority: priority, purpose: "live_streams").status
                }
            }
            for try await status in group { XCTAssertEqual(status, 200) }
        }

        let calls = await client.callCount
        let maxInFlight = await client.maxInFlight
        let starts = await client.startTimes
        XCTAssertEqual(calls, 20)
        XCTAssertEqual(maxInFlight, 1)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 1.5 + 0.25 - 1e-6)
        }
        let snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 20)
        XCTAssertEqual(snapshot.inFlight, 0)
        XCTAssertEqual(snapshot.queued, 0)
    }

    func testRequestStartsAreSpacedByMinIntervalPlusJitterFromThePreviousStart() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        // First value: drawn at init (no previous request); then one draw per request start.
        let random = Kit.SequenceRandom([0.9, 0.0, 1.0, 0.5])
        let governor = makeGovernor(client, clock: clock, policy: GovernorPolicy(minInterval: 2, jitter: 1),
                                    random: { random.next() })

        for index in 0 ..< 4 {
            _ = try await governor.perform(Kit.request("/player_api.php?action=a\(index)"), purpose: "t")
        }

        let starts = await client.startTimes
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0], 2.0, accuracy: 1e-6)
        XCTAssertEqual(gaps[1], 3.0, accuracy: 1e-6)
        XCTAssertEqual(gaps[2], 2.5, accuracy: 1e-6)
        XCTAssertEqual(clock.sleeps.count, 3)
        for gap in gaps { XCTAssertGreaterThanOrEqual(gap, 2.0 - 1e-6) }
    }

    func testUserInitiatedJumpsAheadOfQueuedBackgroundRequests() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/first"), purpose: "sync") }
        let firstHeld = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(firstHeld)

        var background: [Task<HTTPResponse, Error>] = []
        for index in 1 ... 3 {
            background.append(Task { try await governor.perform(Kit.request("/bg\(index)"), priority: .background, purpose: "sync") })
            let queued = await Kit.eventually { await governor.snapshot().queued == index }
            XCTAssertTrue(queued)
        }
        let urgent = Task { try await governor.perform(Kit.request("/urgent"), priority: .userInitiated, purpose: "detail") }
        let allQueued = await Kit.eventually { await governor.snapshot().queued == 4 }
        XCTAssertTrue(allQueued)
        let inFlight = await governor.snapshot().inFlight
        XCTAssertEqual(inFlight, 1)

        await client.release()
        _ = try await first.value
        _ = try await urgent.value
        for task in background { _ = try await task.value }

        let paths = await client.paths
        XCTAssertEqual(paths, ["/first", "/urgent", "/bg1", "/bg2", "/bg3"])
    }

    func testIdenticalGetsAreCoalescedIntoOneNetworkCall() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        let listPath = "/player_api.php?action=get_vod_streams"
        let infoPath = "/player_api.php?action=get_vod_info&vod_id=7"

        await client.hold()
        let first = Task { try await governor.perform(Kit.request(listPath), purpose: "vod_streams") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)

        // Joins the request that is already on the wire.
        let joiner = Task { try await governor.perform(Kit.request(listPath), priority: .userInitiated, purpose: "vod_streams") }
        // Three callers for one queued URL share one queued request.
        let sharers = (0 ..< 3).map { _ in Task { try await governor.perform(Kit.request(infoPath), purpose: "vod_info") } }
        let allWaiting = await Kit.eventually { await governor.waitingCallers() == 5 }
        XCTAssertTrue(allWaiting)
        let queued = await governor.snapshot().queued
        XCTAssertEqual(queued, 1)

        await client.release()
        let firstBody = try await first.value.body
        let joinerBody = try await joiner.value.body
        XCTAssertEqual(firstBody, joinerBody)
        var bodies: [Data] = []
        for task in sharers { bodies.append(try await task.value.body) }
        XCTAssertEqual(Set(bodies).count, 1)
        XCTAssertEqual(bodies.first, Data((Kit.host + infoPath).utf8))

        let urls = await client.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls, [Kit.host + listPath, Kit.host + infoPath])
        let snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 2)
        XCTAssertEqual(snapshot.recent.count, 2)
    }

    func testPostsAndDifferentHeadersAreNotCoalesced() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/first"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let posts = (0 ..< 2).map { _ in Task { try await governor.perform(Kit.request("/form", method: "POST"), purpose: "t") } }
        let otherHeaders = Task { try await governor.perform(Kit.request("/first", headers: ["Range": "bytes=0-9"]), purpose: "t") }
        let queued = await Kit.eventually { await governor.snapshot().queued == 3 }
        XCTAssertTrue(queued)

        await client.release()
        _ = try await first.value
        _ = try await otherHeaders.value
        for task in posts { _ = try await task.value }
        let calls = await client.callCount
        XCTAssertEqual(calls, 4)
    }

    func testCancelledQueuedCallerIsRemovedFromTheQueueAndNeverSent() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/first"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let doomed = Task { try await governor.perform(Kit.request("/doomed"), purpose: "t") }
        let queued = await Kit.eventually { await governor.snapshot().queued == 1 }
        XCTAssertTrue(queued)

        doomed.cancel()
        let error = await Kit.thrownError { try await doomed.value }
        XCTAssertEqual(error as? TunaError, .cancelled)
        let emptied = await Kit.eventually { await governor.snapshot().queued == 0 }
        XCTAssertTrue(emptied)

        await client.release()
        _ = try await first.value
        let followUp = try await governor.perform(Kit.request("/after"), purpose: "t")
        XCTAssertEqual(followUp.status, 200)
        let paths = await client.paths
        XCTAssertEqual(paths, ["/first", "/after"])
    }

    func testCancellingOneCoalescedCallerKeepsTheRequestForTheOthers() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/first"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let keeper = Task { try await governor.perform(Kit.request("/shared"), purpose: "t") }
        let leaver = Task { try await governor.perform(Kit.request("/shared"), purpose: "t") }
        let joined = await Kit.eventually { await governor.waitingCallers() == 3 }
        XCTAssertTrue(joined)

        leaver.cancel()
        let error = await Kit.thrownError { try await leaver.value }
        XCTAssertEqual(error as? TunaError, .cancelled)
        let left = await Kit.eventually { await governor.waitingCallers() == 2 }
        XCTAssertTrue(left)
        let queued = await governor.snapshot().queued
        XCTAssertEqual(queued, 1)

        await client.release()
        _ = try await first.value
        let shared = try await keeper.value
        XCTAssertEqual(shared.status, 200)
        let paths = await client.paths
        XCTAssertEqual(paths, ["/first", "/shared"])
    }

    // MARK: - Breaker

    func testForbiddenBlocksTheAccountWithoutAnyFurtherNetworkCalls() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(403))

        let error = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php"), priority: .userInitiated, purpose: "account") }
        XCTAssertTrue(Kit.isUnauthorized(error))
        var snapshot = await governor.snapshot()
        guard case .authBlocked(let reason) = snapshot.breaker else { return XCTFail("expected authBlocked, got \(snapshot.breaker)") }
        XCTAssertTrue(reason.contains("403"))
        XCTAssertFalse(snapshot.isHealthy)
        XCTAssertNil(snapshot.nextAllowedAt)

        for priority in [RequestPriority.background, .userInitiated] {
            let again = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php?action=get_live_categories"), priority: priority, purpose: "t") }
            XCTAssertTrue(Kit.isUnauthorized(again))
        }
        clock.advance(3 * 24 * 3600) // time alone never unblocks
        let later = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php"), purpose: "t") }
        XCTAssertTrue(Kit.isUnauthorized(later))
        var calls = await client.callCount
        XCTAssertEqual(calls, 1)

        await governor.resetBreaker()
        snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)
        let response = try await governor.perform(Kit.request("/player_api.php"), priority: .userInitiated, purpose: "account")
        XCTAssertEqual(response.status, 200)
        calls = await client.callCount
        XCTAssertEqual(calls, 2)
    }

    func testQueuedRequestsFailWithoutNetworkWhenTheAccountGetsBlocked() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(401))

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/a"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let others = ["/b", "/c"].map { path in Task { try await governor.perform(Kit.request(path), purpose: "t") } }
        let queued = await Kit.eventually { await governor.snapshot().queued == 2 }
        XCTAssertTrue(queued)

        await client.release()
        let firstError = await Kit.thrownError { try await first.value }
        XCTAssertTrue(Kit.isUnauthorized(firstError))
        for task in others {
            let error = await Kit.thrownError { try await task.value }
            XCTAssertTrue(Kit.isUnauthorized(error))
        }
        let calls = await client.callCount
        XCTAssertEqual(calls, 1)
    }

    func testRateLimitThenCloudflareErrorPausesForFiveThenThirtyMinutes() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429), .status(520), .status(429), .status(458))

        let t0 = clock.now()
        let first = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php?action=get_vod_streams"), purpose: "vod_streams") }
        XCTAssertEqual(Kit.pausedUntil(first)?.timeIntervalSince(t0) ?? -1, 300, accuracy: 1e-6)
        var snapshot = await governor.snapshot()
        guard case .open(let until, let reason, let trips) = snapshot.breaker else { return XCTFail("expected open, got \(snapshot.breaker)") }
        XCTAssertEqual(until.timeIntervalSince(t0), 300, accuracy: 1e-6)
        XCTAssertEqual(trips, 1)
        XCTAssertTrue(reason.contains("429"))
        XCTAssertEqual(snapshot.nextAllowedAt, until)

        // While open: refused immediately, without touching the client or sleeping.
        let sleepsBefore = clock.sleeps.count
        for priority in [RequestPriority.background, .userInitiated] {
            let refused = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php"), priority: priority, purpose: "t") }
            XCTAssertEqual(Kit.pausedUntil(refused), until)
        }
        clock.advance(299)
        let stillRefused = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php"), purpose: "t") }
        XCTAssertNotNil(Kit.pausedUntil(stillRefused))
        var calls = await client.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(clock.sleeps.count, sleepsBefore)

        clock.advance(1)
        let t1 = clock.now()
        let second = await Kit.thrownError { try await governor.perform(Kit.request("/player_api.php?action=get_series"), purpose: "series") }
        XCTAssertEqual(Kit.pausedUntil(second)?.timeIntervalSince(t1) ?? -1, 1800, accuracy: 1e-6)
        snapshot = await governor.snapshot()
        guard case .open(_, let reason2, let trips2) = snapshot.breaker else { return XCTFail("expected open") }
        XCTAssertEqual(trips2, 2)
        XCTAssertTrue(reason2.contains("520"))

        clock.advance(1800)
        let t2 = clock.now()
        let third = await Kit.thrownError { try await governor.perform(Kit.request("/x"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(third)?.timeIntervalSince(t2) ?? -1, 7200, accuracy: 1e-6)

        clock.advance(7200)
        let t3 = clock.now()
        let fourth = await Kit.thrownError { try await governor.perform(Kit.request("/y"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(fourth)?.timeIntervalSince(t3) ?? -1, 7200, accuracy: 1e-6, "schedule caps at its last step")
        snapshot = await governor.snapshot()
        guard case .open(_, _, let trips4) = snapshot.breaker else { return XCTFail("expected open") }
        XCTAssertEqual(trips4, 4)
        calls = await client.callCount
        XCTAssertEqual(calls, 4)
    }

    func testRetryAfterIsHonouredWhenLongerThanTheSchedule() async throws {
        let clock = ManualClock()
        let t0 = clock.now()

        let longClient = Kit.FakeHTTPClient(clock: clock)
        await longClient.enqueue(.status(429, headers: ["retry-after": "900"]))
        let long = await Kit.thrownError { try await self.makeGovernor(longClient, clock: clock).perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(long)?.timeIntervalSince(t0) ?? -1, 900, accuracy: 1e-6)

        let shortClient = Kit.FakeHTTPClient(clock: clock)
        await shortClient.enqueue(.status(429, headers: ["Retry-After": "10"]))
        let short = await Kit.thrownError { try await self.makeGovernor(shortClient, clock: clock).perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(short)?.timeIntervalSince(t0) ?? -1, 300, accuracy: 1e-6)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let dateClient = Kit.FakeHTTPClient(clock: clock)
        await dateClient.enqueue(.status(503, headers: ["Retry-After": formatter.string(from: t0.addingTimeInterval(3600))]))
        let dated = await Kit.thrownError { try await self.makeGovernor(dateClient, clock: clock).perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(dated)?.timeIntervalSince(t0) ?? -1, 3600, accuracy: 1e-6)
    }

    func testRetryAfterOnAServerErrorOpensTheBreakerImmediately() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(503, headers: ["Retry-After": "120"]))

        let t0 = clock.now()
        let error = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(error)?.timeIntervalSince(t0) ?? -1, 300, accuracy: 1e-6)
    }

    func testTwoConsecutiveServerErrorsTripTheBreaker() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(500), .status(502))

        let first = try await governor.perform(Kit.request("/a"), purpose: "t")
        XCTAssertEqual(first.status, 500, "a single 5xx is returned to the caller")
        var snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)

        let second = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        let starts = await client.startTimes
        let secondStart = try XCTUnwrap(starts.last)
        XCTAssertEqual(secondStart.timeIntervalSince(clock.now()), 0, accuracy: 1e-6, "the pause starts at the response")
        XCTAssertEqual(Kit.pausedUntil(second)?.timeIntervalSince(secondStart) ?? -1, 300, accuracy: 1e-6)
        snapshot = await governor.snapshot()
        XCTAssertFalse(snapshot.isHealthy)
        XCTAssertEqual(snapshot.recent.map(\.status), [500, 502])
        let calls = await client.callCount
        XCTAssertEqual(calls, 2)
    }

    func testAnAnswerBetweenServerErrorsResetsTheStreak() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(500), .status(200), .status(500), .status(404), .status(503))

        let statuses = try await [
            governor.perform(Kit.request("/a"), purpose: "t").status,
            governor.perform(Kit.request("/b"), purpose: "t").status,
            governor.perform(Kit.request("/c"), purpose: "t").status,
            governor.perform(Kit.request("/d"), purpose: "t").status,
            governor.perform(Kit.request("/e"), purpose: "t").status,
        ]
        XCTAssertEqual(statuses, [500, 200, 500, 404, 503])
        let snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)
    }

    func testConsecutiveNetworkErrorsTripTheBreaker() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.failure(.network("timed out")), .failure(.network("connection reset")))

        let first = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(first as? TunaError, .network("timed out"))
        let second = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        XCTAssertNotNil(Kit.pausedUntil(second))
        let snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.recent.map(\.outcome).first, "network error")
        let calls = await client.callCount
        XCTAssertEqual(calls, 2)
    }

    func testCancellationErrorsFromTheClientDoNotCountAsFailures() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.failure(.cancelled), .failure(.cancelled), .failure(.cancelled))

        for path in ["/a", "/b", "/c"] {
            let error = await Kit.thrownError { try await governor.perform(Kit.request(path), purpose: "t") }
            XCTAssertEqual(error as? TunaError, .cancelled)
        }
        let snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)
    }

    func testTheFirstFailureAfterAPauseReopensTheBreaker() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(500), .status(500), .status(503))

        _ = try await governor.perform(Kit.request("/a"), purpose: "t")
        _ = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        clock.advance(300)
        let probeStart = clock.now()
        let probe = await Kit.thrownError { try await governor.perform(Kit.request("/c"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(probe)?.timeIntervalSince(probeStart) ?? -1, 1800, accuracy: 1e-6)
    }

    func testASuccessfulProbeEndsProbation() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429), .status(200), .status(500))

        _ = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        clock.advance(300)
        let ok = try await governor.perform(Kit.request("/b"), purpose: "t")
        XCTAssertEqual(ok.status, 200)
        let single = try await governor.perform(Kit.request("/c"), purpose: "t")
        XCTAssertEqual(single.status, 500)
        let snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)
    }

    func testResetBreakerClosesButKeepsTheTripCountForEscalation() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429), .status(429))

        _ = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        await governor.resetBreaker()
        var snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isHealthy)

        clock.advance(2) // spacing only
        let t1 = clock.now()
        let second = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(second)?.timeIntervalSince(t1) ?? -1, 1800, accuracy: 1e-6)
        snapshot = await governor.snapshot()
        guard case .open(_, _, let trips) = snapshot.breaker else { return XCTFail("expected open") }
        XCTAssertEqual(trips, 2)
    }

    func testEscalationStartsOverAfterADayWithoutTrips() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429), .status(429))

        _ = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        clock.advance(24 * 3600 + 1)
        let t1 = clock.now()
        let later = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(later)?.timeIntervalSince(t1) ?? -1, 300, accuracy: 1e-6)
        let snapshot = await governor.snapshot()
        guard case .open(_, _, let trips) = snapshot.breaker else { return XCTFail("expected open") }
        XCTAssertEqual(trips, 1)
    }

    func testNoAutomaticRetries() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock, policy: GovernorPolicy(failuresBeforeTrip: 5))
        await client.enqueue(.status(500), .failure(.network("offline")), .status(404))

        let serverError = try await governor.perform(Kit.request("/a"), purpose: "t")
        XCTAssertEqual(serverError.status, 500)
        var calls = await client.callCount
        XCTAssertEqual(calls, 1)
        _ = await Kit.thrownError { try await governor.perform(Kit.request("/b"), purpose: "t") }
        calls = await client.callCount
        XCTAssertEqual(calls, 2)
        let missing = try await governor.perform(Kit.request("/c"), purpose: "t")
        XCTAssertEqual(missing.status, 404)
        calls = await client.callCount
        XCTAssertEqual(calls, 3)
    }

    func testTripBreakerFromTheCaller() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        let t0 = clock.now()

        await governor.tripBreaker(reason: "get_vod_streams returned an empty list twice")
        let paused = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(paused)?.timeIntervalSince(t0) ?? -1, 300, accuracy: 1e-6)
        await governor.tripBreaker(reason: "again")
        let stillSame = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(Kit.pausedUntil(stillSame), Kit.pausedUntil(paused), "a running pause is not extended")

        await governor.tripBreaker(reason: "Account status: Banned", authBlocked: true)
        let blocked = await Kit.thrownError { try await governor.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertEqual(blocked as? TunaError, .unauthorized("Account status: Banned"))
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testAnExternalTripDuringAFlightDoesNotEscalateTwice() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429))

        await client.hold()
        let inFlight = Task { try await governor.perform(Kit.request("/a"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let t0 = clock.now()
        await governor.tripBreaker(reason: "empty lists")
        await client.release()

        let error = await Kit.thrownError { try await inFlight.value }
        XCTAssertEqual(Kit.pausedUntil(error)?.timeIntervalSince(t0) ?? -1, 300, accuracy: 1e-6)
        let snapshot = await governor.snapshot()
        guard case .open(_, let reason, let trips) = snapshot.breaker else { return XCTFail("expected open") }
        XCTAssertEqual(reason, "empty lists")
        XCTAssertEqual(trips, 1)
    }

    func testAnAccountBlockIsNeverDowngradedToAPause() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(429))

        await client.hold()
        let inFlight = Task { try await governor.perform(Kit.request("/a"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        await governor.tripBreaker(reason: "Account status: Banned", authBlocked: true)
        await client.release()

        let error = await Kit.thrownError { try await inFlight.value }
        XCTAssertEqual(error as? TunaError, .unauthorized("Account status: Banned"))
        let snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.breaker, .authBlocked(reason: "Account status: Banned"))
    }

    // MARK: - Budget

    func testDailyBudgetRefusesBackgroundButNotUserInitiatedRequests() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock, policy: GovernorPolicy(dailySoftBudget: 2))

        _ = try await governor.perform(Kit.request("/a"), purpose: "t")
        _ = try await governor.perform(Kit.request("/b"), purpose: "t")
        let refused = await Kit.thrownError { try await governor.perform(Kit.request("/c"), priority: .background, purpose: "t") }
        XCTAssertEqual(refused as? TunaError, .budgetExhausted)
        var calls = await client.callCount
        XCTAssertEqual(calls, 2)

        let user = try await governor.perform(Kit.request("/d"), priority: .userInitiated, purpose: "detail")
        XCTAssertEqual(user.status, 200)
        var snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 3)
        XCTAssertEqual(snapshot.dailySoftBudget, 2)

        clock.advance(24 * 3600) // next local day
        snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 0)
        _ = try await governor.perform(Kit.request("/e"), priority: .background, purpose: "t")
        snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 1)
        calls = await client.callCount
        XCTAssertEqual(calls, 4)
    }

    func testQueuedBackgroundRequestsAreRefusedOnceTheBudgetRunsOut() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock, policy: GovernorPolicy(dailySoftBudget: 2))

        await client.hold()
        let first = Task { try await governor.perform(Kit.request("/a"), purpose: "t") }
        let held = await Kit.eventually { await client.heldCount == 1 }
        XCTAssertTrue(held)
        let queuedTasks = ["/b", "/c", "/d"].map { path in Task { try await governor.perform(Kit.request(path), purpose: "t") } }
        // A background caller for the in-flight URL costs nothing and may join even past the budget.
        let joiner = Task { try await governor.perform(Kit.request("/a"), purpose: "t") }
        let waiting = await Kit.eventually { await governor.waitingCallers() == 5 }
        XCTAssertTrue(waiting)

        await client.release()
        _ = try await first.value
        _ = try await joiner.value
        var outcomes: [String] = []
        for task in queuedTasks {
            let error = await Kit.thrownError { try await task.value }
            outcomes.append(error == nil ? "ok" : (error as? TunaError == .budgetExhausted ? "budget" : "other"))
        }
        // The three tasks may have reached the queue in any order; exactly one fits in the budget.
        XCTAssertEqual(outcomes.sorted(), ["budget", "budget", "ok"])
        let calls = await client.callCount
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Persistence

    func testAnOpenBreakerSurvivesARelaunch() async throws {
        let files = FileStore.temporary()
        defer { try? FileManager.default.removeItem(at: files.baseURL) }
        let store = AppStateStore(files: files)
        let clock = ManualClock()
        let t0 = clock.now()

        let clientA = Kit.FakeHTTPClient(clock: clock)
        await clientA.enqueue(.status(429))
        let governorA = makeGovernor(clientA, clock: clock, persistence: store, providerID: "prov-1")
        _ = await Kit.thrownError { try await governorA.perform(Kit.request("/player_api.php"), purpose: "account") }
        XCTAssertTrue(files.exists("governor/prov-1.json"))

        // "Relaunch": a new governor with the same persistence and a client that must stay untouched.
        clock.advance(60)
        let clientB = Kit.FakeHTTPClient(clock: clock)
        let governorB = makeGovernor(clientB, clock: clock, persistence: store, providerID: "prov-1")
        let snapshot = await governorB.snapshot()
        guard case .open(let until, let reason, let trips) = snapshot.breaker else { return XCTFail("expected open, got \(snapshot.breaker)") }
        XCTAssertEqual(until.timeIntervalSince(t0), 300, accuracy: 0.001)
        XCTAssertTrue(reason.contains("429"))
        XCTAssertEqual(trips, 1)
        XCTAssertEqual(snapshot.requestsToday, 1)
        XCTAssertEqual(snapshot.lastRequestAt?.timeIntervalSince(t0) ?? -1, 0, accuracy: 0.001)

        let refused = await Kit.thrownError { try await governorB.perform(Kit.request("/player_api.php"), priority: .userInitiated, purpose: "account") }
        XCTAssertNotNil(Kit.pausedUntil(refused))
        var callsB = await clientB.callCount
        XCTAssertEqual(callsB, 0)

        // The escalation survives the relaunch too.
        clock.advance(240)
        await clientB.enqueue(.status(520))
        let t1 = clock.now()
        let second = await Kit.thrownError { try await governorB.perform(Kit.request("/player_api.php"), purpose: "account") }
        XCTAssertEqual(Kit.pausedUntil(second)?.timeIntervalSince(t1) ?? -1, 1800, accuracy: 0.001)
        callsB = await clientB.callCount
        XCTAssertEqual(callsB, 1)
    }

    func testAnAuthBlockSurvivesARelaunch() async throws {
        let persistence = Kit.MemoryPersistence()
        let clock = ManualClock()
        let clientA = Kit.FakeHTTPClient(clock: clock)
        await clientA.enqueue(.status(403))
        _ = await Kit.thrownError { try await self.makeGovernor(clientA, clock: clock, persistence: persistence).perform(Kit.request("/a"), purpose: "t") }

        let clientB = Kit.FakeHTTPClient(clock: clock)
        let governorB = makeGovernor(clientB, clock: clock, persistence: persistence)
        let error = await Kit.thrownError { try await governorB.perform(Kit.request("/a"), purpose: "t") }
        XCTAssertTrue(Kit.isUnauthorized(error))
        let calls = await clientB.callCount
        XCTAssertEqual(calls, 0)
    }

    func testSpacingAndDayCounterSurviveARelaunch() async throws {
        let persistence = Kit.MemoryPersistence()
        let clock = ManualClock()
        let t0 = clock.now()
        let clientA = Kit.FakeHTTPClient(clock: clock)
        let governorA = makeGovernor(clientA, clock: clock, persistence: persistence)
        _ = try await governorA.perform(Kit.request("/a"), purpose: "t")
        _ = try await governorA.perform(Kit.request("/b"), purpose: "t")
        let lastStart = await clientA.startTimes.last!
        XCTAssertGreaterThanOrEqual(persistence.saveCount, 2)
        let saved = persistence.load(providerID: "provider-1")
        XCTAssertEqual(saved?.requestsToday, 2)
        XCTAssertEqual(saved?.lastRequestAt, lastStart)
        XCTAssertEqual(saved?.dayStamp, GovernorCore.dayStamp(for: t0, timeZone: nil))

        clock.advance(0.25)
        let clientB = Kit.FakeHTTPClient(clock: clock)
        let governorB = makeGovernor(clientB, clock: clock, persistence: persistence)
        _ = try await governorB.perform(Kit.request("/c"), purpose: "t")
        let firstStartB = await clientB.startTimes.first!
        XCTAssertEqual(firstStartB.timeIntervalSince(lastStart), 1.75, accuracy: 1e-6)
        let snapshot = await governorB.snapshot()
        XCTAssertEqual(snapshot.requestsToday, 3)
    }

    // MARK: - Snapshot and log

    func testSnapshotReportsLastRequestAndNextAllowedStart() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        var snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.providerID, "provider-1")
        XCTAssertNil(snapshot.lastRequestAt)
        XCTAssertNil(snapshot.nextAllowedAt)

        let t0 = clock.now()
        _ = try await governor.perform(Kit.request("/a"), purpose: "t")
        snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.lastRequestAt, t0)
        XCTAssertEqual(snapshot.nextAllowedAt?.timeIntervalSince(t0) ?? -1, 1.75, accuracy: 1e-6)

        clock.advance(2)
        snapshot = await governor.snapshot()
        XCTAssertNil(snapshot.nextAllowedAt)
    }

    func testRequestLogKeepsRedactedSummariesOfTheLast200Requests() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock)
        await client.enqueue(.status(200), .status(200), .status(404))

        _ = try await governor.perform(Kit.request("/player_api.php?username=alice&password=s3cret&action=get_vod_info&vod_id=12"),
                                       priority: .userInitiated, purpose: "vod_info")
        _ = try await governor.perform(Kit.request("/alice/s3cret/xmltv.php?username=alice&password=s3cret"), purpose: "xmltv")
        let missing = try await governor.perform(Kit.request("/get.php?username=alice&password=s3cret&type=m3u_plus"), purpose: "playlist")
        XCTAssertEqual(missing.status, 404)

        var recent = await governor.snapshot().recent
        XCTAssertEqual(recent.map(\.summary), ["/player_api.php?action=get_vod_info", "/•••/•••/xmltv.php", "/get.php"])
        XCTAssertEqual(recent.map(\.purpose), ["vod_info", "xmltv", "playlist"])
        XCTAssertEqual(recent.map(\.status), [200, 200, 404])
        XCTAssertEqual(recent.map(\.outcome), ["ok", "ok", "HTTP 404"])
        XCTAssertEqual(recent.map(\.priority), [.userInitiated, .background, .background])
        for entry in recent {
            XCTAssertFalse(entry.summary.contains("alice"))
            XCTAssertFalse(entry.summary.contains("s3cret"))
        }

        for index in 0 ..< 205 {
            _ = try await governor.perform(Kit.request("/player_api.php?action=a\(index)"), purpose: "t")
        }
        recent = await governor.snapshot().recent
        XCTAssertEqual(recent.count, 200)
        XCTAssertEqual(recent.first?.id, 9)
        XCTAssertEqual(recent.last?.id, 208)
        XCTAssertEqual(recent.last?.summary, "/player_api.php?action=a204")
        XCTAssertEqual(Set(recent.map(\.id)).count, 200)
    }

    func testUpdatePolicyChangesTheSpacing() async throws {
        let clock = ManualClock()
        let client = Kit.FakeHTTPClient(clock: clock)
        let governor = makeGovernor(client, clock: clock, policy: GovernorPolicy(minInterval: 1, jitter: 0))
        _ = try await governor.perform(Kit.request("/a"), purpose: "t")
        await governor.updatePolicy(GovernorPolicy.forPacing(.gentle))
        let policy = await governor.policy
        XCTAssertEqual(policy.minInterval, 3)
        XCTAssertEqual(policy.maxInFlight, 1)
        _ = try await governor.perform(Kit.request("/b"), purpose: "t")
        let starts = await client.startTimes
        // gentle: 3 s + 0.5 * 1 s of jitter
        XCTAssertEqual(starts[1].timeIntervalSince(starts[0]), 3.5, accuracy: 1e-6)
    }

    func testDayStampUsesTheLocalCalendarDay() {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        XCTAssertEqual(GovernorCore.dayStamp(for: date, timeZone: TimeZone(identifier: "UTC")), "2027-01-15")
        XCTAssertEqual(GovernorCore.dayStamp(for: date, timeZone: TimeZone(identifier: "Pacific/Kiritimati")), "2027-01-15")
        XCTAssertEqual(GovernorCore.dayStamp(for: date, timeZone: TimeZone(identifier: "America/Los_Angeles")), "2027-01-15")
        XCTAssertEqual(GovernorCore.dayStamp(for: date.addingTimeInterval(-9 * 3600), timeZone: TimeZone(identifier: "UTC")), "2027-01-14")
    }
}
