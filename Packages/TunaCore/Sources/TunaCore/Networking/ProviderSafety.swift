import Foundation

// =====================================================================================================
// PROVIDER SAFETY CONTRACT (owner: Networking). These types are the reason Tuna TV does not get accounts
// banned. Every request to an IPTV provider host (player_api.php, get.php, xmltv.php, panel-hosted images)
// goes through exactly one `RequestGovernor` per provider. Every stream open goes through `StreamGate`.
// See docs/ARCHITECTURE.md "Provider Safety Spec" for the numbers; tests in ProviderSafetyTests.
// =====================================================================================================

public enum RequestPriority: Int, Codable, Sendable, Comparable {
    /// Catalog sync, guide download: waits behind user actions.
    case background = 0
    /// Something the user is waiting for (detail page info, login check).
    case userInitiated = 1

    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GovernorPolicy: Codable, Hashable, Sendable {
    /// Never more than this many requests in flight to the provider. Always 1.
    public var maxInFlight: Int
    /// Minimum seconds between request starts.
    public var minInterval: TimeInterval
    /// Random extra delay in 0...jitter seconds added to `minInterval`.
    public var jitter: TimeInterval
    /// Soft daily cap. Past it, background requests are refused (`TunaError.budgetExhausted`); user-initiated still pass.
    public var dailySoftBudget: Int
    /// Circuit-breaker pause durations for consecutive trips (seconds): 5 min, 30 min, 2 h.
    public var breakerSchedule: [TimeInterval]
    /// Statuses that trip the breaker immediately.
    public var tripStatuses: Set<Int>
    /// 5xx responses / network errors allowed in a row before the breaker trips.
    public var failuresBeforeTrip: Int

    public init(maxInFlight: Int = 1, minInterval: TimeInterval = 1.5, jitter: TimeInterval = 0.5, dailySoftBudget: Int = 400,
                breakerSchedule: [TimeInterval] = [300, 1800, 7200],
                tripStatuses: Set<Int> = [401, 403, 429, 458, 509, 520, 521, 522, 523, 524, 525, 526, 527],
                failuresBeforeTrip: Int = 2) {
        self.maxInFlight = 1 // deliberately not configurable above 1
        _ = maxInFlight
        self.minInterval = max(0.5, minInterval)
        self.jitter = max(0, jitter)
        self.dailySoftBudget = dailySoftBudget
        self.breakerSchedule = breakerSchedule.isEmpty ? [300, 1800, 7200] : breakerSchedule
        self.tripStatuses = tripStatuses
        self.failuresBeforeTrip = max(1, failuresBeforeTrip)
    }

    public static func forPacing(_ pacing: PacingProfile) -> GovernorPolicy {
        GovernorPolicy(minInterval: pacing.minInterval, jitter: pacing.minInterval / 3)
    }
}

public enum BreakerState: Codable, Hashable, Sendable {
    case closed
    /// No requests until `until`.
    case open(until: Date, reason: String, tripCount: Int)
    /// Credentials refused / account unusable: no requests until the user edits the provider or presses Retry.
    case authBlocked(reason: String)
}

public struct RequestLogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var date: Date
    /// What it was for: "account", "live_streams", "vod_info", "xmltv", "image" ...
    public var purpose: String
    /// Path + action only. Credentials are never stored.
    public var summary: String
    public var status: Int?
    public var durationMs: Int
    public var priority: RequestPriority
    public var outcome: String

    public init(id: Int, date: Date, purpose: String, summary: String, status: Int?, durationMs: Int,
                priority: RequestPriority, outcome: String) {
        self.id = id
        self.date = date
        self.purpose = purpose
        self.summary = summary
        self.status = status
        self.durationMs = durationMs
        self.priority = priority
        self.outcome = outcome
    }
}

/// What the UI's "Provider Shield" shows.
public struct GovernorSnapshot: Codable, Hashable, Sendable {
    public var providerID: ProviderID
    public var breaker: BreakerState
    public var inFlight: Int
    public var queued: Int
    public var requestsToday: Int
    public var dailySoftBudget: Int
    public var lastRequestAt: Date?
    public var nextAllowedAt: Date?
    public var recent: [RequestLogEntry]

    public init(providerID: ProviderID, breaker: BreakerState = .closed, inFlight: Int = 0, queued: Int = 0,
                requestsToday: Int = 0, dailySoftBudget: Int = 400, lastRequestAt: Date? = nil,
                nextAllowedAt: Date? = nil, recent: [RequestLogEntry] = []) {
        self.providerID = providerID
        self.breaker = breaker
        self.inFlight = inFlight
        self.queued = queued
        self.requestsToday = requestsToday
        self.dailySoftBudget = dailySoftBudget
        self.lastRequestAt = lastRequestAt
        self.nextAllowedAt = nextAllowedAt
        self.recent = recent
    }

    public var isHealthy: Bool { if case .closed = breaker { return true } else { return false } }
}

