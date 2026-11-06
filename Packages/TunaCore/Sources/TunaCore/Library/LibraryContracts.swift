import Foundation

// =====================================================================================================
// LIBRARY CONTRACT (owner: Library). Indexed, immutable snapshot the UI reads; search; ranking; rails;
// guide; insights; demo content. Pure Swift, no networking.
// =====================================================================================================

/// Immutable, indexed snapshot of the curated catalog. Build off the main thread; share freely.
public final class Library: @unchecked Sendable {
    public let generatedAt: Date
    public let movies: [Title]
    public let series: [Title]
    public let channels: [Channel]
    public let stats: CurationStats

    public init(catalog: CuratedCatalog, generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        self.movies = catalog.movies
        self.series = catalog.series
        self.channels = catalog.channels
        self.stats = catalog.stats
        self.index = LibraryIndex(catalog: catalog)
    }

    public static let empty = Library(catalog: CuratedCatalog())

    private let index: LibraryIndex

    public func title(_ id: String) -> Title? { index.title(id) }
    public func channel(_ id: String) -> Channel? { index.channel(id) }
    public func titles(tmdbIDs: [Int], kind: TitleKind?) -> [Title] { index.titles(tmdbIDs: tmdbIDs, kind: kind) }
    /// Variant lookup by `Variant.id` (StreamRef id).
    public func variant(_ id: String) -> (title: Title?, channel: Channel?, variant: Variant)? { index.variant(id) }

    /// Showcase titles of a kind (the main experience).
    public func showcase(_ kind: TitleKind) -> [Title] { index.showcase(kind) }
    /// Showcase channels.
    public var liveShowcase: [Channel] { index.liveShowcase }
    /// Titles on a Vault shelf (adult only when `includeAdult`).
    public func vault(_ shelf: VaultShelf, kind: TitleKind?) -> [Title] { index.vault(shelf, kind: kind) }
    public func vaultChannels(_ shelf: VaultShelf) -> [Channel] { index.vaultChannels(shelf) }
    /// Count per shelf (titles + channels) for the Vault landing page.
    public var vaultCounts: [VaultShelf: Int] { index.vaultCounts }
    /// Other-language content grouped by language code (Vault "Other Languages" with flags).
    public func otherLanguageGroups(kind: TitleKind?) -> [(language: String, titles: [Title])] { index.otherLanguageGroups(kind: kind) }

    public func channels(in category: ChannelCategory) -> [Channel] { index.channels(in: category) }
    public var channelCategories: [(category: ChannelCategory, count: Int)] { index.channelCategories }
    public var channelGroups: [(name: String, channels: [Channel])] { index.channelGroups }

    /// Genre names present in the showcase (provider hints + metadata), with counts.
    public func genres(_ kind: TitleKind, metadata: [String: MediaMetadata]) -> [(genre: String, count: Int)] {
        index.genres(kind, metadata: metadata)
    }

    // MARK: Additive API (owner: Library)

    /// Like `titles(tmdbIDs:kind:)`, but also matches TMDB ids found later through metadata (`MediaMetadata.tmdbID`).
    /// Results follow `tmdbIDs` order; for one id showcase titles come before Vault titles.
    public func titles(tmdbIDs: [Int], kind: TitleKind?, metadata: [String: MediaMetadata]) -> [Title] {
        index.titles(tmdbIDs: tmdbIDs, kind: kind, metadata: metadata)
    }

    /// Every title: movies, then series.
    public var allTitles: [Title] { movies + series }
}

// `LibraryIndex` (internal) lives in LibraryIndex.swift.

// MARK: - Search

public struct SearchHit: Hashable, Sendable, Identifiable {
    public enum Target: Hashable, Sendable {
        case title(String)
        case channel(String)
        case person(id: Int, name: String, profileURL: String?)
        case program(channelID: String, program: Program)
    }
    public var target: Target
    public var score: Double
    /// Display strings.
    public var primary: String
    public var secondary: String
    public var id: String {
        switch target {
        case .title(let id): return "t:\(id)"
        case .channel(let id): return "c:\(id)"
        case .person(let id, _, _): return "p:\(id)"
        case .program(let channelID, let program): return "g:\(channelID):\(program.id)"
        }
    }

    public init(target: Target, score: Double, primary: String, secondary: String) {
        self.target = target
        self.score = score
        self.primary = primary
        self.secondary = secondary
    }
}

/// Instant search over titles (names, original titles, cast, directors, keywords from metadata), channels and
/// current/upcoming programmes. Typo-tolerant prefix matching on folded tokens. < 15 ms for 150k items.
public final class SearchIndex: @unchecked Sendable {
    public init(library: Library, metadata: [String: MediaMetadata], guide: Guide?) {
        engine = SearchEngine(library: library, metadata: metadata, guide: guide, includeAdult: false, now: Date())
    }

    /// Additive: `includeAdult` indexes adult titles/channels (only after the PIN unlock); `now` picks the guide's
    /// current/next programmes and the ranking reference date.
    public init(library: Library, metadata: [String: MediaMetadata], guide: Guide?, includeAdult: Bool, now: Date = Date()) {
        engine = SearchEngine(library: library, metadata: metadata, guide: guide, includeAdult: includeAdult, now: now)
    }

