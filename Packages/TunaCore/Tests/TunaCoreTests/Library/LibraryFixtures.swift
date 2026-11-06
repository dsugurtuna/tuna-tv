import Foundation
@testable import TunaCore

/// Hand-built curated catalogs for Library tests (no dependency on the Curator).
enum LF {
    static let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15
    static let day: TimeInterval = 86_400

    static func variant(_ streamID: String, kind: StreamKind = .movie, name: String = "x", quality: Quality = .uhd,
                        languages: [String] = [], countries: [String] = [], score: Int = 700) -> Variant {
        let raw = RawItem(ref: StreamRef(providerID: "p", kind: kind, streamID: streamID), name: name)
        let parsed = ParsedName(original: name, title: name, key: name.lowercased(), quality: quality,
                                languages: languages, countries: countries)
        return Variant(raw: raw, parsed: parsed, matchesWorld: true, score: score)
    }

    static func title(_ key: String, _ kind: TitleKind = .movie, name: String? = nil, year: Int? = 2020,
                      placement: Placement = .showcase, quality: Quality = .uhd, hdr: HDRFormat? = nil,
                      languages: [String] = ["en"], countries: [String] = [], genres: [String] = [],
                      tmdb: Int? = nil, addedDaysAgo: Double? = nil, rating: Double? = nil, backdrop: Bool = false,
                      adult: Bool = false, categories: [String] = []) -> Title {
        let id = kind == .movie ? "movie:\(key):\(year ?? 0)" : "series:\(key)"
        return Title(id: id, kind: kind, name: name ?? key.capitalized, year: year,
                     variants: [variant("\(kind.rawValue)-\(key)", kind: kind.streamKind, name: name ?? key, quality: quality, languages: languages)],
                     placement: placement, bestQuality: quality, hdr: hdr, languages: languages, countries: countries,
                     categories: categories, genres: genres, providerTMDBID: tmdb,
                     addedAt: addedDaysAgo.map { now.addingTimeInterval(-$0 * day) }, providerRating: rating,
                     backdropURL: backdrop ? "https://img/\(key).jpg" : nil, isAdult: adult)
    }

    static func channel(_ key: String, name: String? = nil, placement: Placement = .showcase, categories: [ChannelCategory] = [],
                        group: String? = nil, epg: String? = nil, quality: Quality = .fhd, adult: Bool = false) -> Channel {
        Channel(id: "live:\(key):gb", name: name ?? key.uppercased(), variants: [variant("live-\(key)", kind: .live, name: key, quality: quality)],
                groupName: group, categories: categories, epgChannelID: epg, placement: placement, bestQuality: quality, isAdult: adult)
    }

    static func md(_ kind: TitleKind = .movie, title: String, tmdb: Int? = nil, vote: Double? = nil, votes: Int? = nil,
                   popularity: Double? = nil, year: Int? = nil, genres: [String] = [], language: String? = "en",
                   countries: [String] = ["US"], cast: [CastMember] = [], keywords: [String] = [],
                   collection: CollectionRef? = nil, recommendations: [Int] = [], backdrop: Bool = true) -> MediaMetadata {
        MediaMetadata(kind: kind, source: .tmdb, title: title, tmdbID: tmdb, releaseDate: year.map { "\($0)-06-01" }, year: year,
                      genres: genres, voteAverage: vote, voteCount: votes, popularity: popularity, originalLanguage: language,
                      originCountries: countries, backdropURL: backdrop ? "https://img/\(title).jpg" : nil, cast: cast,
                      keywords: keywords, collection: collection, recommendationIDs: recommendations)
    }

    struct Rich {
        var library: Library
        var metadata: [String: MediaMetadata]
        var movies: [Title]
        var series: [Title]
        var guide: Guide
        func context(userState: UserState = UserState(), preferences: ContentPreferences = LF.turkishPreferences,
                     trendingMovies: [Int] = [], trendingSeries: [Int] = [], guide: Guide? = nil) -> RailContext {
            RailContext(library: library, metadata: metadata, userState: userState, preferences: preferences,
                        trendingMovieIDs: trendingMovies, trendingSeriesIDs: trendingSeries, guide: guide ?? self.guide, now: LF.now)
        }
    }

    static var turkishPreferences: ContentPreferences {
        ContentPreferences(worlds: WorldSelection.english.adding(country: "TR", language: "tr"))
    }

