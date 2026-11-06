import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TMDB v3 client. Image URLs are returned as full URLs (poster w500, backdrop w1280, profile w185, logo w500,
/// still w300). `append_to_response` is used so one detail call returns everything.
///
/// Auth: a 32-character hex v3 API key goes in the `api_key` query item; anything else (the v4 "API Read Access
/// Token", usually starting with "eyJ") is sent as `Authorization: Bearer`. Every request goes through
/// `HostLimiter`. HTTP 401 → `TunaError.unauthorized("TMDB key rejected")`, other non-2xx → `TunaError.http`.
public struct TMDBClient: Sendable {
    public init(keys: MetadataKeys, http: HTTPClient, limiter: HostLimiter) {
        self.keys = keys
        self.fetcher = MetadataSupport.Fetcher(http: http, limiter: limiter)
        if let token = keys.tmdb { TunaLog.shared.registerSecret(token) }
    }

    let keys: MetadataKeys
    let fetcher: MetadataSupport.Fetcher

    static let apiHost = "api.themoviedb.org"
    static let apiBase = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p"
    /// Cast members kept per title.
    static let castLimit = 20

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

    public func search(_ query: String, kind: TitleKind, year: Int?) async throws -> [SearchResult] {
        let text = query.tunaTrimmed
        guard !text.isEmpty else { return [] }
        var items: [(String, String)] = [("query", text), ("include_adult", "false"), ("language", keys.language), ("page", "1")]
        if let year, (1870...2200).contains(year) {
            items.append((kind == .movie ? "year" : "first_air_date_year", String(year)))
        }
        let page = try await get(kind == .movie ? "/search/movie" : "/search/tv", items, as: DTO.ResultPage<DTO.SearchItem>.self)
        return (page.results?.values ?? []).compactMap { $0.searchResult }
    }

    /// movie/{id} or tv/{id} with credits/aggregate_credits, videos, images (logos), release_dates/content_ratings,
    /// keywords, recommendations, similar, external_ids.
    public func details(id: Int, kind: TitleKind) async throws -> MediaMetadata {
        guard id > 0 else { throw TunaError.invalidInput("Invalid TMDB id \(id)") }
        let language = languageCode
        let append = kind == .movie
            ? "credits,videos,images,release_dates,keywords,recommendations,similar,external_ids"
            : "aggregate_credits,credits,videos,images,content_ratings,keywords,recommendations,similar,external_ids"
        let items: [(String, String)] = [
            ("language", keys.language),
            ("append_to_response", append),
            ("include_image_language", MetadataSupport.unique([language, "en", "null"]).joined(separator: ",")),
            ("include_video_language", MetadataSupport.unique([language, "en"]).joined(separator: ",")),
        ]
        let path = kind == .movie ? "/movie/\(id)" : "/tv/\(id)"
        let dto = try await get(path, items, as: DTO.Details.self)
        return Self.map(dto, kind: kind, language: language, fetchedAt: Date())
    }

    public func season(tvID: Int, season: Int) async throws -> SeasonMetadata {
        guard tvID > 0, season >= 0 else { throw TunaError.invalidInput("Invalid TMDB season \(tvID)/\(season)") }
        let dto = try await get("/tv/\(tvID)/season/\(season)", [("language", keys.language)], as: DTO.Season.self)
        return Self.map(dto, requestedSeason: season)
    }

    public func person(id: Int) async throws -> PersonDetails {
        guard id > 0 else { throw TunaError.invalidInput("Invalid TMDB person id \(id)") }
        let items: [(String, String)] = [("language", keys.language), ("append_to_response", "combined_credits")]
        let dto = try await get("/person/\(id)", items, as: DTO.Person.self)
        return Self.map(dto, fetchedAt: Date())
    }

    /// trending/{movie|tv}/{day|week} ids, in rank order.
    public func trending(kind: TitleKind, window: String) async throws -> [Int] {
        let span = window.lowercased() == "day" ? "day" : "week"
        let page = try await get("/trending/\(kind == .movie ? "movie" : "tv")/\(span)", [("language", keys.language)],
                                 as: DTO.ResultPage<DTO.IDOnly>.self)
        return MetadataSupport.unique((page.results?.values ?? []).compactMap { $0.id })
    }

    /// tv/{id}/external_ids or find by IMDb id helpers if needed.
    public func find(imdbID: String) async throws -> (kind: TitleKind, id: Int)? {
        let clean = imdbID.tunaTrimmed.lowercased()
        guard clean.count > 2, clean.hasPrefix("tt"), clean.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw TunaError.invalidInput("Invalid IMDb id")
        }
        let items: [(String, String)] = [("external_source", "imdb_id"), ("language", keys.language)]
        let dto = try await get("/find/\(clean)", items, as: DTO.Find.self)
        if let id = dto.movieResults?.values.first?.id { return (.movie, id) }
        if let id = dto.tvResults?.values.first?.id { return (.series, id) }
        if let id = dto.tvEpisodeResults?.values.first?.showID { return (.series, id) }
        return nil
    }

    // MARK: - Requests

    enum Credential: Equatable {
        case apiKey(String)
        case bearer(String)
    }

    /// 32 hex characters → v3 API key; anything else → v4 bearer token.
    static func credential(for token: String?) -> Credential? {
        guard let token = token?.tunaTrimmed, !token.isEmpty else { return nil }
        let isHex = token.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        return token.utf8.count == 32 && isHex ? .apiKey(token) : .bearer(token)
    }

    /// ISO 639-1 part of `keys.language` ("tr" for "tr-TR").
    var languageCode: String {
        let code = keys.language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        return code.isEmpty ? "en" : code
    }

    func makeRequest(_ path: String, _ query: [(String, String)]) throws -> HTTPRequest {
        guard let credential = Self.credential(for: keys.tmdb) else {
            throw TunaError.notConfigured("Add your TMDB API key or read access token in Settings to load movie and series details.")
        }
        var items = query
        var headers = ["Accept": "application/json"]
        switch credential {
        case .apiKey(let key): items.append(("api_key", key))
        case .bearer(let token): headers["Authorization"] = "Bearer \(token)"
        }
        guard let url = MetadataSupport.makeURL(Self.apiBase, path: path, query: items) else {
            throw TunaError.invalidInput("Could not build TMDB request for \(path)")
        }
        return HTTPRequest(url: url, headers: headers, timeout: 20)
    }

    func get<T: Decodable>(_ path: String, _ query: [(String, String)], as type: T.Type) async throws -> T {
        let request = try makeRequest(path, query)
        let response = try await fetcher.send(request)
        guard response.isSuccess else {
            if response.status == 401 { throw TunaError.unauthorized("TMDB key rejected") }
            throw TunaError.http(status: response.status, host: Self.apiHost)
        }
        return try MetadataSupport.decode(T.self, from: response.body, context: "TMDB \(path)")
    }

    // MARK: - Images

    static func imageURL(_ path: String?, size: String) -> String? {
        guard let path = path?.nonEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        return imageBase + "/" + size + (path.hasPrefix("/") ? path : "/" + path)
    }

    /// Logos may be SVG; TMDB rasterizes them at sized URLs when asked for `.png`.
    static func logoURL(_ path: String?, size: String) -> String? {
        guard var path = path?.nonEmpty else { return nil }
        if path.lowercased().hasSuffix(".svg") { path = String(path.dropLast(4)) + ".png" }
        return imageURL(path, size: size)
    }

    /// Title logo: language == user's, then "en", then textless (null); highest vote average within a tier.
    /// Logos in other languages are never used (the UI falls back to the text title).
    static func pickLogo(_ logos: [DTO.Image], language: String) -> DTO.Image? {
        func tier(_ image: DTO.Image) -> Int? {
            let code = image.iso6391?.lowercased() ?? ""
            if code == language { return 0 }
            if code == "en" { return 1 }
            if code.isEmpty || code == "xx" || code == "null" { return 2 }
            return nil
        }
        var best: (tier: Int, image: DTO.Image)?
        for image in logos where image.filePath?.nonEmpty != nil {
            guard let rank = tier(image) else { continue }
            guard let current = best else {
                best = (rank, image)
                continue
            }
            let better: Bool
            if rank != current.tier {
                better = rank < current.tier
            } else if (image.voteAverage ?? 0) != (current.image.voteAverage ?? 0) {
                better = (image.voteAverage ?? 0) > (current.image.voteAverage ?? 0)
            } else if (image.voteCount ?? 0) != (current.image.voteCount ?? 0) {
                better = (image.voteCount ?? 0) > (current.image.voteCount ?? 0)
            } else {
                better = (image.width ?? 0) > (current.image.width ?? 0)
            }
            if better { best = (rank, image) }
        }
        return best?.image
    }

    /// Backdrop URLs (w1280): textless first, then the user's language, then English; best rated first.
    static func backdropURLs(_ images: [DTO.Image], language: String, fallback: String?) -> [String] {
        func tier(_ image: DTO.Image) -> Int {
            let code = image.iso6391?.lowercased() ?? ""
            if code.isEmpty || code == "xx" || code == "null" { return 0 }
            if code == language { return 1 }
            if code == "en" { return 2 }
            return 3
        }
        let ordered = images.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            if (a.voteAverage ?? 0) != (b.voteAverage ?? 0) { return (a.voteAverage ?? 0) > (b.voteAverage ?? 0) }
            return lhs.offset < rhs.offset
        }
        let urls = MetadataSupport.unique(ordered.compactMap { imageURL($0.element.filePath, size: "w1280") })
        if urls.isEmpty, let fallback { return [fallback] }
        return Array(urls.prefix(15))
    }

    // MARK: - Mapping

    static func map(_ d: DTO.Details, kind: TitleKind, language: String, fetchedAt: Date) -> MediaMetadata {
        let isMovie = kind == .movie
        let primaryTitle = isMovie ? d.title : d.name
        let primaryOriginal = isMovie ? d.originalTitle : d.originalName
        let title = primaryTitle?.nonEmpty ?? d.title?.nonEmpty ?? d.name?.nonEmpty ?? primaryOriginal?.nonEmpty ?? ""
        let releaseDate = (isMovie ? d.releaseDate : d.firstAirDate)?.nonEmpty

        var m = MediaMetadata(kind: kind, source: .tmdb, title: title, tmdbID: d.id, fetchedAt: fetchedAt)
        m.imdbID = d.imdbID?.nonEmpty ?? d.externalIDs?.imdbID?.nonEmpty
        m.originalTitle = primaryOriginal?.nonEmpty
        m.tagline = d.tagline?.nonEmpty
        m.overview = d.overview?.nonEmpty
        m.releaseDate = releaseDate
        m.year = MetadataSupport.year(from: releaseDate)
        if isMovie {
            m.runtimeMinutes = MetadataSupport.positive(d.runtime)
        } else {
            m.runtimeMinutes = (d.episodeRunTime ?? []).first(where: { $0 > 0 })
                ?? MetadataSupport.positive(d.lastEpisodeToAir?.runtime)
                ?? MetadataSupport.positive(d.nextEpisodeToAir?.runtime)
        }
        m.genres = MetadataSupport.unique((d.genres?.values ?? []).compactMap { $0.name?.nonEmpty })
        m.certification = isMovie ? certification(movie: d.releaseDates) : certification(tv: d.contentRatings)
        m.status = d.status?.nonEmpty

        m.voteCount = d.voteCount
        m.voteAverage = ((d.voteCount ?? 0) > 0 || (d.voteAverage ?? 0) > 0) ? d.voteAverage : nil
        m.popularity = d.popularity

        m.originalLanguage = d.originalLanguage?.nonEmpty?.lowercased()
        m.spokenLanguages = MetadataSupport.unique((d.spokenLanguages?.values ?? []).compactMap { $0.iso6391?.nonEmpty?.lowercased() })
        m.originCountries = MetadataSupport.unique((d.originCountry ?? []).compactMap { $0.nonEmpty?.uppercased() })
        m.productionCountries = MetadataSupport.unique((d.productionCountries?.values ?? []).compactMap { $0.iso31661?.nonEmpty?.uppercased() })
        m.studios = companies(d.productionCompanies?.values ?? [])
        m.networks = companies(d.networks?.values ?? [])

        m.posterURL = imageURL(d.posterPath, size: "w500")
        m.backdropURL = imageURL(d.backdropPath, size: "w1280")
        m.logoURL = pickLogo(d.images?.logos?.values ?? [], language: language).flatMap { logoURL($0.filePath, size: "w500") }
        m.backdrops = backdropURLs(d.images?.backdrops?.values ?? [], language: language, fallback: m.backdropURL)

        m.cast = cast(d, isMovie: isMovie)
        m.crew = crew(d, isMovie: isMovie)
        m.directors = Array(MetadataSupport.unique(m.crew.filter { $0.job == "Director" }.map { $0.name }).prefix(6))
        m.writers = Array(MetadataSupport.unique(m.crew.filter { writerJobs.contains($0.job) }.map { $0.name }).prefix(8))
        m.creators = MetadataSupport.unique((d.createdBy?.values ?? []).compactMap { $0.name?.nonEmpty })

        m.trailers = trailers(d.videos?.results?.values ?? [], language: language)
        let keywordList = (d.keywords?.keywords?.values ?? []) + (d.keywords?.results?.values ?? [])
        m.keywords = MetadataSupport.unique(keywordList.compactMap { $0.name?.nonEmpty })
        if let collection = d.belongsToCollection, let id = collection.id {
            m.collection = CollectionRef(id: id, name: collection.name?.nonEmpty ?? "",
                                         posterURL: imageURL(collection.posterPath, size: "w500"),
                                         backdropURL: imageURL(collection.backdropPath, size: "w1280"))
        }
        m.recommendationIDs = MetadataSupport.unique((d.recommendations?.results?.values ?? []).compactMap { $0.id })
        m.similarIDs = MetadataSupport.unique((d.similar?.results?.values ?? []).compactMap { $0.id })
        m.budget = MetadataSupport.positive(d.budget)
        m.revenue = MetadataSupport.positive(d.revenue)
        m.homepage = d.homepage?.nonEmpty

        if !isMovie {
            m.seasonCount = d.numberOfSeasons
            m.episodeCount = d.numberOfEpisodes
            m.firstAirDate = d.firstAirDate?.nonEmpty
            m.lastAirDate = d.lastAirDate?.nonEmpty
            m.inProduction = d.inProduction
        }
        return m
    }

    /// Movie: US release (theatrical 3 / digital 4 first) with a certification, then any US one, then the first
    /// non-empty certification of any country.
    static func certification(movie releaseDates: DTO.ReleaseDates?) -> String? {
        let countries = releaseDates?.results?.values ?? []
        if let us = countries.first(where: { $0.iso31661?.uppercased() == "US" }) {
            let dates = us.releaseDates?.values ?? []
            if let value = dates.first(where: { [3, 4].contains($0.type ?? 0) && $0.certification?.nonEmpty != nil })?.certification?.nonEmpty {
                return value
            }
            if let value = dates.lazy.compactMap({ $0.certification?.nonEmpty }).first { return value }
        }
        for country in countries {
            if let value = (country.releaseDates?.values ?? []).lazy.compactMap({ $0.certification?.nonEmpty }).first { return value }
        }
        return nil
    }

    /// TV: the US content rating, else the first non-empty one.
    static func certification(tv ratings: DTO.ContentRatings?) -> String? {
        let list = ratings?.results?.values ?? []
        if let us = list.first(where: { $0.iso31661?.uppercased() == "US" })?.rating?.nonEmpty { return us }
        return list.lazy.compactMap { $0.rating?.nonEmpty }.first
    }

    static func companies(_ list: [DTO.CompanyDTO]) -> [Company] {
        var seen = Set<Int>()
        return list.compactMap { company in
            guard let id = company.id, let name = company.name?.nonEmpty, seen.insert(id).inserted else { return nil }
            return Company(id: id, name: name, logoURL: logoURL(company.logoPath, size: "w92"),
                           country: company.originCountry?.nonEmpty?.uppercased())
        }
    }

    /// Top 20 by `order`. TV uses `aggregate_credits` (character from roles[0]) when present.
    /// One entry per person (extra roles are appended to the character).
    static func cast(_ d: DTO.Details, isMovie: Bool) -> [CastMember] {
        let aggregate = isMovie ? [] : (d.aggregateCredits?.cast?.values ?? [])
        let source = aggregate.isEmpty ? (d.credits?.cast?.values ?? []) : aggregate
        let ordered = source.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element.order ?? Int.max, rhs.element.order ?? Int.max)
            return a != b ? a < b : lhs.offset < rhs.offset
        }
        var result: [CastMember] = []
        var positions: [Int: Int] = [:]
        for (offset, member) in ordered {
            guard let id = member.id, let name = member.name?.nonEmpty else { continue }
            let character = member.character?.nonEmpty ?? member.roles?.values.lazy.compactMap({ $0.character?.nonEmpty }).first
            if let position = positions[id] {
                if let character, result[position].character?.contains(character) != true {
                    result[position].character = [result[position].character, character].compactMap { $0 }.joined(separator: " / ")
                }
                continue
            }
            guard result.count < castLimit else { continue }
            positions[id] = result.count
            result.append(CastMember(personID: id, name: name, character: character,
                                     profileURL: imageURL(member.profilePath, size: "w185"), order: member.order ?? offset))
        }
        return result
    }

    /// Jobs kept in `crew`, most important first.
    static let crewJobs: [String] = ["Director", "Screenplay", "Writer", "Story", "Novel", "Teleplay", "Author",
                                     "Original Music Composer", "Music", "Director of Photography", "Editor",
                                     "Producer", "Executive Producer", "Casting", "Production Design", "Costume Design"]
    static let writerJobs: Set<String> = ["Screenplay", "Writer", "Story", "Novel", "Teleplay", "Author"]

    static func crew(_ d: DTO.Details, isMovie: Bool) -> [CrewMember] {
        var rankOfJob: [String: Int] = [:]
        for (index, job) in crewJobs.enumerated() { rankOfJob[job] = index }
        struct Entry {
            let rank: Int
            let episodes: Int
            let index: Int
            let member: CrewMember
        }
        var entries: [Entry] = []
        let aggregate = isMovie ? [] : (d.aggregateCredits?.crew?.values ?? [])
        if !aggregate.isEmpty {
            for (index, person) in aggregate.enumerated() {
                guard let id = person.id, let name = person.name?.nonEmpty else { continue }
                for job in person.jobs?.values ?? [] {
                    guard let title = job.job?.nonEmpty, let rank = rankOfJob[title] else { continue }
                    entries.append(Entry(rank: rank, episodes: job.episodeCount ?? 0, index: index,
                                         member: CrewMember(personID: id, name: name, job: title, department: person.department?.nonEmpty,
                                                            profileURL: imageURL(person.profilePath, size: "w185"))))
                }
            }
        } else {
            for (index, person) in (d.credits?.crew?.values ?? []).enumerated() {
                guard let id = person.id, let name = person.name?.nonEmpty, let title = person.job?.nonEmpty,
                      let rank = rankOfJob[title] else { continue }
                entries.append(Entry(rank: rank, episodes: 0, index: index,
                                     member: CrewMember(personID: id, name: name, job: title, department: person.department?.nonEmpty,
                                                        profileURL: imageURL(person.profilePath, size: "w185"))))
            }
        }
        entries.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.episodes != b.episodes { return a.episodes > b.episodes }
            return a.index < b.index
        }
        var seen = Set<String>()
        var perJob: [String: Int] = [:]
        var result: [CrewMember] = []
        for entry in entries where result.count < 40 {
            let member = entry.member
            guard (perJob[member.job] ?? 0) < 6, seen.insert("\(member.personID)|\(member.job)").inserted else { continue }
            perJob[member.job, default: 0] += 1
            result.append(member)
        }
        return result
    }

    /// YouTube videos only. Order: Trailer, Teaser, Clip, Featurette, others; official first; the user's language,
    /// then English; earliest published first (the canonical trailer).
    static func trailers(_ videos: [DTO.Video], language: String) -> [Trailer] {
        let typeRank: [String: Int] = ["Trailer": 0, "Teaser": 1, "Clip": 2, "Featurette": 3, "Behind the Scenes": 4,
                                       "Opening Credits": 5, "Bloopers": 5]
        typealias Key = (type: Int, official: Int, language: Int, published: String, index: Int)
        var candidates: [(key: Key, trailer: Trailer)] = []
        for (index, video) in videos.enumerated() {
            guard (video.site ?? "").lowercased() == "youtube", let key = video.key?.nonEmpty else { continue }
            let type = video.type?.nonEmpty ?? "Trailer"
            let official = video.official ?? false
            let code = video.iso6391?.lowercased() ?? ""
            let languageRank = code == language ? 0 : (code == "en" ? 1 : 2)
            let sortKey: Key = (typeRank[type] ?? 6, official ? 0 : 1, languageRank, video.publishedAt ?? "9999", index)
            candidates.append((sortKey, Trailer(youtubeKey: key, name: video.name?.nonEmpty ?? type, type: type, isOfficial: official)))
        }
        candidates.sort { $0.key < $1.key }
        var seen = Set<String>()
        return Array(candidates.map { $0.trailer }.filter { seen.insert($0.youtubeKey).inserted }.prefix(12))
    }

    static func map(_ s: DTO.Season, requestedSeason: Int) -> SeasonMetadata {
        let episodes = (s.episodes?.values ?? []).compactMap { episode -> EpisodeMetadata? in
            guard let number = episode.episodeNumber else { return nil }
            let rating = episode.voteAverage ?? 0
            return EpisodeMetadata(episodeNumber: number, name: episode.name?.nonEmpty, overview: episode.overview?.nonEmpty,
                                   stillURL: imageURL(episode.stillPath, size: "w300"), airDate: episode.airDate?.nonEmpty,
                                   runtimeMinutes: MetadataSupport.positive(episode.runtime),
                                   voteAverage: rating > 0 ? rating : nil)
        }.sorted { $0.episodeNumber < $1.episodeNumber }
        return SeasonMetadata(seasonNumber: s.seasonNumber ?? requestedSeason, name: s.name?.nonEmpty, overview: s.overview?.nonEmpty,
                              posterURL: imageURL(s.posterPath, size: "w500"), airDate: s.airDate?.nonEmpty, episodes: episodes)
    }

    /// TMDB genre ids for talk shows and news: guest appearances there are not "known for" credits.
    static let appearanceGenres: Set<Int> = [10763, 10767]

    static func map(_ p: DTO.Person, fetchedAt: Date) -> PersonDetails {
        let credits = (p.combinedCredits?.cast?.values ?? []) + (p.combinedCredits?.crew?.values ?? [])
        let ordered = credits.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element.popularity ?? 0, rhs.element.popularity ?? 0)
            return a != b ? a > b : lhs.offset < rhs.offset
        }.map { $0.element }.filter { credit in
            guard credit.adult != true else { return false }
            if credit.mediaType == "tv" {
                if !appearanceGenres.isDisjoint(with: credit.genreIDs ?? []) { return false }
                let character = credit.character?.lowercased() ?? ""
                if character == "self" || character.hasPrefix("self ") || character.hasPrefix("himself") || character.hasPrefix("herself") {
                    return false
                }
            }
            return true
        }
        let movies = MetadataSupport.unique(ordered.filter { $0.mediaType == "movie" }.compactMap { $0.id })
        let shows = MetadataSupport.unique(ordered.filter { $0.mediaType == "tv" }.compactMap { $0.id })
        return PersonDetails(id: p.id, name: p.name?.nonEmpty ?? "", biography: p.biography?.nonEmpty, birthday: p.birthday?.nonEmpty,
                             deathday: p.deathday?.nonEmpty, placeOfBirth: p.placeOfBirth?.nonEmpty,
                             knownForDepartment: p.knownForDepartment?.nonEmpty, profileURL: imageURL(p.profilePath, size: "w185"),
                             popularity: p.popularity, movieCredits: movies, tvCredits: shows, fetchedAt: fetchedAt)
    }
}

