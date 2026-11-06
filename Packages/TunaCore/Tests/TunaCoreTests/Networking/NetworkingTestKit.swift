import Foundation
import XCTest
@testable import TunaCore

/// Fakes and helpers for the Networking tests. Namespaced so other test files can define their own fakes.
enum NetTestKit {
    static let host = "http://panel.test:8080"

    static func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(url: URL(string: host + path)!, method: method, headers: headers)
    }

    /// One scripted answer of the fake client.
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var error: TunaError?

        static func status(_ status: Int, headers: [String: String] = [:]) -> Reply { Reply(status: status, headers: headers) }
        static func failure(_ error: TunaError) -> Reply { Reply(error: error) }
    }

    /// Records every request with its start time (injected clock) and how many requests were in flight at once.
    /// Answers with scripted replies (then 200); the body echoes the URL. `hold()` parks requests until `release()`.
    actor FakeHTTPClient: HTTPClient {
        private let clock: TunaClock
        private var script: [Reply] = []
        private(set) var requests: [HTTPRequest] = []
        private(set) var startTimes: [Date] = []
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0
        private var holding = false
        private var held: [CheckedContinuation<Void, Never>] = []

        init(clock: TunaClock) { self.clock = clock }

        func enqueue(_ replies: Reply...) { script.append(contentsOf: replies) }
        func hold() { holding = true }

        func release() {
            holding = false
            let parked = held
            held.removeAll()
            for continuation in parked { continuation.resume() }
        }

        var heldCount: Int { held.count }
        var callCount: Int { requests.count }
        var paths: [String] { requests.map { $0.url.path } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            startTimes.append(clock.now())
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            if holding { await withCheckedContinuation { held.append($0) } }
            for _ in 0 ..< 3 { await Task.yield() }
            let reply = script.isEmpty ? Reply() : script.removeFirst()
            if let error = reply.error { throw error }
            return HTTPResponse(status: reply.status, headers: reply.headers, body: Data(request.url.absoluteString.utf8), url: request.url)
        }
    }

    /// In-memory `GovernorPersistence` that counts saves.
    final class MemoryPersistence: GovernorPersistence, @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ProviderID: GovernorPersistedState] = [:]
        private var saves = 0

        func load(providerID: ProviderID) -> GovernorPersistedState? {
            lock.lock()
            defer { lock.unlock() }
            return states[providerID]
        }

        func save(_ state: GovernorPersistedState, providerID: ProviderID) {
            lock.lock()
            states[providerID] = state
            saves += 1
            lock.unlock()
        }

        var saveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return saves
        }
    }

    /// Deterministic "random" numbers: returns `values` in order, then repeats the last one.
    final class SequenceRandom: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [Double]
        private var index = 0

        init(_ values: [Double]) { self.values = values }

        func next() -> Double {
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }

    /// A latch that async operations can wait on until the test opens it.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let parked = waiters
            waiters.removeAll()
            for continuation in parked { continuation.resume() }
        }
    }

    /// Counts concurrently running operations and records their start times.
    actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var maxActive = 0
        private(set) var starts: [Date] = []
        private(set) var finished = 0

        func begin(at date: Date) {
            active += 1
            maxActive = max(maxActive, active)
            starts.append(date)
        }

        func end() {
            active -= 1
            finished += 1
        }
    }

    /// Polls `condition` (real time) until it holds or `timeout` passes.
    static func eventually(timeout: TimeInterval = 5, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        } while Date() < deadline
        return await condition()
    }

    /// The error thrown by `operation`, or nil when it succeeded.
    static func thrownError<T>(_ operation: () async throws -> T) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    /// `until` of a `TunaError.paused`.
    static func pausedUntil(_ error: Error?) -> Date? {
        if case .paused(let until, _)? = error as? TunaError { return until }
        return nil
    }

    static func isUnauthorized(_ error: Error?) -> Bool {
        if case .unauthorized? = error as? TunaError { return true }
        return false
    }
}