/// Serializes and paces every request to ONE provider. Behaviour (all unit-tested):
/// 1. At most one request in flight; FIFO within a priority, `.userInitiated` jumps ahead of `.background`.
/// 2. Request starts are spaced by `minInterval + random(0...jitter)` measured from the previous START.
/// 3. Identical in-flight/queued GETs (same URL) are coalesced: callers share one response.
/// 4. Responses with a status in `tripStatuses`, or `failuresBeforeTrip` consecutive 5xx/network errors,
///    open the breaker for `breakerSchedule[tripCount]` (or Retry-After if longer). While open every call throws
///    `TunaError.paused` immediately without touching the network. 401/403 put it in `.authBlocked`.
/// 5. NO automatic retries. A failed request fails; the caller decides (and callers never loop).
/// 6. Daily counter resets at local midnight; past `dailySoftBudget` background calls throw `.budgetExhausted`.
/// 7. Breaker state and daily counter persist across launches through `persistence` (so relaunching the app
///    does not reset a cooldown).
public actor RequestGovernor {
    public let providerID: ProviderID
    public private(set) var policy: GovernorPolicy

    public init(providerID: ProviderID, policy: GovernorPolicy, client: HTTPClient, clock: TunaClock = SystemClock(),
                persistence: GovernorPersistence? = nil, random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.providerID = providerID
        self.policy = policy
        self.impl = GovernorCore(providerID: providerID, policy: policy, client: client, clock: clock,
                                 persistence: persistence, random: random)
    }

    private let impl: GovernorCore

    /// Performs one request under all rules above. `purpose` is a short label for the request log.
    public func perform(_ request: HTTPRequest, priority: RequestPriority = .background, purpose: String) async throws -> HTTPResponse {
        try await impl.perform(request, priority: priority, purpose: purpose)
    }

    public func snapshot() async -> GovernorSnapshot { await impl.snapshot() }

    /// User pressed "Try now" / edited credentials: close the breaker (keeps the trip count for escalation).
    public func resetBreaker() async { await impl.resetBreaker() }

    public func updatePolicy(_ policy: GovernorPolicy) async {
        self.policy = policy
        await impl.updatePolicy(policy)
    }
}

/// Persists breaker + budget state per provider.
public protocol GovernorPersistence: Sendable {
    func load(providerID: ProviderID) -> GovernorPersistedState?
    func save(_ state: GovernorPersistedState, providerID: ProviderID)
}

public struct GovernorPersistedState: Codable, Hashable, Sendable {
    public var breaker: BreakerState
    public var tripCount: Int
    public var dayStamp: String
    public var requestsToday: Int
    public var lastRequestAt: Date?

    public init(breaker: BreakerState = .closed, tripCount: Int = 0, dayStamp: String = "", requestsToday: Int = 0, lastRequestAt: Date? = nil) {
        self.breaker = breaker
        self.tripCount = tripCount
        self.dayStamp = dayStamp
        self.requestsToday = requestsToday
        self.lastRequestAt = lastRequestAt
    }
}

/// Per-host limiter for NON-provider hosts (TMDB, TVMaze, OMDb, image CDNs, iptv-org).
/// `maxConcurrent` requests at once and `minInterval` between starts, per host key.
public actor HostLimiter {
    public struct Rule: Sendable, Hashable {
        public var maxConcurrent: Int
        public var minInterval: TimeInterval
        public init(maxConcurrent: Int, minInterval: TimeInterval) {
            self.maxConcurrent = max(1, maxConcurrent)
            self.minInterval = max(0, minInterval)
        }

        /// Images hosted on an IPTV panel: one at a time, at least 1 s apart.
        public static let providerImages = Rule(maxConcurrent: 1, minInterval: 1.0)
    }

    public init(defaultRule: Rule = Rule(maxConcurrent: 4, minInterval: 0.05), rules: [String: Rule] = [:],
                clock: TunaClock = SystemClock()) {
        self.impl = HostLimiterCore(defaultRule: defaultRule, rules: rules, clock: clock)
    }

    private let impl: HostLimiterCore

    /// Runs `operation` once a slot for `host` is free and pacing allows.
    public func run<T: Sendable>(host: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await impl.run(host: host, operation)
    }

    public func setRule(_ rule: Rule, for host: String) async { await impl.setRule(rule, for: host) }

    /// Default rules: api.themoviedb.org 8 concurrent / 25 ms; image.tmdb.org 6 / 0; api.tvmaze.com 1 / 0.55 s;
    /// www.omdbapi.com 2 / 0.2 s; everything else 4 / 50 ms.
    /// IPTV PROVIDER HOSTS: the app must call `setRule(.providerImages, for: providerHost)` for every provider
    /// panel host, so logos/posters served by the panel load ONE at a time, ≥ 1 s apart (and are cached forever).
    /// Prefer TMDB / iptv-org artwork over panel-hosted images whenever both exist.
    public static func standard(clock: TunaClock = SystemClock()) -> HostLimiter {
        HostLimiter(rules: [
            "api.themoviedb.org": Rule(maxConcurrent: 8, minInterval: 0.025),
            "image.tmdb.org": Rule(maxConcurrent: 6, minInterval: 0),
            "api.tvmaze.com": Rule(maxConcurrent: 1, minInterval: 0.55),
            "www.omdbapi.com": Rule(maxConcurrent: 2, minInterval: 0.2),
        ], clock: clock)
    }
}