// MARK: - Wire format (exact TMDB JSON names)

extension TMDBClient {
    enum DTO {
        typealias Lossy<T: Decodable> = MetadataSupport.Lossy<T>

        struct ResultPage<Item: Decodable>: Decodable {
            let results: Lossy<Item>?
        }

        struct IDOnly: Decodable {
            let id: Int?
        }

        struct SearchItem: Decodable {
            let id: Int?
            let title: String?
            let name: String?
            let originalTitle: String?
            let originalName: String?
            let releaseDate: String?
            let firstAirDate: String?
            let popularity: Double?
            let voteCount: Int?
            let originalLanguage: String?

            enum CodingKeys: String, CodingKey {
                case id, title, name, popularity
                case originalTitle = "original_title"
                case originalName = "original_name"
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
                case voteCount = "vote_count"
                case originalLanguage = "original_language"
            }

            var searchResult: TMDBClient.SearchResult? {
                guard let id, id > 0, let title = title?.nonEmpty ?? name?.nonEmpty ?? originalTitle?.nonEmpty ?? originalName?.nonEmpty else {
                    return nil
                }
                return TMDBClient.SearchResult(id: id, title: title, originalTitle: (originalTitle ?? originalName)?.nonEmpty,
                                               year: MetadataSupport.year(from: releaseDate ?? firstAirDate),
                                               popularity: popularity ?? 0, voteCount: voteCount ?? 0,
                                               originalLanguage: originalLanguage?.nonEmpty)
            }
        }

