import Foundation

// =====================================================================================================
// METADATA CONTRACT (owner: Metadata). TMDB (user's own token), TVMaze (no key), OMDb (optional key),
// iptv-org (no key). NEVER calls the IPTV provider (provider details come from ProviderSession on demand).
// All requests go through `HostLimiter`. Results are cached on disk (FileStore) — TTLs below.
// =====================================================================================================

public struct MetadataKeys: Sendable, Hashable {
    /// TMDB v4 "API Read Access Token" (Bearer) or v3 API key (32 hex chars) — both accepted.
    public var tmdb: String?
    public var omdb: String?
    /// ISO 639-1 + region for TMDB `language`, e.g. "en-US", "tr-TR".
    public var language: String

    public init(tmdb: String? = nil, omdb: String? = nil, language: String = "en-US") {
        self.tmdb = tmdb?.nonEmpty
        self.omdb = omdb?.nonEmpty
        self.language = language
    }

    public var hasTMDB: Bool { tmdb != nil }
}

/// TMDB v3 client. Image URLs are returned as full URLs (poster w500, backdrop w1280, profile w185, logo w500,
/// still w300). `append_to_response` is used so one detail call returns everything.
public struct TMDBClient: Sendable {
    public init(keys: MetadataKeys, http: HTTPClient, limiter: HostLimiter) { fatalError("TODO(metadata)") }

    public struct SearchResult: Codable, Hashable, Sendable {
        public var id: Int
        public var title: String
        public var originalTitle: String?
        public var year: Int?
        public var popularity: Double
        public var voteCount: Int
        public var originalLanguage: String?
        public init(id: Int, title: String, originalTitle: String?, year: Int?, popularity: Double, voteCount: Int, originalLanguage: String?) {
            self.id = id
            self.title = title
            self.originalTitle = originalTitle
            self.year = year
            self.popularity = popularity
            self.voteCount = voteCount
            self.originalLanguage = originalLanguage
        }
    }

    public func search(_ query: String, kind: TitleKind, year: Int?) async throws -> [SearchResult] { fatalError("TODO(metadata)") }
    /// movie/{id} or tv/{id} with credits/aggregate_credits, videos, images (logos), release_dates/content_ratings,
    /// keywords, recommendations, similar, external_ids.
    public func details(id: Int, kind: TitleKind) async throws -> MediaMetadata { fatalError("TODO(metadata)") }
    public func season(tvID: Int, season: Int) async throws -> SeasonMetadata { fatalError("TODO(metadata)") }
    public func person(id: Int) async throws -> PersonDetails { fatalError("TODO(metadata)") }
    /// trending/{movie|tv}/{day|week} ids, in rank order.
    public func trending(kind: TitleKind, window: String) async throws -> [Int] { fatalError("TODO(metadata)") }
    /// tv/{id}/external_ids or find by IMDb id helpers if needed.
    public func find(imdbID: String) async throws -> (kind: TitleKind, id: Int)? { fatalError("TODO(metadata)") }
}

/// TVMaze (no key) for series when TMDB is not configured.
public struct TVMazeClient: Sendable {
    public init(http: HTTPClient, limiter: HostLimiter) { fatalError("TODO(metadata)") }
    /// singlesearch/shows?q=&embed[]=cast&embed[]=seasons&embed[]=images -> metadata.
    public func show(named name: String, year: Int?) async throws -> MediaMetadata? { fatalError("TODO(metadata)") }
    public func episodes(showID: Int) async throws -> [SeasonMetadata] { fatalError("TODO(metadata)") }
}

/// OMDb (optional key): IMDb rating/votes, Rotten Tomatoes, Metacritic, awards, box office.
public struct OMDbClient: Sendable {
    public init(apiKey: String, http: HTTPClient, limiter: HostLimiter) { fatalError("TODO(metadata)") }
    public func ratings(imdbID: String) async throws -> (imdb: Double?, votes: Int?, rottenTomatoes: Int?, metacritic: Int?, awards: String?, boxOffice: String?) {
        fatalError("TODO(metadata)")
    }
}

/// iptv-org public API (https://iptv-org.github.io/api/channels.json, logos.json, ...). Downloaded at most weekly,
/// slimmed to `IPTVOrgChannel`, cached on disk.
public struct IPTVOrgClient: Sendable {
    public init(http: HTTPClient, limiter: HostLimiter, files: FileStore) { fatalError("TODO(metadata)") }
    public func channels(maxAge: TimeInterval) async throws -> [IPTVOrgChannel] { fatalError("TODO(metadata)") }
}

/// Matches provider channels to iptv-org channels (name/alt-names/country scoring).
public struct ChannelMatcher: Sendable {
    public init(channels: [IPTVOrgChannel]) { fatalError("TODO(metadata)") }
    /// Best match for a cleaned channel name + countries, or nil below the confidence threshold.
    public func match(name: String, countries: [String], epgID: String?) -> IPTVOrgChannel? { fatalError("TODO(metadata)") }
}

