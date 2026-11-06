import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// =====================================================================================================
// PERSISTENCE CONTRACT (owner: Networking/Persistence). Plain files under one base directory
// (the app passes ~/Library/Application Support/TunaTV2). Atomic writes, never partial files.
// =====================================================================================================

/// Atomic JSON/data file storage rooted at `baseURL`. Thread-safe.
///
/// - Writes go to a hidden temporary file in the destination directory which is then renamed over the
///   destination (POSIX `rename`, atomic on one file system): readers see the old or the new file, never a mix.
/// - JSON uses `TunaJSON` (sorted keys, ISO 8601 dates). Missing or undecodable files read as nil.
/// - Relative paths are sanitized: empty, `.` and `..` components are dropped, so a path built from provider
///   data (ids, names) can never point outside `baseURL`.
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

    public func url(for relativePath: String) -> URL {
        let components = FileStore.components(of: relativePath)
        return components.isEmpty ? baseURL : baseURL.appendingPathComponent(components.joined(separator: "/"))
    }

    public func exists(_ relativePath: String) -> Bool { FileManager.default.fileExists(atPath: url(for: relativePath).path) }

    /// Contents of a stored file; nil when it is missing, unreadable or a directory.
    public func readData(_ relativePath: String) -> Data? {
        let target = url(for: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return try? Data(contentsOf: target)
    }

    /// Writes atomically (temp file + replace), creating intermediate directories.
    public func writeData(_ data: Data, to relativePath: String) throws {
        guard let name = FileStore.components(of: relativePath).last else {
            throw TunaError.invalidInput("A file path is required")
        }
        let destination = url(for: relativePath)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(name.prefix(64)).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            if rename(temporary.path, destination.path) != 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                              userInfo: [NSLocalizedDescriptionKey: "Could not replace \(relativePath) (errno \(code))"])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Decoded JSON document; nil when the file is missing or does not decode as `T`.
    public func read<T: Decodable>(_ type: T.Type, from relativePath: String) -> T? {
        guard let data = readData(relativePath) else { return nil }
        return try? TunaJSON.makeDecoder().decode(T.self, from: data)
    }

    /// Encodes `value` as JSON (`TunaJSON`) and writes it atomically.
    public func write<T: Encodable>(_ value: T, to relativePath: String) throws {
        try writeData(try TunaJSON.makeEncoder().encode(value), to: relativePath)
    }

    /// Removes a file or directory (recursively). `""` empties the store but keeps `baseURL` itself.
    public func remove(_ relativePath: String) {
        let manager = FileManager.default
        guard !FileStore.components(of: relativePath).isEmpty else {
            for name in (try? manager.contentsOfDirectory(atPath: baseURL.path)) ?? [] {
                try? manager.removeItem(at: baseURL.appendingPathComponent(name))
            }
            return
        }
        try? manager.removeItem(at: url(for: relativePath))
    }

    /// Modification date of a stored file.
    public func modifiedAt(_ relativePath: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: relativePath).path))?[.modificationDate] as? Date
    }

    /// Total size in bytes under a relative directory ("" for everything).
    public func size(of relativeDirectory: String) -> Int64 {
        let manager = FileManager.default
        let root = url(for: relativeDirectory)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return FileStore.fileSize(atPath: root.path) }
        var total: Int64 = 0
        let enumerator = manager.enumerator(atPath: root.path)
        while let relative = enumerator?.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            var entryIsDirectory: ObjCBool = false
            if manager.fileExists(atPath: path, isDirectory: &entryIsDirectory), !entryIsDirectory.boolValue {
                total += FileStore.fileSize(atPath: path)
            }
        }
        return total
    }

    /// Names of the entries (files and directories) directly inside a relative directory, sorted. Hidden entries
    /// (names starting with ".", e.g. in-progress temp files and cache sidecars) are not listed.
    public func list(_ relativeDirectory: String) -> [String] {
        let directory = url(for: relativeDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Helpers

    /// Path components of a relative path without empty, "." and ".." components.
    static func components(of relativePath: String) -> [String] {
        relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." && $0 != ".." }
    }

    static func fileSize(atPath path: String) -> Int64 {
        guard let value = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] else { return 0 }
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? UInt64 { return Int64(clamping: number) }
        return 0
    }
}