        struct Named: Decodable {
            let id: Int?
            let name: String?
        }

        struct SpokenLanguage: Decodable {
            let iso6391: String?
            enum CodingKeys: String, CodingKey { case iso6391 = "iso_639_1" }
        }

        struct ProductionCountry: Decodable {
            let iso31661: String?
            enum CodingKeys: String, CodingKey { case iso31661 = "iso_3166_1" }
        }

        struct CompanyDTO: Decodable {
            let id: Int?
            let name: String?
            let logoPath: String?
            let originCountry: String?
            enum CodingKeys: String, CodingKey {
                case id, name
                case logoPath = "logo_path"
                case originCountry = "origin_country"
            }
        }

        struct Image: Decodable {
            let filePath: String?
            let iso6391: String?
            let voteAverage: Double?
            let voteCount: Int?
            let width: Int?
            let height: Int?
            enum CodingKeys: String, CodingKey {
                case width, height
                case filePath = "file_path"
                case iso6391 = "iso_639_1"
                case voteAverage = "vote_average"
                case voteCount = "vote_count"
            }
        }

        struct Images: Decodable {
            let backdrops: Lossy<Image>?
            let logos: Lossy<Image>?
            let posters: Lossy<Image>?
        }

        struct Role: Decodable {
            let character: String?
            let episodeCount: Int?
            enum CodingKeys: String, CodingKey {
                case character
                case episodeCount = "episode_count"
            }
        }

