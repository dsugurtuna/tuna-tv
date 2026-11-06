import Foundation

/// The Vault: ONE box in the UI that holds everything that is not showcase material.
public enum VaultShelf: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Blu-ray / REMUX / disc rips that are below the showcase quality floor.
    case disc
    /// Full HD / HD versions (when the showcase is 4K-only).
    case highDefinition
    /// SD, DVD-era and unknown-quality files.
    case legacy
    /// CAM, telesync, screeners.
    case lowQuality
    /// Content in languages/countries outside the user's worlds.
    case otherLanguages
    /// Could not be classified (empty names, junk, separators).
    case unsorted
    /// Adult content. Hidden unless enabled, PIN-locked.
    case adult

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disc: return "Blu-ray & Disc"
        case .highDefinition: return "Full HD & HD"
        case .legacy: return "Legacy"
        case .lowQuality: return "Cam & Screeners"
        case .otherLanguages: return "Other Languages"
        case .unsorted: return "Unsorted"
        case .adult: return "Adult"
        }
    }

    public var subtitle: String {
        switch self {
        case .disc: return "Disc rips below your showcase quality"
        case .highDefinition: return "Great versions that are not 4K"
        case .legacy: return "SD, DVD-era and unknown quality"
        case .lowQuality: return "Theatre captures. Watch at your own risk"
        case .otherLanguages: return "Everything outside your worlds"
        case .unsorted: return "Things we could not classify"
        case .adult: return "Locked with your PIN"
        }
    }

    /// SF Symbol used as the shelf's logo.
    public var symbol: String {
        switch self {
        case .disc: return "opticaldisc.fill"
        case .highDefinition: return "sparkles.tv.fill"
        case .legacy: return "film.stack.fill"
        case .lowQuality: return "video.slash.fill"
        case .otherLanguages: return "globe.europe.africa.fill"
        case .unsorted: return "questionmark.folder.fill"
        case .adult: return "lock.fill"
        }
    }
}

/// Where a curated title/channel lives in the UI.
public enum Placement: Codable, Hashable, Sendable {
    /// The main, premium experience (Home, Movies, Series, Live).
    case showcase
    /// Tucked into The Vault on one shelf.
    case vault(VaultShelf)

    public var isShowcase: Bool { if case .showcase = self { return true } else { return false } }
    public var shelf: VaultShelf? { if case .vault(let shelf) = self { return shelf } else { return nil } }
}

/// One playable version of a title or channel (one provider record).
public struct Variant: Codable, Hashable, Sendable, Identifiable {
    public var raw: RawItem
    public var parsed: ParsedName
    public var id: String { raw.ref.id }
    public var ref: StreamRef { raw.ref }
    /// True when the variant's language/country fits the user's worlds (or carries no foreign tag).
    public var matchesWorld: Bool
    /// Higher is better. Used to order versions and to pick the default one.
    public var score: Int
    /// Quality verified by actual playback (overrides the parsed tag when known).
    public var verifiedQuality: Quality?

    public init(raw: RawItem, parsed: ParsedName, matchesWorld: Bool, score: Int, verifiedQuality: Quality? = nil) {
        self.raw = raw
        self.parsed = parsed
        self.matchesWorld = matchesWorld
        self.score = score
        self.verifiedQuality = verifiedQuality
    }

    public var effectiveQuality: Quality { verifiedQuality ?? parsed.quality }
    /// "4K · HDR10 · EN" style label for version pickers.
    public var label: String { parsed.badgeLine.isEmpty ? "Standard" : parsed.badgeLine }
}

/// A canonical movie or series: all duplicate provider records merged into one entry.
public struct Title: Codable, Hashable, Sendable, Identifiable {
    /// Stable id: "movie:<key>:<year>" / "series:<key>" (see `Curator`).
    public var id: String
    public var kind: TitleKind
    /// Clean display name.
    public var name: String
    public var year: Int?
    /// Versions, best first (score order). Series: each variant is one provider series record.
    public var variants: [Variant]
    public var placement: Placement
    public var bestQuality: Quality
    public var hdr: HDRFormat?
    public var languages: [String]
    public var countries: [String]
    public var regions: [String]
    /// Cleaned provider category names.
    public var categories: [String]
    /// Genre hints from provider data (TMDB metadata overrides these in the UI).
    public var genres: [String]
    public var platform: String?
    /// TMDB id supplied by the provider, if any.
    public var providerTMDBID: Int?
    /// Newest `addedAt` among variants.
    public var addedAt: Date?
    public var providerRating: Double?
    /// Fallback artwork from the provider.
    public var posterURL: String?
    public var backdropURL: String?
    /// Fallback plot from the provider list data.
    public var plot: String?
    public var isAdult: Bool

    public init(id: String, kind: TitleKind, name: String, year: Int?, variants: [Variant], placement: Placement,
                bestQuality: Quality, hdr: HDRFormat? = nil, languages: [String] = [], countries: [String] = [],
                regions: [String] = [], categories: [String] = [], genres: [String] = [], platform: String? = nil,
                providerTMDBID: Int? = nil, addedAt: Date? = nil, providerRating: Double? = nil,
                posterURL: String? = nil, backdropURL: String? = nil, plot: String? = nil, isAdult: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.year = year
        self.variants = variants
        self.placement = placement
        self.bestQuality = bestQuality
        self.hdr = hdr
        self.languages = languages
        self.countries = countries
        self.regions = regions
        self.categories = categories
        self.genres = genres
        self.platform = platform
        self.providerTMDBID = providerTMDBID
        self.addedAt = addedAt
        self.providerRating = providerRating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.plot = plot
        self.isAdult = isAdult
    }