/// Picks the TMDB/TVMaze candidate for a curated title. Pure, unit-tested.
public enum TitleMatcher {
    /// 0...1 confidence. Uses normalized similarity (TitleKey), original title, year delta (±1 tolerated),
    /// popularity / vote count as tiebreak.
    public static func score(title: String, year: Int?, candidate: TMDBClient.SearchResult) -> Double { fatalError("TODO(metadata)") }
    /// Best candidate with score >= threshold (default 0.72), else nil.
    public static func best(title: String, year: Int?, candidates: [TMDBClient.SearchResult], threshold: Double = 0.72) -> TMDBClient.SearchResult? {
        fatalError("TODO(metadata)")
    }
}

/// Disk + memory cache of metadata, keyed by Title id. TTL: details 30 days, misses 7 days, trending 12 h,
/// persons 30 days, seasons 7 days.
public actor MetadataStore {
    public init(files: FileStore) { self.files = files }
    private let files: FileStore

    public func metadata(for titleID: String) -> MediaMetadata? { fatalError("TODO(metadata)") }
    public func allMetadata() -> [String: MediaMetadata] { fatalError("TODO(metadata)") }
    public func store(_ metadata: MediaMetadata, for titleID: String) { fatalError("TODO(metadata)") }
    public func markMiss(_ titleID: String) { fatalError("TODO(metadata)") }
    public func isRecentMiss(_ titleID: String, now: Date) -> Bool { fatalError("TODO(metadata)") }
    public func season(tvID: Int, season: Int) -> SeasonMetadata? { fatalError("TODO(metadata)") }
    public func storeSeason(_ season: SeasonMetadata, tvID: Int) { fatalError("TODO(metadata)") }
    public func person(_ id: Int) -> PersonDetails? { fatalError("TODO(metadata)") }
    public func storePerson(_ person: PersonDetails) { fatalError("TODO(metadata)") }
    public func trending(kind: TitleKind) -> (ids: [Int], fetchedAt: Date)? { fatalError("TODO(metadata)") }
    public func storeTrending(_ ids: [Int], kind: TitleKind, at: Date) { fatalError("TODO(metadata)") }
    /// Flush in-memory changes to disk (debounced by the service).
    public func flush() { fatalError("TODO(metadata)") }
}

/// Orchestrates enrichment. Priority queue: `.userInitiated` (detail page) > visible (hero/rails) > background trickle.
/// Background trickle: one title at a time through HostLimiter; pauses while the app is playing video.
public actor MetadataService {
    public init(keys: MetadataKeys, store: MetadataStore, http: HTTPClient, limiter: HostLimiter, files: FileStore) {
        self.impl = MetadataServiceCore(keys: keys, store: store, http: http, limiter: limiter, files: files)
    }

    private let impl: MetadataServiceCore

    public func updateKeys(_ keys: MetadataKeys) async { await impl.updateKeys(keys) }

    /// Cached metadata or a fetch now (user is waiting). Falls back to TVMaze for series without TMDB.
    public func metadata(for title: Title) async -> MediaMetadata? { await impl.metadata(for: title) }

    /// Queue titles for enrichment; earlier ones first. Already-cached titles are skipped.
    public func enqueue(_ titles: [Title], priority: RequestPriority) async { await impl.enqueue(titles, priority: priority) }

    /// Stream of batches of title ids whose metadata changed (debounced ~1 s).
    public func updates() async -> AsyncStream<[String]> { await impl.updates() }

    public func season(for title: Title, tvID: Int, season: Int) async -> SeasonMetadata? { await impl.season(for: title, tvID: tvID, season: season) }
    public func person(id: Int) async -> PersonDetails? { await impl.person(id: id) }
    /// TMDB trending ids (cached 12 h), empty without a TMDB key.
    public func trendingIDs(kind: TitleKind) async -> [Int] { await impl.trendingIDs(kind: kind) }
    /// iptv-org channel index (weekly) for live enrichment.
    public func channelMatcher() async -> ChannelMatcher? { await impl.channelMatcher() }
    public func setPaused(_ paused: Bool) async { await impl.setPaused(paused) }
}

final class MetadataServiceCore: @unchecked Sendable {
    init(keys: MetadataKeys, store: MetadataStore, http: HTTPClient, limiter: HostLimiter, files: FileStore) { fatalError("TODO(metadata)") }
    func updateKeys(_ keys: MetadataKeys) async { fatalError("TODO(metadata)") }
    func metadata(for title: Title) async -> MediaMetadata? { fatalError("TODO(metadata)") }
    func enqueue(_ titles: [Title], priority: RequestPriority) async { fatalError("TODO(metadata)") }
    func updates() async -> AsyncStream<[String]> { fatalError("TODO(metadata)") }
    func season(for title: Title, tvID: Int, season: Int) async -> SeasonMetadata? { fatalError("TODO(metadata)") }
    func person(id: Int) async -> PersonDetails? { fatalError("TODO(metadata)") }
    func trendingIDs(kind: TitleKind) async -> [Int] { fatalError("TODO(metadata)") }
    func channelMatcher() async -> ChannelMatcher? { fatalError("TODO(metadata)") }
    func setPaused(_ paused: Bool) async { fatalError("TODO(metadata)") }
}