/// A ticket for one open stream connection. Return it with `StreamGate.close(_:)` once the player has
/// actually stopped (engine idle/stopped), not when the user merely clicked away.
public struct StreamTicket: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let ref: StreamRef
    public let openedAt: Date

    public init(id: UUID = UUID(), ref: StreamRef, openedAt: Date) {
        self.id = id
        self.ref = ref
        self.openedAt = openedAt
    }
}

/// Enforces the one-connection rule for streams (player, recordings, anything that reads a stream URL).
/// Behaviour (unit-tested):
/// 1. At most `maxStreams(providerID)` open tickets per provider (default 1).
/// 2. `open` while the cap is reached throws `TunaError.streamRateLimited` unless `preempt` is true, in which case
///    the gate calls the registered `onPreempt` handler (the player stops), waits for `close` of the old ticket.
/// 3. A new open waits until `releaseGrace` (1.5 s) has passed since the previous ticket of that provider closed,
///    and `minOpenSpacing` (1.5 s) since the previous open started.
/// 4. At most `maxOpensPerMinute` (8) opens per provider per rolling minute; beyond that `.streamRateLimited`.
public actor StreamGate {
    public init(releaseGrace: TimeInterval = 1.5, minOpenSpacing: TimeInterval = 1.5, maxOpensPerMinute: Int = 8,
                clock: TunaClock = SystemClock()) {
        self.impl = StreamGateCore(releaseGrace: releaseGrace, minOpenSpacing: minOpenSpacing,
                                   maxOpensPerMinute: maxOpensPerMinute, clock: clock)
    }

    private let impl: StreamGateCore

    public func setMaxStreams(_ count: Int, for providerID: ProviderID) async { await impl.setMaxStreams(count, for: providerID) }

    /// Called when a held ticket must be given up for a new open (the app stops its player and then calls `close`).
    public func setPreemptHandler(_ handler: @escaping @Sendable (StreamTicket) async -> Void) async {
        await impl.setPreemptHandler(handler)
    }

    public func open(_ ref: StreamRef, preempt: Bool = true) async throws -> StreamTicket {
        try await impl.open(ref, preempt: preempt)
    }

    public func close(_ ticket: StreamTicket) async { await impl.close(ticket) }

    public func openTickets() async -> [StreamTicket] { await impl.openTickets() }
}

// MARK: - Implementation shells (owner: Networking). Replace the bodies; keep the method signatures.

final class GovernorCore: @unchecked Sendable {
    init(providerID: ProviderID, policy: GovernorPolicy, client: HTTPClient, clock: TunaClock,
         persistence: GovernorPersistence?, random: @escaping @Sendable () -> Double) {
        fatalError("TODO(networking): implement GovernorCore")
    }
    func perform(_ request: HTTPRequest, priority: RequestPriority, purpose: String) async throws -> HTTPResponse {
        fatalError("TODO(networking)")
    }
    func snapshot() async -> GovernorSnapshot { fatalError("TODO(networking)") }
    func resetBreaker() async { fatalError("TODO(networking)") }
    func updatePolicy(_ policy: GovernorPolicy) async { fatalError("TODO(networking)") }
}

final class HostLimiterCore: @unchecked Sendable {
    init(defaultRule: HostLimiter.Rule, rules: [String: HostLimiter.Rule], clock: TunaClock) {
        fatalError("TODO(networking): implement HostLimiterCore")
    }
    func run<T: Sendable>(host: String, _ operation: @Sendable () async throws -> T) async throws -> T { fatalError("TODO(networking)") }
    func setRule(_ rule: HostLimiter.Rule, for host: String) async { fatalError("TODO(networking)") }
}

final class StreamGateCore: @unchecked Sendable {
    init(releaseGrace: TimeInterval, minOpenSpacing: TimeInterval, maxOpensPerMinute: Int, clock: TunaClock) {
        fatalError("TODO(networking): implement StreamGateCore")
    }
    func setMaxStreams(_ count: Int, for providerID: ProviderID) async { fatalError("TODO(networking)") }
    func setPreemptHandler(_ handler: @escaping @Sendable (StreamTicket) async -> Void) async { fatalError("TODO(networking)") }
    func open(_ ref: StreamRef, preempt: Bool) async throws -> StreamTicket { fatalError("TODO(networking)") }
    func close(_ ticket: StreamTicket) async { fatalError("TODO(networking)") }
    func openTickets() async -> [StreamTicket] { fatalError("TODO(networking)") }
}
