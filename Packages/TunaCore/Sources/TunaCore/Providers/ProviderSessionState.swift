import Foundation

/// The Xtream sections of a catalog sync, in the exact order they are requested (strictly one after the other).
enum XtreamSyncSection: String, CaseIterable, Sendable {
    case account
    case liveCategories = "live_categories"
    case vodCategories = "vod_categories"
    case seriesCategories = "series_categories"
    case liveStreams = "live_streams"
    case vodStreams = "vod_streams"
    case series

    /// The list sections (everything but the account), in request order. ONE request each, never per category.
    static let lists: [XtreamSyncSection] = [.liveCategories, .vodCategories, .seriesCategories, .liveStreams, .vodStreams, .series]

    var action: String? {
        switch self {
        case .account: return nil
        case .liveCategories: return "get_live_categories"
        case .vodCategories: return "get_vod_categories"
        case .seriesCategories: return "get_series_categories"
        case .liveStreams: return "get_live_streams"
        case .vodStreams: return "get_vod_streams"
        case .series: return "get_series"
        }
    }

    var stage: SyncStage {
        switch self {
        case .account: return .checkingAccount
        case .liveCategories: return .liveCategories
        case .vodCategories: return .movieCategories
        case .seriesCategories: return .seriesCategories
        case .liveStreams: return .liveChannels
        case .vodStreams: return .movies
        case .series: return .series
        }
    }

    /// Share of the whole sync, for `SyncProgress.fraction` (the big lists dominate).
    var weight: Double {
        switch self {
        case .account, .liveCategories, .vodCategories, .seriesCategories: return 0.05
        case .liveStreams: return 0.2
        case .vodStreams, .series: return 0.3
        }
    }

    var kind: StreamKind {
        switch self {
        case .account, .liveCategories, .liveStreams: return .live
        case .vodCategories, .vodStreams: return .movie
        case .seriesCategories, .series: return .series
        }
    }

    var isCategoryList: Bool { self == .liveCategories || self == .vodCategories || self == .seriesCategories }

    var label: String {
        switch self {
        case .account: return "account"
        case .liveCategories: return "live TV categories"
        case .vodCategories: return "movie categories"
        case .seriesCategories: return "series categories"
        case .liveStreams: return "live channels"
        case .vodStreams: return "movies"
        case .series: return "series"
        }
    }

    static func categories(for kind: StreamKind) -> XtreamSyncSection {
        switch kind {
        case .live: return .liveCategories
        case .movie: return .vodCategories
        case .series, .episode: return .seriesCategories
        }
    }

    static func items(for kind: StreamKind) -> XtreamSyncSection {
        switch kind {
        case .live: return .liveStreams
        case .movie: return .vodStreams
        case .series, .episode: return .series
        }
    }
}

/// `CacheStore` keys of one provider: "providers/<id>/<section>.json" and friends.
struct ProviderCacheKeys: Sendable {
    let prefix: String

    init(providerID: ProviderID) {
        prefix = "providers/\(ProviderCacheKeys.safe(providerID))/"
    }

    func section(_ section: XtreamSyncSection) -> String { prefix + section.rawValue + ".json" }
    /// Written when a list came back empty and the saved (non-empty) one was kept: counts as "checked".
    func checked(_ section: XtreamSyncSection) -> String { prefix + section.rawValue + ".checked.json" }
    var playlist: String { prefix + "playlist.m3u" }
    var playlistChecked: String { prefix + "playlist.checked.json" }
    var guide: String { prefix + "guide.xml" }
    var guideFailure: String { prefix + "guide.failure.txt" }
    func vodInfo(_ id: String) -> String { prefix + "vod_info/" + ProviderCacheKeys.safe(id) + ".json" }
    func seriesInfo(_ id: String) -> String { prefix + "series_info/" + ProviderCacheKeys.safe(id) + ".json" }
    func shortEPG(_ id: String) -> String { prefix + "short_epg/" + ProviderCacheKeys.safe(id) + ".json" }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// A path-safe, collision-free key component (percent-encoding of everything but [A-Za-z0-9_-]).
    static func safe(_ raw: String) -> String {
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
        return encoded.isEmpty ? "_" : encoded
    }
}

