import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The engine behind `RequestGovernor` (contract and rules: ProviderSafety.swift). One instance per provider.
///
/// How it works:
/// - Callers never send a request themselves. `perform` parks the caller on a continuation and one pump task works
///   through the queue, so at most one request is ever on the wire, and a cancelled caller can never tear down a
///   request that other (coalesced) callers are waiting for. A request that already went out is allowed to finish:
///   cancelling it would not lighten the provider's load, and a caller who comes back for the same URL can still
///   join it.
/// - Before every start the pump re-checks the breaker and the budget and waits out the spacing, so a request that
///   was queued before the breaker opened never reaches the network.
/// - When the breaker opens (or the account is blocked) everything still queued fails at once.
/// - Breaker, trip count, day counter and the last request start are written through `persistence` on every change.
///
/// Thrown errors: `TunaError.paused` (breaker open; also for the response that opened it), `.unauthorized`
/// (401/403; the account stays blocked until `resetBreaker()`), `.budgetExhausted` (background only),
/// `.cancelled` (the caller was cancelled), and transport errors as `TunaError.network`. Any other HTTP status is
/// returned as a normal `HTTPResponse` for the caller to judge.
actor GovernorCore {
    /// Identical GETs share one request: same URL and same headers.
    private struct CoalesceKey: Hashable {
        let url: String
        let headers: [String: String]
    }

    /// One request to make plus everyone waiting for its answer. Only touched on the actor.
    private final class Job {
        let request: HTTPRequest
        let key: CoalesceKey?
        let purpose: String
        var priority: RequestPriority
        var waiters: [Int: CheckedContinuation<HTTPResponse, Error>] = [:]

        init(request: HTTPRequest, key: CoalesceKey?, purpose: String, priority: RequestPriority) {
            self.request = request
            self.key = key
            self.purpose = purpose
            self.priority = priority
        }
    }

    /// What a finished request turns into.
    private struct Verdict {
        var delivery: Result<HTTPResponse, Error>
        var status: Int?
        var outcome: String
        /// Set when the request opened the breaker / blocked the account: everything still queued fails with it.
        var queueError: TunaError?
    }

    /// Entries kept in the request log.
    static let logCapacity = 200
    /// Upper bound for a server-requested pause (guards against absurd Retry-After values).
    static let maxRetryAfter: TimeInterval = 7 * 24 * 3600
    /// After this long without a trip, escalation starts again from `breakerSchedule[0]`.
    static let tripCountDecay: TimeInterval = 24 * 3600
    private static let timeEpsilon: TimeInterval = 1e-6

    let providerID: ProviderID
    private var policy: GovernorPolicy
    private let client: HTTPClient
    private let clock: TunaClock
    private let persistence: GovernorPersistence?
    private let random: @Sendable () -> Double
    private let timeZone: TimeZone?

    // Persisted state.
    private var breaker: BreakerState
    private var tripCount: Int
    private var lastTripAt: Date?
    private var dayStamp: String
    private var requestsToday: Int
    private var lastRequestAt: Date?

    // Runtime state.
    /// 5xx responses / network errors in a row.
    private var consecutiveFailures = 0
    /// Half-open: the first request after a pause (or a manual reset) is a probe; one 5xx / network error re-opens.
    private var probation = false
    /// The jitter fraction (0...1) of the gap that follows `lastRequestAt`.
    private var gapFraction: Double
    private var queue: [Job] = []
    private var inFlight: Job?
    private var pumping = false
    private var waiterSeed = 0
    private var waiterJobs: [Int: Job] = [:]
    private var log: [RequestLogEntry] = []
    private var logSeed = 0

    /// - Parameter timeZone: zone that defines the "local day" of the request counter (nil = the system zone).
    init(providerID: ProviderID, policy: GovernorPolicy, client: HTTPClient, clock: TunaClock,
         persistence: GovernorPersistence?, random: @escaping @Sendable () -> Double, timeZone: TimeZone? = nil) {
        self.providerID = providerID
        self.policy = policy
        self.client = client
        self.clock = clock
        self.persistence = persistence
        self.random = random
        self.timeZone = timeZone

        let now = clock.now()
        let today = GovernorCore.dayStamp(for: now, timeZone: timeZone)
        let restored = persistence?.load(providerID: providerID)
        let restoredTrips = max(0, restored?.tripCount ?? 0)
        breaker = restored?.breaker ?? .closed
        tripCount = restoredTrips
        // A state saved before `lastTripAt` existed: start the decay window now (conservative).
        lastTripAt = restored?.lastTripAt ?? (restoredTrips > 0 ? now : nil)
        dayStamp = today
        requestsToday = restored.map { $0.dayStamp == today ? max(0, $0.requestsToday) : 0 } ?? 0
        lastRequestAt = restored?.lastRequestAt
        gapFraction = GovernorCore.unit(random())
        if case .open? = restored?.breaker { probation = true }
    }

    // MARK: - API used by RequestGovernor

    func perform(_ request: HTTPRequest, priority: RequestPriority, purpose: String) async throws -> HTTPResponse {
        if Task.isCancelled { throw TunaError.cancelled }
        let now = clock.now()
        rollDay(now)
        if let error = breakerError(now) { throw error }
        waiterSeed += 1
        let waiterID = waiterSeed
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                enqueue(request, priority: priority, purpose: purpose, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func snapshot() -> GovernorSnapshot {
        let now = clock.now()
        rollDay(now)
        _ = breakerError(now) // closes an expired breaker
        return GovernorSnapshot(providerID: providerID, breaker: breaker, inFlight: inFlight == nil ? 0 : 1,
                                queued: queue.count, requestsToday: requestsToday, dailySoftBudget: policy.dailySoftBudget,
                                lastRequestAt: lastRequestAt, nextAllowedAt: nextAllowedAt(now), recent: log)
    }

    /// Closes the breaker; the trip count is kept, and the next request is a probe (one failure re-opens).
    func resetBreaker() {
        consecutiveFailures = 0
        if case .closed = breaker { return }
        breaker = .closed
        probation = true
        persist()
    }

    func updatePolicy(_ policy: GovernorPolicy) {
        self.policy = policy
    }

    /// Callers waiting for a response (queued or sharing the in-flight request).
    func waitingCallers() -> Int { waiterJobs.count }

    /// Opens the breaker (or blocks the account) for a problem only the caller can see, e.g. `auth: 0` or a
    /// "Banned" status inside a 200 response. A pause that is already running is not extended.
    func tripBreaker(reason: String, authBlocked: Bool) {
        if authBlocked {
            block(reason: reason)
            failQueued(with: .unauthorized(reason))
            return
        }
        let now = clock.now()
        guard breakerError(now) == nil else { return }
        failQueued(with: trip(at: now, reason: reason, retryAfter: nil))
    }

    // MARK: - Queue

    private func enqueue(_ request: HTTPRequest, priority: RequestPriority, purpose: String, waiterID: Int,
                         continuation: CheckedContinuation<HTTPResponse, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: TunaError.cancelled)
            return
        }
        let key = GovernorCore.coalesceKey(for: request)
        if let key, let job = inFlight, job.key == key {
            attach(waiterID, continuation, to: job)
            return
        }
        if let key, let job = queue.first(where: { $0.key == key }) {
            if priority > job.priority { job.priority = priority }
            attach(waiterID, continuation, to: job)
            return
        }
        if priority == .background, requestsToday >= policy.dailySoftBudget {
            continuation.resume(throwing: TunaError.budgetExhausted)
            return
        }
        let job = Job(request: request, key: key, purpose: purpose, priority: priority)
        attach(waiterID, continuation, to: job)
        queue.append(job)
        startPumpIfNeeded()
    }

    private func attach(_ waiterID: Int, _ continuation: CheckedContinuation<HTTPResponse, Error>, to job: Job) {
        job.waiters[waiterID] = continuation
        waiterJobs[waiterID] = job
    }

    /// A cancelled caller leaves at once; a queued request nobody waits for any more is dropped.
    private func cancelWaiter(_ waiterID: Int) {
        guard let job = waiterJobs.removeValue(forKey: waiterID),
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: TunaError.cancelled)
        if job.waiters.isEmpty, let index = queue.firstIndex(where: { $0 === job }) {
            queue.remove(at: index)
        }
    }

    private func finish(_ job: Job, with result: Result<HTTPResponse, Error>) {
        let waiters = job.waiters
        job.waiters.removeAll()
        for (waiterID, continuation) in waiters {
            waiterJobs[waiterID] = nil
            continuation.resume(with: result)
        }
    }

    private func failQueued(with error: TunaError) {
        let jobs = queue
        queue.removeAll()
        for job in jobs { finish(job, with: .failure(error)) }
    }

    /// Highest priority first, FIFO within a priority (the queue is kept in arrival order).
    private func takeNextJob() -> Job {
        var best = 0
        for index in queue.indices.dropFirst() where queue[index].priority > queue[best].priority { best = index }
        return queue.remove(at: best)
    }

    // MARK: - Pump

    private func startPumpIfNeeded() {
        guard !pumping, !queue.isEmpty else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while !queue.isEmpty {
            let now = clock.now()
            rollDay(now)
            if let error = breakerError(now) {
                failQueued(with: error)
                break
            }
            let wait = spacingDelay(at: now)
            if wait > GovernorCore.timeEpsilon {
                do {
                    try await clock.sleep(seconds: wait)
                } catch {
                    failQueued(with: .cancelled)
                    break
                }
                continue // re-evaluate: the breaker, the policy or the queue may have changed meanwhile
            }
            let job = takeNextJob()
            if job.priority == .background, requestsToday >= policy.dailySoftBudget {
                finish(job, with: .failure(TunaError.budgetExhausted))
                continue
            }
            await execute(job, startedAt: now)
        }
        pumping = false
    }

    private func execute(_ job: Job, startedAt start: Date) async {
        inFlight = job
        lastRequestAt = start
        requestsToday += 1
        gapFraction = GovernorCore.unit(random())
        persist()

        let result: Result<HTTPResponse, Error>
        do {
            result = .success(try await client.send(job.request))
        } catch {
            result = .failure(error)
        }
        let end = clock.now()
        inFlight = nil

        let verdict = judge(result, request: job.request, at: end)
        record(job, start: start, end: end, verdict: verdict)
        finish(job, with: verdict.delivery)
        if let error = verdict.queueError { failQueued(with: error) }
    }

    // MARK: - Breaker

    private func judge(_ result: Result<HTTPResponse, Error>, request: HTTPRequest, at now: Date) -> Verdict {
        let host = request.hostKey
        let response: HTTPResponse
        var thrown: TunaError?
        switch result {
        case .success(let value):
            response = value
        case .failure(let error):
            let mapped = GovernorCore.map(error)
            switch mapped {
            case .cancelled:
                return Verdict(delivery: .failure(mapped), status: nil, outcome: "cancelled", queueError: nil)
            case .http(let status, _):
                // A client that reports statuses as errors: judge the status, deliver the original error.
                response = HTTPResponse(status: status, url: request.url)
                thrown = mapped
            case .unauthorized:
                response = HTTPResponse(status: 401, url: request.url)
                thrown = mapped
            default:
                if let error = countFailure(at: now, description: "network error") {
                    return Verdict(delivery: .failure(error), status: nil, outcome: "network error, \(pauseText(error, now))",
                                   queueError: error)
                }
                return Verdict(delivery: .failure(mapped), status: nil, outcome: "network error", queueError: nil)
            }
        }

        let status = response.status
        let passThrough: Result<HTTPResponse, Error> = thrown.map { .failure($0) } ?? .success(response)
        if status == 401 || status == 403 {
            let reason = "HTTP \(status): \(host) refused the account"
            block(reason: reason)
            return Verdict(delivery: .failure(TunaError.unauthorized(reason)), status: status,
                           outcome: "HTTP \(status), account blocked", queueError: .unauthorized(reason))
        }
        let retryAfter = status >= 400 ? response.retryAfterDelay(now: now) : nil
        if policy.tripStatuses.contains(status) || (retryAfter ?? 0) > 0 {
            let error = trip(at: now, reason: "HTTP \(status) from \(host)", retryAfter: retryAfter)
            return Verdict(delivery: .failure(error), status: status, outcome: "HTTP \(status), \(pauseText(error, now))",
                           queueError: error)
        }
        if (500 ... 599).contains(status) {
            if let error = countFailure(at: now, description: "HTTP \(status)") {
                return Verdict(delivery: .failure(error), status: status, outcome: "HTTP \(status), \(pauseText(error, now))",
                               queueError: error)
            }
            return Verdict(delivery: passThrough, status: status, outcome: "HTTP \(status)", queueError: nil)
        }
        // Anything else means the server is alive and answering.
        consecutiveFailures = 0
        probation = false
        if response.isSuccess { decayTripCount(at: now) }
        return Verdict(delivery: passThrough, status: status, outcome: response.isSuccess ? "ok" : "HTTP \(status)",
                       queueError: nil)
    }

    /// Counts a 5xx / network error and opens the breaker when the streak is long enough (or during probation).
    private func countFailure(at now: Date, description: String) -> TunaError? {
        consecutiveFailures += 1
        let threshold = max(1, policy.failuresBeforeTrip)
        guard probation || consecutiveFailures >= threshold else { return nil }
        let reason = consecutiveFailures >= threshold
            ? "\(consecutiveFailures) failed requests in a row (last: \(description))"
            : "\(description) on the first request after a pause"
        return trip(at: now, reason: reason, retryAfter: nil)
    }

    /// Opens the breaker for `breakerSchedule[min(trips so far, last)]`, or Retry-After when that is longer, and
    /// returns the error for the callers. A pause that is already running (opened via `tripBreaker` while this
    /// request was in flight) gets no extra escalation step, only a longer Retry-After; a block is never downgraded.
    private func trip(at now: Date, reason: String, retryAfter: TimeInterval?) -> TunaError {
        let requested = min(max(0, retryAfter ?? 0), GovernorCore.maxRetryAfter)
        switch breaker {
        case .authBlocked(let blockedReason):
            return .unauthorized(blockedReason)
        case .open(let until, let openReason, let trips) where until > now:
            let extended = max(until, now.addingTimeInterval(requested))
            if extended > until {
                breaker = .open(until: extended, reason: openReason, tripCount: trips)
                persist()
            }
            return .paused(until: extended, reason: openReason)
        default:
            break
        }
        let previousTrips = effectiveTripCount(at: now)
        let schedule = policy.breakerSchedule.isEmpty ? GovernorPolicy().breakerSchedule : policy.breakerSchedule
        let scheduled = max(0, schedule[min(previousTrips, schedule.count - 1)])
        let until = now.addingTimeInterval(max(scheduled, requested))
        tripCount = previousTrips + 1
        lastTripAt = now
        consecutiveFailures = 0
        probation = false
        breaker = .open(until: until, reason: reason, tripCount: tripCount)
        persist()
        TunaLog.shared.log("governor", "Provider \(providerID) paused for \(GovernorCore.describe(until.timeIntervalSince(now))): \(reason)")
        return .paused(until: until, reason: reason)
    }

    private func block(reason: String) {
        breaker = .authBlocked(reason: reason)
        consecutiveFailures = 0
        probation = false
        persist()
        TunaLog.shared.log("governor", "Provider \(providerID) blocked until the user retries: \(reason)")
    }

    /// The error a call gets right now, if any. Closes an expired pause (and puts the breaker on probation).
    private func breakerError(_ now: Date) -> TunaError? {
        switch breaker {
        case .closed:
            return nil
        case .authBlocked(let reason):
            return .unauthorized(reason)
        case .open(let until, let reason, _):
            if until > now { return .paused(until: until, reason: reason) }
            breaker = .closed
            probation = true
            persist()
            return nil
        }
    }

    private func effectiveTripCount(at now: Date) -> Int {
        guard tripCount > 0 else { return 0 }
        if let last = lastTripAt, now.timeIntervalSince(last) >= GovernorCore.tripCountDecay { return 0 }
        return tripCount
    }

    private func decayTripCount(at now: Date) {
        guard tripCount > 0, effectiveTripCount(at: now) == 0 else { return }
        tripCount = 0
        lastTripAt = nil
        persist()
    }

    // MARK: - Pacing and budget

    /// Seconds until the next request may start (spacing from the previous START). A clock that jumped
    /// backwards never stalls the queue for more than one gap.
    private func spacingDelay(at now: Date) -> TimeInterval {
        guard let last = lastRequestAt else { return 0 }
        let gap = max(0, policy.minInterval) + gapFraction * max(0, policy.jitter)
        let remaining = last.addingTimeInterval(gap).timeIntervalSince(now)
        return min(max(0, remaining), gap)
    }

    private func nextAllowedAt(_ now: Date) -> Date? {
        switch breaker {
        case .open(let until, _, _): return until
        case .authBlocked: return nil
        case .closed:
            let wait = spacingDelay(at: now)
            return wait > GovernorCore.timeEpsilon ? now.addingTimeInterval(wait) : nil
        }
    }

    private func rollDay(_ now: Date) {
        let today = GovernorCore.dayStamp(for: now, timeZone: timeZone)
        guard today != dayStamp else { return }
        dayStamp = today
        requestsToday = 0
        persist()
    }

    // MARK: - Log and persistence

    private func record(_ job: Job, start: Date, end: Date, verdict: Verdict) {
        logSeed += 1
        let milliseconds = min(max(0, end.timeIntervalSince(start) * 1000), 86_400_000)
        log.append(RequestLogEntry(id: logSeed, date: start, purpose: job.purpose,
                                   summary: RequestRedaction.summary(for: job.request.url, method: job.request.method),
                                   status: verdict.status, durationMs: Int(milliseconds.rounded()),
                                   priority: job.priority, outcome: verdict.outcome))
        if log.count > GovernorCore.logCapacity { log.removeFirst(log.count - GovernorCore.logCapacity) }
    }

    private func persist() {
        guard let persistence else { return }
        var state = GovernorPersistedState(breaker: breaker, tripCount: tripCount, dayStamp: dayStamp,
                                           requestsToday: requestsToday, lastRequestAt: lastRequestAt)
        state.lastTripAt = lastTripAt
        persistence.save(state, providerID: providerID)
    }

    // MARK: - Helpers

    private static func coalesceKey(for request: HTTPRequest) -> CoalesceKey? {
        guard request.method.uppercased() == "GET", request.body == nil else { return nil }
        return CoalesceKey(url: request.url.absoluteString, headers: request.headers)
    }

    /// Local calendar day "yyyy-MM-dd" of `date`.
    static func dayStamp(for date: Date, timeZone: TimeZone?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? TimeZone.autoupdatingCurrent
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    static func map(_ error: Error) -> TunaError {
        if let tuna = error as? TunaError { return tuna }
        if error is CancellationError { return .cancelled }
        return .network(error.localizedDescription)
    }

    /// "45 s", "5 min", "2 h".
    static func describe(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value >= 3600 { return "\(Int((value / 3600).rounded())) h" }
        if value >= 60 { return "\(Int((value / 60).rounded())) min" }
        return "\(Int(value.rounded())) s"
    }

    private func pauseText(_ error: TunaError, _ now: Date) -> String {
        switch error {
        case .paused(let until, _): return "paused \(GovernorCore.describe(until.timeIntervalSince(now)))"
        case .unauthorized: return "account blocked"
        default: return "paused"
        }
    }
}