        struct Job: Decodable {
            let job: String?
            let episodeCount: Int?
            enum CodingKeys: String, CodingKey {
                case job
                case episodeCount = "episode_count"
            }
        }

        struct CastDTO: Decodable {
            let id: Int?
            let name: String?
            let character: String?
            let profilePath: String?
            let order: Int?
            let roles: Lossy<Role>?
            enum CodingKeys: String, CodingKey {
                case id, name, character, order, roles
                case profilePath = "profile_path"
            }
        }

        struct CrewDTO: Decodable {
            let id: Int?
            let name: String?
            let job: String?
            let department: String?
            let profilePath: String?
            let jobs: Lossy<Job>?
            enum CodingKeys: String, CodingKey {
                case id, name, job, department, jobs
                case profilePath = "profile_path"
            }
        }

        struct Credits: Decodable {
            let cast: Lossy<CastDTO>?
            let crew: Lossy<CrewDTO>?
        }

        struct Video: Decodable {
            let key: String?
            let name: String?
            let site: String?
            let type: String?
            let official: Bool?
            let iso6391: String?
            let publishedAt: String?
            enum CodingKeys: String, CodingKey {
                case key, name, site, type, official
                case iso6391 = "iso_639_1"
                case publishedAt = "published_at"
            }
        }

