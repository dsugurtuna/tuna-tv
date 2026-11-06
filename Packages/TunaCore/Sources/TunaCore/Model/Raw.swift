import Foundation

/// A provider category (Xtream `get_*_categories`, or an M3U `group-title`).
public struct RawCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: StreamKind
    public var parentID: String?

    public init(id: String, name: String, kind: StreamKind, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
    }
}

/// One record exactly as the provider listed it (normalized types, nothing curated yet).
/// Built from Xtream `get_live_streams` / `get_vod_streams` / `get_series` rows or M3U entries.
public struct RawItem: Codable, Hashable, Sendable, Identifiable {
    public var ref: StreamRef
    public var id: String { ref.id }

    /// The raw display name, garbage included (e.g. "EN| The Matrix (1999) 4K").
    public var name: String
    public var categoryID: String?
    /// Resolved category name (raw, e.g. "EN | MOVIES 4K").
    public var categoryName: String?
    /// Poster / channel logo URL from the provider (`stream_icon`, `cover`, `tvg-logo`).
    public var iconURL: String?
    /// When the provider added it (`added`, `last_modified`).
    public var addedAt: Date?
    /// Provider rating normalized to 0...10 (`rating`, or `rating_5based` * 2).
    public var providerRating: Double?
    /// TMDB id when the provider supplies one (`tmdb`, `tmdb_id`).
    public var tmdbID: Int?
    public var imdbID: String?
    /// Year when the provider supplies one (`year`, `releaseDate`).
    public var year: Int?
    /// Container extension for movies (`container_extension`, e.g. "mkv").
    public var containerExtension: String?
    /// A direct stream URL (M3U entries). Xtream URLs are built on demand by `XtreamURLBuilder`.
    public var directURL: String?

    // Live channel fields
    public var channelNumber: Int?
    public var epgChannelID: String?
    /// Catch-up days if the provider supports archive for this channel (`tv_archive` == 1).
    public var catchupDays: Int?
    public var tvgCountry: String?
    public var tvgLanguage: String?

    // Extra fields that list endpoints already return (free metadata, no extra request).
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var releaseDate: String?
    public var backdropURLs: [String]
    public var trailerYouTubeID: String?
    public var episodeRunTimeMinutes: Int?

    /// Per-entry User-Agent (M3U `#EXTVLCOPT:http-user-agent`), if any.
    public var userAgentOverride: String?
    public var referrerOverride: String?

    public init(
        ref: StreamRef,
        name: String,
        categoryID: String? = nil,
        categoryName: String? = nil,
        iconURL: String? = nil,
        addedAt: Date? = nil,
        providerRating: Double? = nil,
        tmdbID: Int? = nil,
        imdbID: String? = nil,
        year: Int? = nil,
        containerExtension: String? = nil,
        directURL: String? = nil,
        channelNumber: Int? = nil,
        epgChannelID: String? = nil,
        catchupDays: Int? = nil,
        tvgCountry: String? = nil,
        tvgLanguage: String? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        releaseDate: String? = nil,
        backdropURLs: [String] = [],
        trailerYouTubeID: String? = nil,
        episodeRunTimeMinutes: Int? = nil,
        userAgentOverride: String? = nil,
        referrerOverride: String? = nil
    ) {
        self.ref = ref
        self.name = name
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.iconURL = iconURL
        self.addedAt = addedAt
        self.providerRating = providerRating
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.year = year
        self.containerExtension = containerExtension
        self.directURL = directURL
        self.channelNumber = channelNumber
        self.epgChannelID = epgChannelID
        self.catchupDays = catchupDays
        self.tvgCountry = tvgCountry
        self.tvgLanguage = tvgLanguage
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.releaseDate = releaseDate
        self.backdropURLs = backdropURLs
        self.trailerYouTubeID = trailerYouTubeID
        self.episodeRunTimeMinutes = episodeRunTimeMinutes
        self.userAgentOverride = userAgentOverride
        self.referrerOverride = referrerOverride
    }
}

/// Technical stream facts a provider reports in `get_vod_info` / episode `info`.
public struct StreamTechInfo: Codable, Hashable, Sendable {
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var bitrateKbps: Int?

    public init(videoCodec: String? = nil, width: Int? = nil, height: Int? = nil,
                audioCodec: String? = nil, audioChannels: Int? = nil, bitrateKbps: Int? = nil) {
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.bitrateKbps = bitrateKbps
    }
}

