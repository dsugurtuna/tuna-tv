import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Host used for per-host limits ("example.com:8080").
    public var hostKey: String {
        let host = url.host ?? "unknown"
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var url: URL?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), url: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == lower })?.value
    }

    /// Retry-After in seconds (delta-seconds form only), if present.
    public var retryAfterSeconds: TimeInterval? {
        guard let value = header("Retry-After"), let seconds = TimeInterval(value.tunaTrimmed) else { return nil }
        return seconds
    }
}

/// Abstraction over the network so request-pattern rules are unit-testable.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession-backed client. One per provider (its session caps connections per host to 1).
/// Implemented by the Networking owner. MUST set `httpMaximumConnectionsPerHost` from `maxConnectionsPerHost`,
/// disable URLCache for API calls, and map transport errors to `TunaError.network`.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    public let maxConnectionsPerHost: Int
    public let defaultHeaders: [String: String]
    private let session: URLSession

    public init(maxConnectionsPerHost: Int = 1, defaultHeaders: [String: String] = [:], timeout: TimeInterval = 30) {
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.defaultHeaders = defaultHeaders
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(1, maxConnectionsPerHost)
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 600)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldUsePipelining = false
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in defaultHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            if let fields = http?.allHeaderFields {
                for (key, value) in fields { headers[String(describing: key)] = String(describing: value) }
            }
            return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data, url: http?.url)
        } catch is CancellationError {
            throw TunaError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw TunaError.cancelled
        } catch {
            throw TunaError.network(error.localizedDescription)
        }
    }
}
