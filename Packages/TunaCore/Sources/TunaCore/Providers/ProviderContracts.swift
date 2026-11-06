import Foundation

// =====================================================================================================
// PROVIDERS CONTRACT (owner: Providers). Talks Xtream Codes / M3U / XMLTV. EVERY network call goes through
// the provider's `RequestGovernor` (never a raw URLSession). Sync is serial, cache-first and rare.
// =====================================================================================================

/// Builds Xtream URLs. Pure functions, no I/O.
public enum XtreamURLBuilder {
    /// Normalizes user input: trims, adds "http://" if missing, strips trailing "/", "player_api.php", "get.php",
    /// "xmltv.php", "panel_api.php" and query strings, KEEPS any sub-path ("http://host:8080/sub").
    public static func normalizeServer(_ input: String) -> String? { fatalError("TODO(providers)") }

    /// Parses a pasted full link ("http://host:8080/get.php?username=u&password=p&type=m3u_plus" or
    /// ".../player_api.php?username=u&password=p") into (server, username, password).
    public static func parseFullLink(_ input: String) -> (server: String, username: String, password: String)? { fatalError("TODO(providers)") }

    /// player_api.php URL; `action` nil = account info. Credentials percent-encoded.
    public static func apiURL(server: String, username: String, password: String, action: String?, params: [String: String] = [:]) -> URL? { fatalError("TODO(providers)") }

    public static func xmltvURL(server: String, username: String, password: String) -> URL? { fatalError("TODO(providers)") }

    /// /live/u/p/<id>.<ts|m3u8>
    public static func liveURL(server: String, username: String, password: String, streamID: String, format: String) -> URL? { fatalError("TODO(providers)") }

    /// /movie/u/p/<id>.<ext>
    public static func movieURL(server: String, username: String, password: String, streamID: String, ext: String) -> URL? { fatalError("TODO(providers)") }

    /// /series/u/p/<episodeID>.<ext>
    public static func episodeURL(server: String, username: String, password: String, episodeID: String, ext: String) -> URL? { fatalError("TODO(providers)") }

    /// /timeshift/u/p/<durationMinutes>/<yyyy-MM-dd:HH-mm in server timezone>/<id>.ts
    public static func catchupURL(server: String, username: String, password: String, streamID: String, start: Date,
                                  durationMinutes: Int, serverTimeZone: TimeZone) -> URL? { fatalError("TODO(providers)") }
}

/// Tolerant decoding of Xtream JSON (numbers as strings, nulls, `false` for empty, dict-or-array episodes,
/// base64 EPG titles). Pure functions over `Data`.
public enum XtreamDecoder {
    public static func account(_ data: Data) throws -> AccountInfo { fatalError("TODO(providers)") }
    public static func categories(_ data: Data, kind: StreamKind) throws -> [RawCategory] { fatalError("TODO(providers)") }
    /// `get_live_streams` / `get_vod_streams` / `get_series` rows -> RawItem (kind .live / .movie / .series).
    public static func items(_ data: Data, kind: StreamKind, providerID: ProviderID, categories: [String: String]) throws -> [RawItem] { fatalError("TODO(providers)") }
    public static func vodInfo(_ data: Data) throws -> RawItemInfo { fatalError("TODO(providers)") }
    public static func seriesInfo(_ data: Data, seriesRef: StreamRef) throws -> RawSeriesInfo { fatalError("TODO(providers)") }
    /// `get_short_epg` / `get_simple_data_table` -> programmes (titles/descriptions base64-decoded).
    public static func shortEPG(_ data: Data, channelKey: String) throws -> [Program] { fatalError("TODO(providers)") }
}

/// One `#EXTINF` entry.
public struct M3UEntry: Hashable, Sendable {
    public var name: String
    public var url: String
    public var attributes: [String: String]
    public var groupTitle: String?
    public var duration: Int
    public var userAgent: String?
    public var referrer: String?

