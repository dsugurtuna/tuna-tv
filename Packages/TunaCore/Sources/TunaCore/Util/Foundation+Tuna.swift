import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// All errors TunaCore surfaces to the app.
public enum TunaError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The provider/host answered with an HTTP error status.
    case http(status: Int, host: String)
    /// Connection-level failure (timeout, DNS, TLS ...).
    case network(String)
    /// Response could not be decoded.
    case decoding(String)
    /// Bad credentials or account not usable (never retried automatically).
    case unauthorized(String)
    /// Requests to this provider are paused by the circuit breaker until `until`.
    case paused(until: Date, reason: String)
    /// Soft daily request budget used up; only user-initiated requests may continue.
    case budgetExhausted
    /// Too many stream opens in a short time (anti-flood protection).
    case streamRateLimited(retryAfter: TimeInterval)
    /// Invalid user input (bad URL ...).
    case invalidInput(String)
    /// The operation was superseded or cancelled.
    case cancelled
    /// Feature needs a key/configuration that is missing.
    case notConfigured(String)

    public var description: String {
        switch self {
        case .http(let status, let host): return "HTTP \(status) from \(host)"
        case .network(let message): return "Network error: \(message)"
        case .decoding(let message): return "Unexpected response: \(message)"
        case .unauthorized(let message): return "Not authorized: \(message)"
        case .paused(let until, let reason): return "Paused until \(until): \(reason)"
        case .budgetExhausted: return "Daily request budget reached"
        case .streamRateLimited(let retryAfter): return "Too many stream starts; wait \(Int(retryAfter.rounded())) s"
        case .invalidInput(let message): return "Invalid input: \(message)"
        case .cancelled: return "Cancelled"
        case .notConfigured(let message): return "Not configured: \(message)"
        }
    }

    /// Plain-language explanation for the UI.
    public var userMessage: String {
        switch self {
        case .http(let status, _):
            switch status {
            case 401, 403: return "Your provider refused the request. Check your username and password, or wait if another device is watching."
            case 429, 458, 509: return "Your provider is limiting requests. Tuna TV paused to protect your account."
            case 520...527: return "Your provider's server is not responding properly (HTTP \(status)). Try again later."
            case 500...599: return "Your provider's server had a problem (HTTP \(status))."
            default: return "Your provider answered with HTTP \(status)."
            }
        case .network: return "Could not reach the server. Check your internet connection."
        case .decoding: return "The provider sent something Tuna TV did not understand."
        case .unauthorized: return "Login failed or the account is not active."
        case .paused(let until, _):
            let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
            return "Provider requests are paused for about \(minutes) min to protect your account."
        case .budgetExhausted: return "Tuna TV has made many requests today and is holding back to protect your account."
        case .streamRateLimited(let retryAfter): return "Slow down a little: stream starts are limited. Try again in \(Int(retryAfter.rounded())) s."
        case .invalidInput(let message): return message
        case .cancelled: return "Cancelled."
        case .notConfigured(let message): return message
        }
    }
}

/// Injectable time source so pacing/backoff logic is testable without real sleeping.
public protocol TunaClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: TunaClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// A manually advanced clock for tests: `sleep` returns immediately and advances time.
public final class ManualClock: TunaClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    /// Every sleep duration requested, in order (assert pacing in tests).
    public private(set) var sleeps: [TimeInterval] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }

    public func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }

    public func sleep(seconds: TimeInterval) async throws {
        recordSleep(seconds)
        await Task.yield()
    }

    private func recordSleep(_ seconds: TimeInterval) {
        lock.lock()
        sleeps.append(seconds)
        if seconds > 0 { current = current.addingTimeInterval(seconds) }
        lock.unlock()
    }
}

public extension String {
    /// Lowercased, diacritics removed, Turkish dotless ı mapped to i. Used for search and keys.
    var tunaFolded: String {
        let base = self.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
        return base.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Trimmed of whitespace and newlines.
    var tunaTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil when empty after trimming.
    var nonEmpty: String? { let t = tunaTrimmed; return t.isEmpty ? nil : t }
}

public enum Flags {
    /// Regional-indicator flag emoji for an ISO 3166-1 alpha-2 code ("TR" -> 🇹🇷). Empty for invalid input.
    public static func emoji(for countryCode: String) -> String {
        let code = countryCode.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "" }
        var result = ""
        for scalar in code.unicodeScalars {
            if let flagScalar = Unicode.Scalar(127_397 + scalar.value) { result.unicodeScalars.append(flagScalar) }
        }
        return result
    }
}

/// Small thread-safe ring buffer log for the in-app diagnostics screen. Never logs secrets.
public final class TunaLog: @unchecked Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: Int
        public let date: Date
        public let category: String
        public let message: String
    }

    public static let shared = TunaLog()
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID = 0
    private var secrets: [String] = []
    public var capacity = 800

    public init() {}

    /// Values that must never appear in logs (passwords, usernames, API keys).
    public func registerSecret(_ value: String) {
        guard value.count >= 3 else { return }
        lock.lock(); if !secrets.contains(value) { secrets.append(value) }; lock.unlock()
    }

    public func redact(_ text: String) -> String {
        lock.lock(); let list = secrets; lock.unlock()
        var out = text
        for secret in list { out = out.replacingOccurrences(of: secret, with: "•••") }
        return out
    }

    public func log(_ category: String, _ message: String) {
        let clean = redact(message)
        lock.lock()
        entries.append(Entry(id: nextID, date: Date(), category: category, message: clean))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        #if DEBUG
        print("[\(category)] \(clean)")
        #endif
    }

    public func recent(_ limit: Int = 200) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }
}