        struct Videos: Decodable {
            let results: Lossy<Video>?
        }

        struct ReleaseDate: Decodable {
            let certification: String?
            let type: Int?
        }

        struct ReleaseDateCountry: Decodable {
            let iso31661: String?
            let releaseDates: Lossy<ReleaseDate>?
            enum CodingKeys: String, CodingKey {
                case iso31661 = "iso_3166_1"
                case releaseDates = "release_dates"
            }
        }

        struct ReleaseDates: Decodable {
            let results: Lossy<ReleaseDateCountry>?
        }

        struct ContentRating: Decodable {
            let iso31661: String?
            let rating: String?
            enum CodingKeys: String, CodingKey {
                case rating
                case iso31661 = "iso_3166_1"
            }
        }

        struct ContentRatings: Decodable {
            let results: Lossy<ContentRating>?
        }

        struct Keywords: Decodable {
            /// Movies use `keywords`, series use `results`.
            let keywords: Lossy<Named>?
            let results: Lossy<Named>?
        }

        struct CollectionDTO: Decodable {
            let id: Int?
            let name: String?
            let posterPath: String?
            let backdropPath: String?
            enum CodingKeys: String, CodingKey {
                case id, name
                case posterPath = "poster_path"
                case backdropPath = "backdrop_path"
            }
        }

