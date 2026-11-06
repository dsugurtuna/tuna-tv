import Foundation

/// Disk + memory cache of metadata, keyed by Title id. TTL: details 30 days, misses 7 days, trending 12 h,
/// persons 30 days, seasons 7 days.
///
/// Layout under the `FileStore`: "metadata/titles/<2 hex>.json" (256 shards of `[titleID: MediaMetadata]`, the shard
/// is a stable FNV-1a hash of the title id), "metadata/misses.json", "metadata/seasons.json",
/// "metadata/persons.json", "metadata/trending.json". Everything is loaded on first use; `flush()` writes only what
/// changed (dirty shards/files).
///
/// Details older than the TTL are still returned by `metadata(for:)` / `allMetadata()` (stale artwork beats none);
/// `isFresh(_:now:)` tells the service when to refresh. Seasons and persons past their TTL are not returned.
public actor MetadataStore {
    public init(files: FileStore) { self.files = files }
    private let files: FileStore

    public static let detailsTTL: TimeInterval = 30 * 86_400
    public static let missTTL: TimeInterval = 7 * 86_400
    public static let seasonTTL: TimeInterval = 7 * 86_400
    public static let personTTL: TimeInterval = 30 * 86_400
    public static let trendingTTL: TimeInterval = 12 * 3_600

    static let titlesDirectory = "metadata/titles"
    static let missesPath = "metadata/misses.json"
    static let seasonsPath = "metadata/seasons.json"
    static let personsPath = "metadata/persons.json"
    static let trendingPath = "metadata/trending.json"

    struct SeasonRecord: Codable, Sendable {
        var season: SeasonMetadata
        var fetchedAt: Date
    }

    struct TrendingRecord: Codable, Sendable {
        var ids: [Int]
        var fetchedAt: Date
    }

    private var loaded = false
    private var titles: [String: MediaMetadata] = [:]
    private var shardMembers: [String: Set<String>] = [:]
    private var misses: [String: Date] = [:]
    private var seasons: [String: SeasonRecord] = [:]
    private var persons: [String: PersonDetails] = [:]
    private var trendingRecords: [String: TrendingRecord] = [:]
    private var dirtyShards: Set<String> = []
    private var dirtyMisses = false
    private var dirtySeasons = false
    private var dirtyPersons = false
    private var dirtyTrending = false

    // MARK: - Titles

    public func metadata(for titleID: String) -> MediaMetadata? {
        loadIfNeeded()
        return titles[titleID]
    }

    public func allMetadata() -> [String: MediaMetadata] {
        loadIfNeeded()
        return titles
    }

    public func store(_ metadata: MediaMetadata, for titleID: String) {
        loadIfNeeded()
        titles[titleID] = metadata
        let shard = Self.shard(for: titleID)
        shardMembers[shard, default: []].insert(titleID)
        dirtyShards.insert(shard)
        if misses.removeValue(forKey: titleID) != nil { dirtyMisses = true }
    }

    /// Cached and younger than `detailsTTL`.
    public func isFresh(_ titleID: String, now: Date = Date()) -> Bool {
        loadIfNeeded()
        guard let metadata = titles[titleID] else { return false }
        return now.timeIntervalSince(metadata.fetchedAt) < Self.detailsTTL
    }

    /// Drops one title's metadata (e.g. the user picked a different match).
    public func removeMetadata(for titleID: String) {
        loadIfNeeded()
        guard titles.removeValue(forKey: titleID) != nil else { return }
        let shard = Self.shard(for: titleID)
        shardMembers[shard]?.remove(titleID)
        dirtyShards.insert(shard)
    }

    /// Wipes memory and disk ("Clear metadata cache").
    public func removeAll() {
        for index in 0..<256 { files.remove("\(Self.titlesDirectory)/\(Self.hex(index)).json") }
        for path in [Self.missesPath, Self.seasonsPath, Self.personsPath, Self.trendingPath] { files.remove(path) }
        titles = [:]
        shardMembers = [:]
        misses = [:]
        seasons = [:]
        persons = [:]
        trendingRecords = [:]
        dirtyShards = []
        dirtyMisses = false
        dirtySeasons = false
        dirtyPersons = false
        dirtyTrending = false
        loaded = true
    }

    /// Ids that are neither fresh in the cache nor a recent miss (one hop for a whole batch).
    func idsNeedingFetch(_ ids: [String], now: Date) -> Set<String> {
        loadIfNeeded()
        var result = Set<String>()
        for id in ids {
            if let metadata = titles[id], now.timeIntervalSince(metadata.fetchedAt) < Self.detailsTTL { continue }
            if let missedAt = misses[id], now.timeIntervalSince(missedAt) < Self.missTTL { continue }
            result.insert(id)
        }
        return result
    }

    // MARK: - Misses

    public func markMiss(_ titleID: String) { markMiss(titleID, at: Date()) }

    func markMiss(_ titleID: String, at date: Date) {
        loadIfNeeded()
        misses[titleID] = date
        dirtyMisses = true
    }

    public func isRecentMiss(_ titleID: String, now: Date) -> Bool {
        loadIfNeeded()
        guard let missedAt = misses[titleID] else { return false }
        return now.timeIntervalSince(missedAt) < Self.missTTL
    }

    /// Forget all misses (a new TMDB key can find what the old setup could not).
    public func clearMisses() {
        loadIfNeeded()
        guard !misses.isEmpty else { return }
        misses = [:]
        dirtyMisses = true
    }

    // MARK: - Seasons

    public func season(tvID: Int, season: Int) -> SeasonMetadata? {
        cachedSeason(key: Self.seasonKey(source: .tmdb, showID: tvID, season: season), now: Date(), allowStale: false)
    }

    public func storeSeason(_ season: SeasonMetadata, tvID: Int) {
        storeSeason(season, key: Self.seasonKey(source: .tmdb, showID: tvID, season: season.seasonNumber), at: Date())
    }

    static func seasonKey(source: MetadataSource, showID: Int, season: Int) -> String { "\(source.rawValue):\(showID):\(season)" }

    func cachedSeason(key: String, now: Date, allowStale: Bool) -> SeasonMetadata? {
        loadIfNeeded()
        guard let record = seasons[key] else { return nil }
        guard allowStale || now.timeIntervalSince(record.fetchedAt) < Self.seasonTTL else { return nil }
        return record.season
    }

    func storeSeason(_ season: SeasonMetadata, key: String, at date: Date) {
        loadIfNeeded()
        seasons[key] = SeasonRecord(season: season, fetchedAt: date)
        dirtySeasons = true
    }

    // MARK: - Persons

    public func person(_ id: Int) -> PersonDetails? { cachedPerson(id, now: Date(), allowStale: false) }

    public func storePerson(_ person: PersonDetails) {
        loadIfNeeded()
        persons[String(person.id)] = person
        dirtyPersons = true
    }

    func cachedPerson(_ id: Int, now: Date, allowStale: Bool) -> PersonDetails? {
        loadIfNeeded()
        guard let person = persons[String(id)] else { return nil }
        guard allowStale || now.timeIntervalSince(person.fetchedAt) < Self.personTTL else { return nil }
        return person
    }

    // MARK: - Trending

    /// Last stored trending ids with their fetch date (the caller applies the 12 h TTL).
    public func trending(kind: TitleKind) -> (ids: [Int], fetchedAt: Date)? {
        loadIfNeeded()
        guard let record = trendingRecords[kind.rawValue] else { return nil }
        return (record.ids, record.fetchedAt)
    }

    public func storeTrending(_ ids: [Int], kind: TitleKind, at: Date) {
        loadIfNeeded()
        trendingRecords[kind.rawValue] = TrendingRecord(ids: ids, fetchedAt: at)
        dirtyTrending = true
    }

    // MARK: - Persistence

    /// Flush in-memory changes to disk (debounced by the service).
    public func flush() {
        guard loaded else { return }
        for shard in dirtyShards.sorted() {
            var content: [String: MediaMetadata] = [:]
            for id in shardMembers[shard] ?? [] {
                if let metadata = titles[id] { content[id] = metadata }
            }
            let path = "\(Self.titlesDirectory)/\(shard).json"
            if content.isEmpty {
                files.remove(path)
            } else {
                write(content, to: path)
            }
        }
        dirtyShards = []
        if dirtyMisses {
            write(misses, to: Self.missesPath)
            dirtyMisses = false
        }
        if dirtySeasons {
            write(seasons, to: Self.seasonsPath)
            dirtySeasons = false
        }
        if dirtyPersons {
            write(persons, to: Self.personsPath)
            dirtyPersons = false
        }
        if dirtyTrending {
            write(trendingRecords, to: Self.trendingPath)
            dirtyTrending = false
        }
    }

    /// "00"..."ff" shard of a title id.
    static func shard(for titleID: String) -> String { hex(Int(MetadataSupport.stableHash(titleID) >> 56)) }

    static func hex(_ value: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[(value >> 4) & 0xf], digits[value & 0xf]])
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let now = Date()
        for index in 0..<256 {
            let shard = Self.hex(index)
            guard let content: [String: MediaMetadata] = read("\(Self.titlesDirectory)/\(shard).json") else { continue }
            for (id, metadata) in content {
                // Never let a stale disk copy overwrite something stored before the first load finished.
                if titles[id] == nil { titles[id] = metadata }
                shardMembers[shard, default: []].insert(id)
            }
        }
        if let stored: [String: Date] = read(Self.missesPath) {
            misses = stored.filter { now.timeIntervalSince($0.value) < Self.missTTL }
        }
        if let stored: [String: SeasonRecord] = read(Self.seasonsPath) { seasons = stored }
        if let stored: [String: PersonDetails] = read(Self.personsPath) { persons = stored }
        if let stored: [String: TrendingRecord] = read(Self.trendingPath) { trendingRecords = stored }
    }

    // Own coders (default date strategy) so the format never depends on FileStore's JSON settings.
    private func read<T: Decodable>(_ path: String) -> T? {
        guard let data = files.readData(path) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            TunaLog.shared.log(MetadataSupport.logCategory, "Ignoring unreadable cache file \(path): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to path: String) {
        do {
            try files.writeData(try JSONEncoder().encode(value), to: path)
        } catch {
            TunaLog.shared.log(MetadataSupport.logCategory, "Could not write \(path): \(error)")
        }
    }
}