struct ProviderMemo<Value: Sendable>: Sendable {
    var date: Date
    var value: Value
    /// Increases every time the memo is replaced (dates can repeat).
    var version = 0
}

struct ProviderItemsMemo: Sendable {
    var date: Date
    /// Version of the category memo whose names were applied to `items`.
    var namesVersion: Int?
    var items: [RawItem]
}

struct ProviderGuideMemo: Sendable {
    var fetchedAt: Date
    var channels: Set<String>
    var window: DateInterval
    var programs: [Program]
}

/// Mutable state of one `ProviderSessionCore`: single-flight sync and requests, failure cooldowns and decoded
/// copies of cached sections (so a 30 MB list is decoded once per launch, not per call).
actor ProviderSessionState {
    // MARK: Single-flight sync

    private var syncTask: Task<ProviderCatalog, Error>?
    private var syncGeneration = 0
    private var listeners: [@Sendable (SyncProgress) -> Void] = []

    /// Joins the running sync (its listener is added) or starts one with `start(generation)`.
    func joinSync(listener: @escaping @Sendable (SyncProgress) -> Void,
                  start: @Sendable (Int) -> Task<ProviderCatalog, Error>) -> Task<ProviderCatalog, Error> {
        listeners.append(listener)
        if let syncTask { return syncTask }
        syncGeneration += 1
        let task = start(syncGeneration)
        syncTask = task
        return task
    }

    func emit(_ progress: SyncProgress) {
        for listener in listeners { listener(progress) }
    }

    func endSync(generation: Int) {
        guard generation == syncGeneration else { return }
        syncTask = nil
        listeners = []
    }

    // MARK: Single-flight requests (details, account)

    private var fetches: [String: Task<HTTPResponse, Error>] = [:]

    func sharedFetch(key: String, start: @Sendable () -> Task<HTTPResponse, Error>) -> Task<HTTPResponse, Error> {
        if let running = fetches[key] { return running }
        let task = start()
        fetches[key] = task
        return task
    }

    func endFetch(key: String) {
        fetches[key] = nil
    }

    // MARK: Failure cooldowns (no hammering after an error)

    private var cooldowns: [String: (until: Date, error: TunaError)] = [:]

    func cooldownError(for key: String, now: Date) -> TunaError? {
        guard let entry = cooldowns[key] else { return nil }
        if entry.until <= now {
            cooldowns[key] = nil
            return nil
        }
        return entry.error
    }

    func setCooldown(for key: String, until: Date, error: TunaError) {
        cooldowns[key] = (until, error)
    }

    // MARK: Decoded sections

    private var categoryMemos: [StreamKind: ProviderMemo<[RawCategory]>] = [:]
    private var itemMemos: [StreamKind: ProviderItemsMemo] = [:]
    private var playlistMemo: ProviderMemo<M3UParsingKit.Classification>?
    private var guideMemo: ProviderGuideMemo?

    func categories(_ kind: StreamKind) -> ProviderMemo<[RawCategory]>? { categoryMemos[kind] }
    private var categoryVersion = 0
    func setCategories(_ kind: StreamKind, _ memo: ProviderMemo<[RawCategory]>) -> ProviderMemo<[RawCategory]> {
        categoryVersion += 1
        var versioned = memo
        versioned.version = categoryVersion
        categoryMemos[kind] = versioned
        return versioned
    }
    func items(_ kind: StreamKind) -> ProviderItemsMemo? { itemMemos[kind] }
    func setItems(_ kind: StreamKind, _ memo: ProviderItemsMemo) { itemMemos[kind] = memo }
    func playlist() -> ProviderMemo<M3UParsingKit.Classification>? { playlistMemo }
    func setPlaylist(_ memo: ProviderMemo<M3UParsingKit.Classification>) { playlistMemo = memo }
    func guide() -> ProviderGuideMemo? { guideMemo }
    func setGuide(_ memo: ProviderGuideMemo) { guideMemo = memo }
}