        struct ExternalIDs: Decodable {
            let imdbID: String?
            enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
        }

        struct EpisodeRef: Decodable {
            let runtime: Int?
        }

        struct Details: Decodable {
            let id: Int
            let title: String?
            let name: String?
            let originalTitle: String?
            let originalName: String?
            let tagline: String?
            let overview: String?
            let releaseDate: String?
            let firstAirDate: String?
            let lastAirDate: String?
            let runtime: Int?
            let episodeRunTime: [Int]?
            let genres: Lossy<Named>?
            let status: String?
            let voteAverage: Double?
            let voteCount: Int?
            let popularity: Double?
            let originalLanguage: String?
            let spokenLanguages: Lossy<SpokenLanguage>?
            let originCountry: [String]?
            let productionCountries: Lossy<ProductionCountry>?
            let productionCompanies: Lossy<CompanyDTO>?
            let networks: Lossy<CompanyDTO>?
            let posterPath: String?
            let backdropPath: String?
            let images: Images?
            let credits: Credits?
            let aggregateCredits: Credits?
            let createdBy: Lossy<Named>?
            let videos: Videos?
            let keywords: Keywords?
            let belongsToCollection: CollectionDTO?
            let recommendations: ResultPage<IDOnly>?
            let similar: ResultPage<IDOnly>?
            let budget: Int?
            let revenue: Int?
            let homepage: String?
            let numberOfSeasons: Int?
            let numberOfEpisodes: Int?
            let inProduction: Bool?
            let imdbID: String?
            let externalIDs: ExternalIDs?
            let releaseDates: ReleaseDates?
            let contentRatings: ContentRatings?
            let lastEpisodeToAir: EpisodeRef?
            let nextEpisodeToAir: EpisodeRef?