    private let engine: SearchEngine

    /// `scope` nil = everything. Showcase results rank above Vault results.
    public func search(_ query: String, scope: TitleKind? = nil, includeChannels: Bool = true, limit: Int = 60) -> [SearchHit] {
        engine.search(query, scope: scope, includeChannels: includeChannels, limit: limit)
    }
}

// MARK: - Ranking & rails

public enum Ranker {
    /// Bayesian weighted rating: (v/(v+m))·R + (m/(v+m))·C. Defaults m = 500, C = 6.8.
    public static func weightedRating(average: Double, votes: Int, m: Double = 500, c: Double = 6.8) -> Double {
        let v = Double(max(0, votes))
        guard v + m > 0 else { return c }
        return (v / (v + m)) * average + (m / (v + m)) * c
    }
    /// Overall score used for "Top" rails: weighted rating, popularity (log), recency, quality bonus, provider rating.
    /// 0.55·(WR/10) + 0.20·log-popularity + 0.10·recency + 0.10·quality + 0.05·(provider rating/10); without
    /// metadata the provider rating stands in for the weighted rating (see `RankMath`).
    public static func score(_ title: Title, metadata: MediaMetadata?, now: Date) -> Double {
        RankMath.score(title, metadata: metadata, now: now)
    }
}

public enum RailStyle: String, Codable, Sendable, Hashable {
    case hero
    case poster
    case landscape
    case top10
    case continueWatching
    case channels
    case liveNow
    case people
    case collections
}

public enum RailItem: Hashable, Sendable, Identifiable {
    case title(Title)
    case channel(Channel)
    case progress(Title, WatchProgress)
    case live(Channel, Program?)
    case person(CastMember)

    public var id: String {
        switch self {
        case .title(let t): return "t:\(t.id)"
        case .channel(let c): return "c:\(c.id)"
        case .progress(let t, let p): return "p:\(t.id):\(p.episodeRef?.id ?? "")"
        case .live(let c, _): return "l:\(c.id)"
        case .person(let m): return "a:\(m.id)"
        }
    }
}

public struct Rail: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var style: RailStyle
    public var items: [RailItem]
    /// Optional "See all" destination key (e.g. "genre:Action", "world:TR", "top:movie").
    public var seeAllKey: String?

    public init(id: String, title: String, subtitle: String? = nil, style: RailStyle, items: [RailItem], seeAllKey: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.items = items
        self.seeAllKey = seeAllKey
    }
}

public struct RailContext: Sendable {
    public var library: Library
    public var metadata: [String: MediaMetadata]
    public var userState: UserState
    public var preferences: ContentPreferences
    public var trendingMovieIDs: [Int]
    public var trendingSeriesIDs: [Int]
    public var guide: Guide?
    public var now: Date

    public init(library: Library, metadata: [String: MediaMetadata], userState: UserState, preferences: ContentPreferences,
                trendingMovieIDs: [Int] = [], trendingSeriesIDs: [Int] = [], guide: Guide? = nil, now: Date = Date()) {
        self.library = library
        self.metadata = metadata
        self.userState = userState
        self.preferences = preferences
        self.trendingMovieIDs = trendingMovieIDs
        self.trendingSeriesIDs = trendingSeriesIDs
        self.guide = guide
        self.now = now
    }
}

/// Composes Netflix-style rails. Only showcase content; never empty rails; dedupes the hero from rail 1.
public enum RailComposer {
    /// Home: hero (6 featured), Continue Watching, Top 10 Movies, Top 10 Series, Live Now, Trending This Week,
    /// New Arrivals, Ultra HD Showcase, Because You Watched X (×2), Critically Acclaimed, Hidden Gems,
    /// per-world rails ("From Türkiye"), genre rails (top 6 genres), Collections.
    public static func home(_ context: RailContext) -> [Rail] { RailEngine(context).home() }
    /// Movies page / Series page rails (same ideas, kind-filtered, more genres + decades).
    public static func browse(_ kind: TitleKind, _ context: RailContext) -> [Rail] { RailEngine(context).browse(kind) }
    /// "More like this" for a title (TMDB recommendations ∩ catalog, then same genres/keywords).
    public static func similar(to title: Title, _ context: RailContext, limit: Int = 18) -> [Title] {
        RailEngine(context).similar(to: title, limit: limit)
    }
    /// Titles credited to a person (by TMDB credits) available in the catalog.
    public static func titles(for person: PersonDetails, _ context: RailContext) -> [Title] {
        RailEngine(context).titles(for: person)
    }
    /// Sorted, filtered grid contents for "See all" / browse pages.
    public static func grid(_ kind: TitleKind?, filter: BrowseFilter, _ context: RailContext) -> [Title] {
        RailEngine(context).grid(kind, filter: filter)
    }
}