    /// The version to play by default (first world-matching variant, else the best one).
    public var defaultVariant: Variant? { variants.first(where: { $0.matchesWorld }) ?? variants.first }
    /// Versions other than the default one (shown in the detail page's "Versions" box).
    public var otherVariants: [Variant] {
        guard let def = defaultVariant else { return [] }
        return variants.filter { $0.id != def.id }
    }
}

/// iptv-org categories plus a few extras.
public enum ChannelCategory: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case news, sports, movies, series, entertainment, kids, documentary, music, lifestyle, religious
    case business, education, cooking, travel, comedy, animation, weather, shop, legislative, outdoor
    case science, culture, family, auto, classic, general, relax, events, xxx, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xxx: return "Adult"
        case .events: return "Events & PPV"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var symbol: String {
        switch self {
        case .news: return "newspaper.fill"
        case .sports: return "sportscourt.fill"
        case .movies: return "film.fill"
        case .series: return "tv.fill"
        case .entertainment: return "sparkles"
        case .kids: return "figure.and.child.holdinghands"
        case .documentary: return "binoculars.fill"
        case .music: return "music.note"
        case .lifestyle: return "leaf.fill"
        case .religious: return "building.columns.fill"
        case .business: return "chart.line.uptrend.xyaxis"
        case .education: return "graduationcap.fill"
        case .cooking: return "fork.knife"
        case .travel: return "airplane"
        case .comedy: return "theatermasks.fill"
        case .animation: return "paintpalette.fill"
        case .weather: return "cloud.sun.fill"
        case .shop: return "bag.fill"
        case .legislative: return "building.2.fill"
        case .outdoor: return "mountain.2.fill"
        case .science: return "atom"
        case .culture: return "books.vertical.fill"
        case .family: return "house.fill"
        case .auto: return "car.fill"
        case .classic: return "film.stack"
        case .general: return "tv"
        case .relax: return "cup.and.saucer.fill"
        case .events: return "ticket.fill"
        case .xxx: return "lock.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
}

/// A canonical live channel: "UK: BBC One FHD", "UK: BBC One HD", "BBC One (Backup)" become one channel.
public struct Channel: Codable, Hashable, Sendable, Identifiable {
    /// Stable id: "live:<key>:<country>".
    public var id: String
    public var name: String
    public var number: Int?
    /// Feeds best-first; also the failover order.
    public var variants: [Variant]
    public var logoURL: String?
    /// Cleaned provider group name.
    public var groupName: String?
    public var categories: [ChannelCategory]
    public var languages: [String]
    public var countries: [String]
    public var epgChannelID: String?
    /// Matched iptv-org channel id (e.g. "BBCOne.uk").
    public var iptvOrgID: String?
    public var catchupDays: Int?
    public var placement: Placement
    public var bestQuality: Quality
    public var isAdult: Bool
    public var isEvent: Bool

    public init(id: String, name: String, number: Int? = nil, variants: [Variant], logoURL: String? = nil,
                groupName: String? = nil, categories: [ChannelCategory] = [], languages: [String] = [],
                countries: [String] = [], epgChannelID: String? = nil, iptvOrgID: String? = nil,
                catchupDays: Int? = nil, placement: Placement, bestQuality: Quality, isAdult: Bool = false,
                isEvent: Bool = false) {
        self.id = id
        self.name = name
        self.number = number
        self.variants = variants
        self.logoURL = logoURL
        self.groupName = groupName
        self.categories = categories
        self.languages = languages
        self.countries = countries
        self.epgChannelID = epgChannelID
        self.iptvOrgID = iptvOrgID
        self.catchupDays = catchupDays
        self.placement = placement
        self.bestQuality = bestQuality
        self.isAdult = isAdult
        self.isEvent = isEvent
    }

    public var defaultVariant: Variant? { variants.first(where: { $0.matchesWorld && !$0.parsed.isBackup }) ?? variants.first }
}

/// Counters produced by the curator. Shown in the sync "curation theater" and the Insights page.
public struct CurationStats: Codable, Hashable, Sendable {
    public var rawCounts: [String: Int]
    public var titleCounts: [String: Int]
    public var duplicatesMerged: Int
    public var showcaseCounts: [String: Int]
    public var vaultCounts: [String: Int]
    public var qualityCounts: [String: Int]
    public var languageCounts: [String: Int]
    public var countryCounts: [String: Int]
    public var adultHidden: Int
    public var showcaseRelaxed: Bool

    public init(rawCounts: [String: Int] = [:], titleCounts: [String: Int] = [:], duplicatesMerged: Int = 0,
                showcaseCounts: [String: Int] = [:], vaultCounts: [String: Int] = [:], qualityCounts: [String: Int] = [:],
                languageCounts: [String: Int] = [:], countryCounts: [String: Int] = [:], adultHidden: Int = 0,
                showcaseRelaxed: Bool = false) {
        self.rawCounts = rawCounts
        self.titleCounts = titleCounts
        self.duplicatesMerged = duplicatesMerged
        self.showcaseCounts = showcaseCounts
        self.vaultCounts = vaultCounts
        self.qualityCounts = qualityCounts
        self.languageCounts = languageCounts
        self.countryCounts = countryCounts
        self.adultHidden = adultHidden
        self.showcaseRelaxed = showcaseRelaxed
    }
}

/// Output of `Curator.curate`.
public struct CuratedCatalog: Sendable {
    public var movies: [Title]
    public var series: [Title]
    public var channels: [Channel]
    public var stats: CurationStats

    public init(movies: [Title] = [], series: [Title] = [], channels: [Channel] = [], stats: CurationStats = CurationStats()) {
        self.movies = movies
        self.series = series
        self.channels = channels
        self.stats = stats
    }
}