            enum CodingKeys: String, CodingKey {
                case id, title, name, tagline, overview, runtime, genres, status, popularity, networks, images, credits, videos
                case keywords, recommendations, similar, budget, revenue, homepage
                case originalTitle = "original_title"
                case originalName = "original_name"
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
                case lastAirDate = "last_air_date"
                case episodeRunTime = "episode_run_time"
                case voteAverage = "vote_average"
                case voteCount = "vote_count"
                case originalLanguage = "original_language"
                case spokenLanguages = "spoken_languages"
                case originCountry = "origin_country"
                case productionCountries = "production_countries"
                case productionCompanies = "production_companies"
                case posterPath = "poster_path"
                case backdropPath = "backdrop_path"
                case aggregateCredits = "aggregate_credits"
                case createdBy = "created_by"
                case belongsToCollection = "belongs_to_collection"
                case numberOfSeasons = "number_of_seasons"
                case numberOfEpisodes = "number_of_episodes"
                case inProduction = "in_production"
                case imdbID = "imdb_id"
                case externalIDs = "external_ids"
                case releaseDates = "release_dates"
                case contentRatings = "content_ratings"
                case lastEpisodeToAir = "last_episode_to_air"
                case nextEpisodeToAir = "next_episode_to_air"
            }

            /// Only `id` is required; any other field with an unexpected shape is dropped instead of failing.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
                id = try c.decode(Int.self, forKey: .id)
                title = value(.title)
                name = value(.name)
                originalTitle = value(.originalTitle)
                originalName = value(.originalName)
                tagline = value(.tagline)
                overview = value(.overview)
                releaseDate = value(.releaseDate)
                firstAirDate = value(.firstAirDate)
                lastAirDate = value(.lastAirDate)
                runtime = value(.runtime)
                episodeRunTime = value(.episodeRunTime)
                genres = value(.genres)
                status = value(.status)
                voteAverage = value(.voteAverage)
                voteCount = value(.voteCount)
                popularity = value(.popularity)
                originalLanguage = value(.originalLanguage)
                spokenLanguages = value(.spokenLanguages)
                originCountry = value(.originCountry)
                productionCountries = value(.productionCountries)
                productionCompanies = value(.productionCompanies)
                networks = value(.networks)
                posterPath = value(.posterPath)
                backdropPath = value(.backdropPath)
                images = value(.images)
                credits = value(.credits)
                aggregateCredits = value(.aggregateCredits)
                createdBy = value(.createdBy)
                videos = value(.videos)
                keywords = value(.keywords)
                belongsToCollection = value(.belongsToCollection)
                recommendations = value(.recommendations)
                similar = value(.similar)
                budget = value(.budget)
                revenue = value(.revenue)
                homepage = value(.homepage)
                numberOfSeasons = value(.numberOfSeasons)
                numberOfEpisodes = value(.numberOfEpisodes)
                inProduction = value(.inProduction)
                imdbID = value(.imdbID)
                externalIDs = value(.externalIDs)
                releaseDates = value(.releaseDates)
                contentRatings = value(.contentRatings)
                lastEpisodeToAir = value(.lastEpisodeToAir)
                nextEpisodeToAir = value(.nextEpisodeToAir)
            }
        }