/// Cache of raw provider/metadata responses with fetch timestamps, so the app shows cached data instantly
/// and only re-fetches when stale. Keys are logical names, e.g. "providers/<id>/vod_streams.json".
///
/// Layout: the data lives at exactly `files.url(for: key)` (so large entries can be streamed from disk), with a
/// small hidden sidecar next to it (`.<name>.meta.json`: `fetchedAt` + byte count). The sidecar is written after
/// the data; if it is missing or does not match the data, the data file's modification date is used instead.
/// `removeAll(prefix:)` only removes entries written by `store` (recognized by their sidecar), so a `FileStore`
/// shared with `AppStateStore` never loses settings to a "clear cache".
public final class CacheStore: @unchecked Sendable {
    public let files: FileStore
    private let lock = NSLock()

    public init(files: FileStore) { self.files = files }

    public struct Entry: Sendable {
        public var data: Data
        public var fetchedAt: Date
        public init(data: Data, fetchedAt: Date) {
            self.data = data
            self.fetchedAt = fetchedAt
        }
    }

    struct Meta: Codable {
        var fetchedAt: Date
        var byteCount: Int?
    }

    static let metaSuffix = ".meta.json"

    public func entry(_ key: String) -> Entry? {
        guard let fetchedAt = fetchedAt(key), let data = files.readData(key) else { return nil }
        return Entry(data: data, fetchedAt: fetchedAt)
    }

