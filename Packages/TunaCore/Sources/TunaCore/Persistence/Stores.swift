import Foundation

// =====================================================================================================
// PERSISTENCE CONTRACT (owner: Networking/Persistence). Plain files under one base directory
// (the app passes ~/Library/Application Support/TunaTV2). Atomic writes, never partial files.
// =====================================================================================================

/// Atomic JSON/data file storage rooted at `baseURL`. Thread-safe.
public final class FileStore: @unchecked Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Temporary-directory store for tests and snapshot runs.
    public static func temporary(named name: String = UUID().uuidString) -> FileStore {
        FileStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("tunatv-\(name)", isDirectory: true))
    }

    public func url(for relativePath: String) -> URL { baseURL.appendingPathComponent(relativePath) }

    public func exists(_ relativePath: String) -> Bool { FileManager.default.fileExists(atPath: url(for: relativePath).path) }

    public func readData(_ relativePath: String) -> Data? { fatalError("TODO(persistence)") }

    /// Writes atomically (temp file + replace), creating intermediate directories.
    public func writeData(_ data: Data, to relativePath: String) throws { fatalError("TODO(persistence)") }

    public func read<T: Decodable>(_ type: T.Type, from relativePath: String) -> T? { fatalError("TODO(persistence)") }

    public func write<T: Encodable>(_ value: T, to relativePath: String) throws { fatalError("TODO(persistence)") }

    public func remove(_ relativePath: String) { fatalError("TODO(persistence)") }

    /// Modification date of a stored file.
    public func modifiedAt(_ relativePath: String) -> Date? { fatalError("TODO(persistence)") }

    /// Total size in bytes under a relative directory ("" for everything).
    public func size(of relativeDirectory: String) -> Int64 { fatalError("TODO(persistence)") }

    public func list(_ relativeDirectory: String) -> [String] { fatalError("TODO(persistence)") }
}

/// Cache of raw provider/metadata responses with fetch timestamps, so the app shows cached data instantly
/// and only re-fetches when stale. Keys are logical names, e.g. "providers/<id>/vod_streams.json".
public final class CacheStore: @unchecked Sendable {
    public let files: FileStore

    public init(files: FileStore) { self.files = files }

    public struct Entry: Sendable {
        public var data: Data
        public var fetchedAt: Date
        public init(data: Data, fetchedAt: Date) {
            self.data = data
            self.fetchedAt = fetchedAt
        }
    }

    public func entry(_ key: String) -> Entry? { fatalError("TODO(persistence)") }

    /// Fresh entry if younger than `maxAge`, else nil.
    public func fresh(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Entry? { fatalError("TODO(persistence)") }

    public func store(_ data: Data, for key: String, fetchedAt: Date = Date()) throws { fatalError("TODO(persistence)") }

    public func remove(_ key: String) { fatalError("TODO(persistence)") }

    public func removeAll(prefix: String) { fatalError("TODO(persistence)") }
}

/// Keychain on macOS (implemented in the app), in-memory in tests.
public protocol SecretStore: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init(_ initial: [String: String] = [:]) { values = initial }
    public func secret(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func setSecret(_ value: String?, for key: String) { lock.lock(); values[key] = value; lock.unlock() }
}

public enum SecretKeys {
    public static func providerPassword(_ id: ProviderID) -> String { "provider.\(id).password" }
    public static let tmdbToken = "metadata.tmdb.token"
    public static let omdbKey = "metadata.omdb.key"
}

/// Typed JSON documents the app persists: settings, providers, user state, governor state.
public final class AppStateStore: @unchecked Sendable, GovernorPersistence {
    public let files: FileStore

    public init(files: FileStore) { self.files = files }

    public func loadSettings() -> AppSettings { fatalError("TODO(persistence)") }
    public func saveSettings(_ settings: AppSettings) { fatalError("TODO(persistence)") }

    public func loadProviders() -> [ProviderConfig] { fatalError("TODO(persistence)") }
    public func saveProviders(_ providers: [ProviderConfig]) { fatalError("TODO(persistence)") }

    public func loadUserState() -> UserState { fatalError("TODO(persistence)") }
    public func saveUserState(_ state: UserState) { fatalError("TODO(persistence)") }

    // GovernorPersistence
    public func load(providerID: ProviderID) -> GovernorPersistedState? { fatalError("TODO(persistence)") }
    public func save(_ state: GovernorPersistedState, providerID: ProviderID) { fatalError("TODO(persistence)") }
}