public struct BrowseFilter: Hashable, Sendable {
    public enum Sort: String, Hashable, Sendable, CaseIterable {
        case recommended, topRated, newest, recentlyAdded, alphabetical, popularity
    }
    public var sort: Sort
    public var genre: String?
    /// First year of a decade, e.g. 1990.
    public var decade: Int?
    public var minRating: Double?
    public var country: String?
    public var language: String?
    public var minQuality: Quality?
    public var seeAllKey: String?

    public init(sort: Sort = .recommended, genre: String? = nil, decade: Int? = nil, minRating: Double? = nil,
                country: String? = nil, language: String? = nil, minQuality: Quality? = nil, seeAllKey: String? = nil) {
        self.sort = sort
        self.genre = genre
        self.decade = decade
        self.minRating = minRating
        self.country = country
        self.language = language
        self.minQuality = minQuality
        self.seeAllKey = seeAllKey
    }
}

// MARK: - Guide

/// Programme index for live channels (from XMLTV / short EPG / demo).
public final class Guide: @unchecked Sendable {
    /// Programmes are deduplicated by `Program.id` (the later one wins) and sorted per channel key.
    public init(programs: [Program]) { storage = GuideStorage(programs: programs) }
    public static let empty = Guide(programs: [])
    private let storage: GuideStorage
    public var channelKeys: Set<String> { storage.channelKeys }
    /// The programme airing at `date` (the latest-starting one when programmes overlap).
    public func now(_ channelKey: String, at date: Date) -> Program? { storage.now(channelKey, at: date) }
    /// The first programme starting strictly after `date`.
    public func next(_ channelKey: String, after date: Date) -> Program? { storage.next(channelKey, after: date) }
    /// Programmes overlapping `interval`, by start.
    public func programs(_ channelKey: String, in interval: DateInterval) -> [Program] { storage.programs(channelKey, in: interval) }
    /// Live events happening now across channels (sports matches, breaking news, premieres), best first.
    /// Uses each channel's `epgChannelID` (falling back to `iptvOrgID`); live sports first, then by start.
    public func liveEvents(at date: Date, channels: [Channel]) -> [(channel: Channel, program: Program)] {
        storage.liveEvents(at: date, channels: channels)
    }
    /// A new guide with `programs` added; programmes with the same id replace the existing ones.
    public func merging(_ programs: [Program]) -> Guide { Guide(programs: storage.allPrograms + programs) }
    /// Additive: every programme, grouped by channel key and sorted by start.
    public var allPrograms: [Program] { storage.allPrograms }
}

public enum LiveEventDetector {
    /// Heuristics on title/categories: " vs ", " v ", "LIVE", "Live:", league names, "Final", "Grand Prix", "🔴".
    public static func isLiveEvent(_ program: Program) -> Bool { LiveEventRules.isLiveEvent(program) }
    /// "Football", "Basketball", "American Football", "Ice Hockey", "Baseball", "Motorsport", "Tennis", "Fighting" or nil.
    public static func sportsKind(_ program: Program) -> String? { LiveEventRules.sportsKind(program) }
}

// MARK: - Insights

public struct InsightsReport: Sendable, Hashable {
    public var totalRaw: Int
    public var totalTitles: Int
    public var duplicatesMerged: Int
    public var showcaseShare: Double
    public var qualityBreakdown: [(label: String, count: Int)]
    public var languageBreakdown: [(code: String, count: Int)]
    public var countryBreakdown: [(code: String, count: Int)]
    public var genreBreakdown: [(name: String, count: Int)]
    public var decadeBreakdown: [(decade: Int, count: Int)]
    public var vaultBreakdown: [(shelf: VaultShelf, count: Int)]
    public var metadataCoverage: Double
    public var hoursWatched: Double

    public static func == (lhs: InsightsReport, rhs: InsightsReport) -> Bool {
        lhs.totalRaw == rhs.totalRaw && lhs.totalTitles == rhs.totalTitles && lhs.duplicatesMerged == rhs.duplicatesMerged
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(totalRaw); hasher.combine(totalTitles) }

    public init(totalRaw: Int, totalTitles: Int, duplicatesMerged: Int, showcaseShare: Double,
                qualityBreakdown: [(label: String, count: Int)], languageBreakdown: [(code: String, count: Int)],
                countryBreakdown: [(code: String, count: Int)], genreBreakdown: [(name: String, count: Int)],
                decadeBreakdown: [(decade: Int, count: Int)], vaultBreakdown: [(shelf: VaultShelf, count: Int)],
                metadataCoverage: Double, hoursWatched: Double) {
        self.totalRaw = totalRaw
        self.totalTitles = totalTitles
        self.duplicatesMerged = duplicatesMerged
        self.showcaseShare = showcaseShare
        self.qualityBreakdown = qualityBreakdown
        self.languageBreakdown = languageBreakdown
        self.countryBreakdown = countryBreakdown
        self.genreBreakdown = genreBreakdown
        self.decadeBreakdown = decadeBreakdown
        self.vaultBreakdown = vaultBreakdown
        self.metadataCoverage = metadataCoverage
        self.hoursWatched = hoursWatched
    }

    public static func build(library: Library, metadata: [String: MediaMetadata], userState: UserState) -> InsightsReport {
        InsightsBuilder.build(library: library, metadata: metadata, userState: userState)
    }
}
