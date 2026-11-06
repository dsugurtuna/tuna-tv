import Foundation

// =====================================================================================================
// METADATA CONTRACT (owner: Metadata). TMDB (user's own token), TVMaze (no key), OMDb (optional key),
// iptv-org (no key). NEVER calls the IPTV provider (provider details come from ProviderSession on demand).
// All requests go through `HostLimiter`. Results are cached on disk (FileStore) — TTLs below.
//
// Files: MetadataTMDBClient.swift (TMDBClient), MetadataTVMazeClient.swift (TVMazeClient),
// MetadataOMDbClient.swift (OMDbClient), MetadataIPTVOrgClient.swift (IPTVOrgClient),
// MetadataChannelMatcher.swift (ChannelMatcher), MetadataTitleMatcher.swift (TitleMatcher),
// MetadataStore.swift (MetadataStore), MetadataServiceCore.swift (queue/workers), MetadataSupport.swift (helpers).
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

/// Orchestrates enrichment. Priority queue: `.userInitiated` (detail page) > visible (hero/rails) > background trickle.
/// Background trickle: one title at a time through HostLimiter; pauses while the app is playing video.
public actor MetadataService {
    public init(keys: MetadataKeys, store: MetadataStore, http: HTTPClient, limiter: HostLimiter, files: FileStore) {
        self.impl = MetadataServiceCore(keys: keys, store: store, http: http, limiter: limiter, files: files)
    }

    /// Tuning hooks (worker count, batching delays) for tests.
    init(keys: MetadataKeys, store: MetadataStore, http: HTTPClient, limiter: HostLimiter, files: FileStore,
         options: MetadataServiceCore.Options) {
        self.impl = MetadataServiceCore(keys: keys, store: store, http: http, limiter: limiter, files: files, options: options)
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

    /// Writes pending cache changes to disk now (store writes are otherwise debounced by a few seconds).
    public func flush() async { await impl.flush() }

    /// Returns when the queue has no running work (tests).
    func waitForIdle() async { await impl.waitForIdle() }
}