    public init(name: String, url: String, attributes: [String: String] = [:], groupTitle: String? = nil, duration: Int = -1,
                userAgent: String? = nil, referrer: String? = nil) {
        self.name = name
        self.url = url
        self.attributes = attributes
        self.groupTitle = groupTitle
        self.duration = duration
        self.userAgent = userAgent
        self.referrer = referrer
    }
}

public struct M3UPlaylist: Sendable {
    public var entries: [M3UEntry]
    /// `url-tvg` / `x-tvg-url` from the `#EXTM3U` header.
    public var guideURLs: [String]

    public init(entries: [M3UEntry] = [], guideURLs: [String] = []) {
        self.entries = entries
        self.guideURLs = guideURLs
    }
}

public enum M3UParser {
    /// Handles BOM, CRLF, quoted attributes with commas, `#EXTGRP`, `#EXTVLCOPT`, `#KODIPROP`, very long lines.
    public static func parse(_ data: Data) -> M3UPlaylist { fatalError("TODO(providers)") }

    /// Classifies entries into live / movie / series (Xtream-style URL paths `/movie/`, `/series/`, extensions,
    /// group names) and converts them to a catalog. Stream ids are stable hashes of the URL.
    public static func catalog(from playlist: M3UPlaylist, providerID: ProviderID) -> ProviderCatalog { fatalError("TODO(providers)") }
}

public enum XMLTVParser {
    /// Streaming parse (XMLParser SAX). Keeps only programmes whose channel is in `channels` (nil = all) and that
    /// overlap `window`. Handles `+0300` offsets and gzip-free input (the app gunzips first if needed).
    public static func parse(_ data: Data, channels: Set<String>?, window: DateInterval) -> [Program] { fatalError("TODO(providers)") }

    /// Same, reading from a file URL in chunks (large guides).
    public static func parse(fileURL: URL, channels: Set<String>?, window: DateInterval) -> [Program] { fatalError("TODO(providers)") }
}

public enum SyncStage: String, Codable, Sendable, CaseIterable {
    case checkingAccount
    case liveCategories
    case movieCategories
    case seriesCategories
    case liveChannels
    case movies
    case series
    case playlist
    case guide
    case curating
    case done
}

public struct SyncProgress: Sendable, Hashable {
    public var providerID: ProviderID
    public var stage: SyncStage
    public var message: String
    /// Items loaded so far per kind (raw values of StreamKind).
    public var counts: [String: Int]
    /// 0...1 over the whole sync.
    public var fraction: Double
    /// Seconds until the next request is allowed (pacing), to show the Provider Shield countdown.
    public var nextRequestIn: TimeInterval?

    public init(providerID: ProviderID, stage: SyncStage, message: String, counts: [String: Int] = [:], fraction: Double, nextRequestIn: TimeInterval? = nil) {
        self.providerID = providerID
        self.stage = stage
        self.message = message
        self.counts = counts
        self.fraction = fraction
        self.nextRequestIn = nextRequestIn
    }
}