    /// Fresh entry if younger than `maxAge`, else nil.
    /// (A `fetchedAt` in the future counts as fresh only within `maxAge`, so a clock change cannot pin stale data.)
    public func fresh(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Entry? {
        guard let fetchedAt = fetchedAt(key) else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard age < maxAge, age > -maxAge, let data = files.readData(key) else { return nil }
        return Entry(data: data, fetchedAt: fetchedAt)
    }

    /// When the entry for `key` was fetched, without loading its data; nil when there is no entry.
    public func fetchedAt(_ key: String) -> Date? {
        let path = files.url(for: key).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        if let meta = files.read(Meta.self, from: CacheStore.metaPath(for: key)),
           meta.byteCount == nil || Int64(meta.byteCount ?? 0) == FileStore.fileSize(atPath: path) {
            return meta.fetchedAt
        }
        return files.modifiedAt(key) ?? .distantPast
    }

    public func store(_ data: Data, for key: String, fetchedAt: Date = Date()) throws {
        let meta = try TunaJSON.makeEncoder().encode(Meta(fetchedAt: fetchedAt, byteCount: data.count))
        try locked {
            try files.writeData(data, to: key)
            try files.writeData(meta, to: CacheStore.metaPath(for: key))
        }
    }

    public func remove(_ key: String) {
        guard !FileStore.components(of: key).isEmpty else { return }
        locked {
            files.remove(key)
            files.remove(CacheStore.metaPath(for: key))
        }
    }

    /// Removes every entry whose key starts with `prefix` ("" = the whole cache).
    public func removeAll(prefix: String) {
        locked {
            let prefixComponents = FileStore.components(of: prefix)
            let endsWithSlash = prefix.hasSuffix("/") && !prefixComponents.isEmpty
            let normalizedPrefix = prefixComponents.joined(separator: "/") + (endsWithSlash ? "/" : "")
            let walkComponents = endsWithSlash ? prefixComponents : Array(prefixComponents.dropLast())
            let walkRoot = walkComponents.joined(separator: "/")
            let rootPath = files.url(for: walkRoot).path

            var doomed: [(data: String, meta: String)] = []
            let enumerator = FileManager.default.enumerator(atPath: rootPath)
            while let relative = enumerator?.nextObject() as? String {
                var parts = relative.split(separator: "/").map(String.init)
                guard let name = parts.popLast(), name.hasPrefix("."), name.hasSuffix(CacheStore.metaSuffix),
                      name.count > 1 + CacheStore.metaSuffix.count else { continue }
                let dataName = String(name.dropFirst().dropLast(CacheStore.metaSuffix.count))
                let directory = (walkComponents + parts).joined(separator: "/")
                let dataKey = directory.isEmpty ? dataName : "\(directory)/\(dataName)"
                guard dataKey.hasPrefix(normalizedPrefix) else { continue }
                doomed.append((dataKey, directory.isEmpty ? name : "\(directory)/\(name)"))
            }
            for entry in doomed {
                files.remove(entry.data)
                files.remove(entry.meta)
                pruneEmptyDirectories(above: entry.data)
            }
        }
    }

    // MARK: - Helpers

    /// "providers/p/vod.json" → "providers/p/.vod.json.meta.json".
    static func metaPath(for key: String) -> String {
        var components = FileStore.components(of: key)
        let name = components.popLast() ?? ""
        components.append(".\(name)\(metaSuffix)")
        return components.joined(separator: "/")
    }

    /// Removes now-empty parent directories of `key`, bottom-up, never `baseURL` itself.
    private func pruneEmptyDirectories(above key: String) {
        var components = FileStore.components(of: key)
        components.removeLast()
        while !components.isEmpty {
            let path = files.url(for: components.joined(separator: "/")).path
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path), contents.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
            components.removeLast()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
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
///
/// Files: `settings.json`, `providers.json`, `user_state.json`, `governor/<providerID>.json`. Loading never fails:
/// a missing file gives the defaults; a document written by another app version (missing or extra keys) is merged
/// over the defaults key by key; an undecodable provider entry is skipped instead of losing the whole list; a file
/// that cannot be read at all is copied to `<name>.corrupt` (for recovery) before the defaults are returned.
public final class AppStateStore: @unchecked Sendable, GovernorPersistence {
    public let files: FileStore

    public init(files: FileStore) { self.files = files }

    enum Paths {
        static let settings = "settings.json"
        static let providers = "providers.json"
        static let userState = "user_state.json"

        static func governor(_ providerID: ProviderID) -> String { "governor/\(fileName(for: providerID)).json" }

        /// A file-name-safe form of an id; ids that needed changes get a hash suffix so they cannot collide.
        static func fileName(for id: String) -> String {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            var cleaned = String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(80))
            if cleaned == id, !id.isEmpty, !id.hasPrefix(".") { return id }
            // Never hidden (leading dot) and never empty.
            while cleaned.hasPrefix(".") { cleaned.replaceSubrange(cleaned.startIndex ... cleaned.startIndex, with: "_") }
            return "\(cleaned.isEmpty ? "_" : cleaned)-\(TunaHash.fnv1a64Hex(id))"
        }
    }

    public func loadSettings() -> AppSettings { loadDocument(AppSettings.self, from: Paths.settings, defaults: AppSettings()) }
    public func saveSettings(_ settings: AppSettings) { saveDocument(settings, to: Paths.settings) }

    public func loadProviders() -> [ProviderConfig] {
        guard let data = files.readData(Paths.providers) else { return [] }
        let decoder = TunaJSON.makeDecoder()
        if let providers = try? decoder.decode([ProviderConfig].self, from: data) { return providers }
        guard case .array(let elements)? = try? decoder.decode(PersistedJSON.Value.self, from: data) else {
            keepCorruptCopy(data, of: Paths.providers)
            return []
        }
        var providers: [ProviderConfig] = []
        var seen = Set<ProviderID>()
        for element in elements {
            guard case .string(let id)? = element.objectValue?["id"], !id.isEmpty, !seen.contains(id) else { continue }
            let template = ProviderConfig(id: id, name: "", kind: .xtream, serverURL: "")
            guard let provider = PersistedJSON.decode(ProviderConfig.self, stored: element, defaults: template) else { continue }
            providers.append(provider)
            seen.insert(id)
        }
        if providers.count < elements.count { keepCorruptCopy(data, of: Paths.providers) }
        return providers
    }

    public func saveProviders(_ providers: [ProviderConfig]) { saveDocument(providers, to: Paths.providers) }

    public func loadUserState() -> UserState { loadDocument(UserState.self, from: Paths.userState, defaults: UserState()) }
    public func saveUserState(_ state: UserState) { saveDocument(state, to: Paths.userState) }

    // GovernorPersistence
    public func load(providerID: ProviderID) -> GovernorPersistedState? {
        guard let data = files.readData(Paths.governor(providerID)) else { return nil }
        return PersistedJSON.decode(GovernorPersistedState.self, from: data, defaults: GovernorPersistedState())
    }

    public func save(_ state: GovernorPersistedState, providerID: ProviderID) {
        saveDocument(state, to: Paths.governor(providerID))
    }

    // MARK: - Helpers

    private func loadDocument<T: Codable>(_ type: T.Type, from path: String, defaults: T) -> T {
        guard let data = files.readData(path) else { return defaults }
        if let value = PersistedJSON.decode(T.self, from: data, defaults: defaults) { return value }
        keepCorruptCopy(data, of: path)
        return defaults
    }

    private func saveDocument<T: Encodable>(_ value: T, to path: String) {
        do {
            try files.write(value, to: path)
        } catch {
            TunaLog.shared.log("persistence", "Could not save \(path): \(error.localizedDescription)")
        }
    }

    private func keepCorruptCopy(_ data: Data, of path: String) {
        guard !data.isEmpty else { return }
        try? files.writeData(data, to: path + ".corrupt")
        TunaLog.shared.log("persistence", "\(path) could not be read completely; a copy was kept as \(path).corrupt")
    }
}
