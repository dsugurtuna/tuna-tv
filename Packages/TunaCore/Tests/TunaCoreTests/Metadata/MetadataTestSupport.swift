import Foundation
import XCTest
@testable import TunaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared helpers for the metadata tests (prefixed so they never clash with other test helpers).
enum MetadataTestKit {
    struct MissingFixture: Error, CustomStringConvertible {
        let name: String
        var description: String { "Missing fixture Fixtures/metadata/\(name).json" }
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/metadata") else {
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }

    /// A limiter that never slows tests down (the service enforces its own concurrency caps).
    static func limiter() -> HostLimiter {
        HostLimiter(defaultRule: HostLimiter.Rule(maxConcurrent: 32, minInterval: 0))
    }

    /// A fresh temporary FileStore, removed when the test ends.
    static func files(for testCase: XCTestCase) -> FileStore {
        let files = FileStore.temporary(named: "metadata-tests-\(UUID().uuidString)")
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: files.baseURL) }
        return files
    }

    static func query(_ request: HTTPRequest) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    static func queryItems(_ request: HTTPRequest) -> [URLQueryItem] {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    static func title(_ id: String, _ name: String, kind: TitleKind = .movie, year: Int? = nil, tmdbID: Int? = nil) -> Title {
        Title(id: id, kind: kind, name: name, year: year, variants: [], placement: .showcase, bestQuality: .uhd,
              providerTMDBID: tmdbID)
    }

    static func service(for testCase: XCTestCase, keys: MetadataKeys, http: MetadataFakeHTTP, workers: Int = 4,
                        files: FileStore? = nil) -> (service: MetadataService, store: MetadataStore, files: FileStore) {
        let files = files ?? self.files(for: testCase)
        let store = MetadataStore(files: files)
        var options = MetadataServiceCore.Options()
        options.workers = workers
        options.updateBatchInterval = 0.05
        options.flushDelay = 0.05
        options.errorCooldown = 0.05
        let service = MetadataService(keys: keys, store: store, http: http, limiter: limiter(), files: files, options: options)
        return (service, store, files)
    }

    /// First element of a stream, or nil after `timeout` seconds.
    static func next<T: Sendable>(_ stream: AsyncStream<T>, timeout: TimeInterval = 5) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static let v3Key = "0123456789abcdef0123456789abcdef"
    static let v4Token = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0dW5hLXRlc3QiLCJzY29wZXMiOlsiYXBpX3JlYWQiXX0.c2lnbmF0dXJlLXR1bmE"
}

/// Fake `HTTPClient`: serves fixtures by host/path/query, records every request and the peak number of
/// concurrent requests per host.
final class MetadataFakeHTTP: HTTPClient, @unchecked Sendable {
    typealias Responder = @Sendable (HTTPRequest) -> HTTPResponse

    private struct Route {
        let matches: @Sendable (HTTPRequest) -> Bool
        let respond: Responder
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var log: [HTTPRequest] = []
    private var running: [String: Int] = [:]
    private var peaks: [String: Int] = [:]
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    /// Serves `fixture` for GETs to host+path whose query contains every given item. Later routes win.
    func on(_ host: String, _ path: String, query: [String: String] = [:], status: Int = 200, fixture: String) {
        let body = (try? MetadataTestKit.fixture(fixture)) ?? Data("missing fixture \(fixture)".utf8)
        on(host, path, query: query, status: status, body: body)
    }

    func on(_ host: String, _ path: String, query: [String: String] = [:], status: Int = 200, body: Data) {
        on(where: { request in
            guard request.url.host == host, request.url.path == path else { return false }
            let actual = MetadataTestKit.query(request)
            return query.allSatisfy { actual[$0.key] == $0.value }
        }, respond: { request in HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body, url: request.url) })
    }

    func on(where matches: @escaping @Sendable (HTTPRequest) -> Bool, respond: @escaping Responder) {
        lock.lock()
        routes.insert(Route(matches: matches, respond: respond), at: 0)
        lock.unlock()
    }

    func removeAllRoutes() {
        lock.lock()
        routes.removeAll()
        lock.unlock()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = begin(request)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        finish(request)
        if let route { return route.respond(request) }
        return HTTPResponse(status: 404, body: Data(#"{"status_code":34,"status_message":"not found"}"#.utf8), url: request.url)
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(host: String) -> [HTTPRequest] { requests.filter { $0.url.host == host } }

    func paths(host: String) -> [String] { requests(host: host).map { $0.url.path } }

    func peakConcurrency(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peaks[host] ?? 0
    }

    func clearLog() {
        lock.lock()
        log.removeAll()
        peaks.removeAll()
        lock.unlock()
    }

    private func begin(_ request: HTTPRequest) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        log.append(request)
        let host = request.url.host ?? ""
        running[host, default: 0] += 1
        peaks[host] = max(peaks[host] ?? 0, running[host] ?? 0)
        return routes.first(where: { $0.matches(request) })
    }

    private func finish(_ request: HTTPRequest) {
        lock.lock()
        running[request.url.host ?? "", default: 1] -= 1
        lock.unlock()
    }
}