    static let movieGenres = [["Action", "Thriller"], ["Drama"], ["Comedy", "Action"]]
    static let seriesGenres = [["Drama", "Crime"], ["Comedy"]]

    /// 30 showcase movies (m0...m29, 6 Turkish), 20 showcase series (s10...s19 Turkish), Vault + adult extras,
    /// 3 channels with a guide.
    static func rich() -> Rich {
        var movies: [Title] = []
        var series: [Title] = []
        var metadata: [String: MediaMetadata] = [:]
        let voteCounts = [100, 500, 1500, 3000, 800]
        for i in 0..<30 {
            let turkish = i >= 24
            let movie = title("m\(i)", name: "Movie \(i)", year: 1990 + i, quality: i % 2 == 0 ? .uhd : .fhd,
                              hdr: i % 4 == 0 ? .dolbyVision : nil, languages: [turkish ? "tr" : "en"],
                              tmdb: 1000 + i, addedDaysAgo: Double(i), backdrop: i % 2 == 0)
            movies.append(movie)
            metadata[movie.id] = md(title: "Movie \(i)", tmdb: 1000 + i, vote: 6.0 + Double(i % 10) * 0.4,
                                    votes: voteCounts[i % 5], popularity: Double(10 * (i + 1)), year: 1990 + i,
                                    genres: movieGenres[i % 3], language: turkish ? "tr" : "en", countries: turkish ? ["TR"] : ["US"],
                                    cast: i < 3 ? [CastMember(personID: 42, name: "Keanu Reeves", profileURL: "https://p/42.jpg")] : [],
                                    keywords: i % 5 == 0 ? ["heist"] : [],
                                    collection: i < 2 ? CollectionRef(id: 77, name: "Alpha Collection") : nil,
                                    recommendations: i == 0 ? [1007, 1006, 1005] : [])
        }
        for i in 0..<20 {
            let turkish = i >= 10
            let show = title("s\(i)", .series, name: "Show \(i)", year: 2000 + i, languages: [turkish ? "tr" : "en"],
                             tmdb: 5000 + i, addedDaysAgo: Double(i) + 0.5)
            series.append(show)
            metadata[show.id] = md(.series, title: "Show \(i)", tmdb: 5000 + i, vote: 7.0 + Double(i % 5) * 0.3, votes: 1200,
                                   popularity: Double(5 * (i + 1)), year: 2000 + i, genres: seriesGenres[i % 2],
                                   language: turkish ? "tr" : "en", countries: turkish ? ["TR"] : ["US"])
        }
        let vaultGerman = title("v0", name: "Das Boot", year: 1981, placement: .vault(.otherLanguages), quality: .fhd, languages: ["de"], tmdb: 9000)
        let vaultLegacy = title("v1", name: "Old Movie 1", year: 1950, placement: .vault(.legacy), quality: .sd, languages: ["en"])
        let adult = title("a0", name: "Adult Movie", placement: .vault(.adult), adult: true)
        movies += [vaultGerman, vaultLegacy, adult]
        let channels = [
            channel("bbc", name: "BBC One", categories: [.general], group: "UK", epg: "bbc.uk"),
            channel("sky", name: "Sky Sports", categories: [.sports], group: "UK", epg: "sky.uk"),
            channel("trt", name: "TRT 1", placement: .vault(.otherLanguages), group: "TR", epg: "trt.tr"),
        ]
        let guide = Guide(programs: [
            Program(channelKey: "bbc.uk", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(1800), title: "News at Ten"),
            Program(channelKey: "bbc.uk", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400), title: "Late Show"),
            Program(channelKey: "sky.uk", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(6000), title: "Arsenal vs Chelsea"),
        ])
        let library = Library(catalog: CuratedCatalog(movies: movies, series: series, channels: channels,
                                                      stats: CurationStats(rawCounts: ["movie": 80, "series": 30, "live": 5], duplicatesMerged: 7)),
                              generatedAt: now)
        return Rich(library: library, metadata: metadata, movies: movies, series: series, guide: guide)
    }

    static func titleIDs(_ rail: Rail) -> [String] {
        rail.items.compactMap { item in
            switch item {
            case .title(let t), .progress(let t, _): return t.id
            default: return nil
            }
        }
    }
}