/// Details from `get_vod_info` (movies) or `get_series_info.info` (series). Fetched only when a detail page opens.
public struct RawItemInfo: Codable, Hashable, Sendable {
    public var tmdbID: Int?
    public var name: String?
    public var originalName: String?
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var country: String?
    public var releaseDate: String?
    public var rating: Double?
    public var durationSeconds: Int?
    public var posterURL: String?
    public var backdropURLs: [String]
    public var trailerYouTubeID: String?
    public var tech: StreamTechInfo?
    public var containerExtension: String?

    public init(tmdbID: Int? = nil, name: String? = nil, originalName: String? = nil, plot: String? = nil,
                cast: String? = nil, director: String? = nil, genre: String? = nil, country: String? = nil,
                releaseDate: String? = nil, rating: Double? = nil, durationSeconds: Int? = nil,
                posterURL: String? = nil, backdropURLs: [String] = [], trailerYouTubeID: String? = nil,
                tech: StreamTechInfo? = nil, containerExtension: String? = nil) {
        self.tmdbID = tmdbID
        self.name = name
        self.originalName = originalName
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.country = country
        self.releaseDate = releaseDate
        self.rating = rating
        self.durationSeconds = durationSeconds
        self.posterURL = posterURL
        self.backdropURLs = backdropURLs
        self.trailerYouTubeID = trailerYouTubeID
        self.tech = tech
        self.containerExtension = containerExtension
    }
}

public struct RawSeason: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    public var name: String?
    public var overview: String?
    public var airDate: String?
    public var coverURL: String?
    public var episodeCount: Int?
    public var id: Int { number }

    public init(number: Int, name: String? = nil, overview: String? = nil, airDate: String? = nil,
                coverURL: String? = nil, episodeCount: Int? = nil) {
        self.number = number
        self.name = name
        self.overview = overview
        self.airDate = airDate
        self.coverURL = coverURL
        self.episodeCount = episodeCount
    }
}

/// One episode from `get_series_info.episodes`.
public struct RawEpisode: Codable, Hashable, Sendable, Identifiable {
    /// kind == .episode, streamID == the episode `id`.
    public var ref: StreamRef
    public var id: String { ref.id }
    public var season: Int
    public var episode: Int
    public var title: String
    public var containerExtension: String?
    public var plot: String?
    public var durationSeconds: Int?
    public var airDate: String?
    public var stillURL: String?
    public var rating: Double?
    public var tech: StreamTechInfo?

    public init(ref: StreamRef, season: Int, episode: Int, title: String, containerExtension: String? = nil,
                plot: String? = nil, durationSeconds: Int? = nil, airDate: String? = nil, stillURL: String? = nil,
                rating: Double? = nil, tech: StreamTechInfo? = nil) {
        self.ref = ref
        self.season = season
        self.episode = episode
        self.title = title
        self.containerExtension = containerExtension
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.airDate = airDate
        self.stillURL = stillURL
        self.rating = rating
        self.tech = tech
    }
}

/// `get_series_info` result for one provider series record.
public struct RawSeriesInfo: Codable, Hashable, Sendable {
    public var seriesRef: StreamRef
    public var info: RawItemInfo?
    public var seasons: [RawSeason]
    public var episodes: [RawEpisode]
    public var fetchedAt: Date

    public init(seriesRef: StreamRef, info: RawItemInfo?, seasons: [RawSeason], episodes: [RawEpisode], fetchedAt: Date = Date()) {
        self.seriesRef = seriesRef
        self.info = info
        self.seasons = seasons
        self.episodes = episodes
        self.fetchedAt = fetchedAt
    }

    /// Episodes grouped by season number, both sorted ascending.
    public var episodesBySeason: [(season: Int, episodes: [RawEpisode])] {
        let grouped = Dictionary(grouping: episodes, by: { $0.season })
        return grouped.keys.sorted().map { key in
            (key, (grouped[key] ?? []).sorted { $0.episode < $1.episode })
        }
    }
}

/// Everything one provider returned during a catalog sync.
public struct ProviderCatalog: Codable, Sendable {
    public var providerID: ProviderID
    public var account: AccountInfo?
    public var categories: [RawCategory]
    public var items: [RawItem]
    /// When each section was last fetched from the provider.
    public var fetchedAt: [String: Date]
    /// XMLTV URL to use for this provider (custom one or the panel's `xmltv.php`).
    public var guideURL: String?

    public init(providerID: ProviderID, account: AccountInfo? = nil, categories: [RawCategory] = [],
                items: [RawItem] = [], fetchedAt: [String: Date] = [:], guideURL: String? = nil) {
        self.providerID = providerID
        self.account = account
        self.categories = categories
        self.items = items
        self.fetchedAt = fetchedAt
        self.guideURL = guideURL
    }

    public func items(of kind: StreamKind) -> [RawItem] { items.filter { $0.ref.kind == kind } }
}