        struct EpisodeDTO: Decodable {
            let episodeNumber: Int?
            let name: String?
            let overview: String?
            let stillPath: String?
            let airDate: String?
            let runtime: Int?
            let voteAverage: Double?
            enum CodingKeys: String, CodingKey {
                case name, overview, runtime
                case episodeNumber = "episode_number"
                case stillPath = "still_path"
                case airDate = "air_date"
                case voteAverage = "vote_average"
            }
        }

        struct Season: Decodable {
            let seasonNumber: Int?
            let name: String?
            let overview: String?
            let posterPath: String?
            let airDate: String?
            let episodes: Lossy<EpisodeDTO>?
            enum CodingKeys: String, CodingKey {
                case name, overview, episodes
                case seasonNumber = "season_number"
                case posterPath = "poster_path"
                case airDate = "air_date"
            }
        }

        struct PersonCredit: Decodable {
            let id: Int?
            let mediaType: String?
            let popularity: Double?
            let character: String?
            let genreIDs: [Int]?
            let adult: Bool?
            enum CodingKeys: String, CodingKey {
                case id, popularity, character, adult
                case mediaType = "media_type"
                case genreIDs = "genre_ids"
            }
        }

        struct PersonCredits: Decodable {
            let cast: Lossy<PersonCredit>?
            let crew: Lossy<PersonCredit>?
        }

        struct Person: Decodable {
            let id: Int
            let name: String?
            let biography: String?
            let birthday: String?
            let deathday: String?
            let placeOfBirth: String?
            let knownForDepartment: String?
            let profilePath: String?
            let popularity: Double?
            let combinedCredits: PersonCredits?
            enum CodingKeys: String, CodingKey {
                case id, name, biography, birthday, deathday, popularity
                case placeOfBirth = "place_of_birth"
                case knownForDepartment = "known_for_department"
                case profilePath = "profile_path"
                case combinedCredits = "combined_credits"
            }
        }

        struct FindEpisode: Decodable {
            let showID: Int?
            enum CodingKeys: String, CodingKey { case showID = "show_id" }
        }

        struct Find: Decodable {
            let movieResults: Lossy<IDOnly>?
            let tvResults: Lossy<IDOnly>?
            let tvEpisodeResults: Lossy<FindEpisode>?
            enum CodingKeys: String, CodingKey {
                case movieResults = "movie_results"
                case tvResults = "tv_results"
                case tvEpisodeResults = "tv_episode_results"
            }
        }
    }
}