/// Everything the app does with ONE provider. Cache-first; all requests via `governor`.
/// TTLs: account 10 min (checked lazily), categories+lists `config.syncInterval` (24 h default),
/// vod_info 14 days, series_info 3 days, short EPG 10 min, XMLTV 24 h.
/// Sync order (strictly sequential): account -> live cats -> vod cats -> series cats -> live -> vod -> series.
/// An empty or failed section NEVER wipes the cached one.
public actor ProviderSession {
    public let config: ProviderConfig
    public let governor: RequestGovernor

    public init(config: ProviderConfig, password: String, governor: RequestGovernor, cache: CacheStore, clock: TunaClock = SystemClock()) {
        self.config = config
        self.governor = governor
        self.impl = ProviderSessionCore(config: config, password: password, governor: governor, cache: cache, clock: clock)
    }

    private let impl: ProviderSessionCore

    /// One request: validates credentials and returns account info (Xtream). M3U: fetches the playlist head.
    public func validate() async throws -> AccountInfo { try await impl.validate() }

    /// Cached account info (refreshes at most every 10 min when `refresh` is true).
    public func account(refresh: Bool = false) async throws -> AccountInfo? { try await impl.account(refresh: refresh) }

    /// The last synced catalog from disk, without any network.
    public func cachedCatalog() async -> ProviderCatalog? { await impl.cachedCatalog() }

    /// Whether `sync(force: false)` would contact the provider.
    public func isStale() async -> Bool { await impl.isStale() }

    /// Runs a (rare) sequential sync. With `force == false` only stale sections are fetched.
    public func sync(force: Bool, progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> ProviderCatalog {
        try await impl.sync(force: force, progress: progress)
    }

    /// User opened a movie: provider details (cached 14 days).
    public func vodInfo(_ ref: StreamRef) async throws -> RawItemInfo { try await impl.vodInfo(ref) }

    /// User opened a series: seasons + episodes (cached 3 days).
    public func seriesInfo(_ ref: StreamRef) async throws -> RawSeriesInfo { try await impl.seriesInfo(ref) }

    /// Short EPG for ONE channel (the one being watched), cached 10 min. Never call this per list row.
    public func shortEPG(_ ref: StreamRef, channelKey: String) async throws -> [Program] { try await impl.shortEPG(ref, channelKey: channelKey) }

    /// Downloads the full XMLTV guide at most once per 24 h (one request) and returns programmes in `window`
    /// for `channels`. Returns cached data when fresh.
    public func guide(channels: Set<String>, window: DateInterval, force: Bool = false) async throws -> [Program] {
        try await impl.guide(channels: channels, window: window, force: force)
    }

    /// Playable URL for a live channel / movie / episode (no network).
    public func streamURL(for ref: StreamRef, containerExtension: String?, directURL: String?) async -> URL? {
        await impl.streamURL(for: ref, containerExtension: containerExtension, directURL: directURL)
    }

    /// Catch-up URL for a programme on a channel with archive.
    public func catchupURL(for ref: StreamRef, program: Program) async -> URL? { await impl.catchupURL(for: ref, program: program) }

    /// HTTP headers to send with stream requests (User-Agent etc.).
    public func streamHeaders(for item: RawItem?) async -> [String: String] { await impl.streamHeaders(for: item) }
}

// MARK: - Implementation shell (owner: Providers). Replace the bodies; keep the signatures.

final class ProviderSessionCore: @unchecked Sendable {
    init(config: ProviderConfig, password: String, governor: RequestGovernor, cache: CacheStore, clock: TunaClock) {
        fatalError("TODO(providers): implement ProviderSessionCore")
    }
    func validate() async throws -> AccountInfo { fatalError("TODO(providers)") }
    func account(refresh: Bool) async throws -> AccountInfo? { fatalError("TODO(providers)") }
    func cachedCatalog() async -> ProviderCatalog? { fatalError("TODO(providers)") }
    func isStale() async -> Bool { fatalError("TODO(providers)") }
    func sync(force: Bool, progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> ProviderCatalog { fatalError("TODO(providers)") }
    func vodInfo(_ ref: StreamRef) async throws -> RawItemInfo { fatalError("TODO(providers)") }
    func seriesInfo(_ ref: StreamRef) async throws -> RawSeriesInfo { fatalError("TODO(providers)") }
    func shortEPG(_ ref: StreamRef, channelKey: String) async throws -> [Program] { fatalError("TODO(providers)") }
    func guide(channels: Set<String>, window: DateInterval, force: Bool) async throws -> [Program] { fatalError("TODO(providers)") }
    func streamURL(for ref: StreamRef, containerExtension: String?, directURL: String?) async -> URL? { fatalError("TODO(providers)") }
    func catchupURL(for ref: StreamRef, program: Program) async -> URL? { fatalError("TODO(providers)") }
    func streamHeaders(for item: RawItem?) async -> [String: String] { fatalError("TODO(providers)") }
}
