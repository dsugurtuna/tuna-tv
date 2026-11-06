import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TVMaze (no key) for series when TMDB is not configured. Requests go through `HostLimiter`
/// (api.tvmaze.com allows 20 calls / 10 s; the service additionally runs TVMaze work strictly one at a time).
public struct TVMazeClient: Sendable {
    public init(http: HTTPClient, limiter: HostLimiter) {
        self.fetcher = MetadataSupport.Fetcher(http: http, limiter: limiter)
    }

    let fetcher: MetadataSupport.Fetcher

    static let host = "api.tvmaze.com"
    static let base = "https://api.tvmaze.com"
    /// Minimum `TitleMatcher` score for the single-search hit; below it the multi-result search is consulted.
    static let acceptScore = 0.72

    /// singlesearch/shows?q=&embed[]=cast&embed[]=seasons, then shows/{id}/images -> metadata.
    /// When the single hit does not fit the name/year (e.g. a remake), search/shows picks the best candidate.
    public func show(named name: String, year: Int?) async throws -> MediaMetadata? {
        let query = name.tunaTrimmed
        guard !query.isEmpty else { return nil }
        let embeds: [(String, String)] = [("embed[]", "cast"), ("embed[]", "seasons")]
        var show = try await fetch("/singlesearch/shows", [("q", query)] + embeds, as: DTO.Show.self)
        if let hit = show, (hit.searchResult.map { TitleMatcher.score(title: query, year: year, candidate: $0) } ?? 0) < Self.acceptScore {
            show = nil
            let hits = try await fetch("/search/shows", [("q", query)], as: MetadataSupport.Lossy<DTO.SearchHit>.self)?.values ?? []
            let candidates = hits.compactMap { $0.show?.searchResult }
            if let best = TitleMatcher.best(title: query, year: year, candidates: candidates, threshold: Self.acceptScore) {
                show = try await fetch("/shows/\(best.id)", embeds, as: DTO.Show.self)
            }
        }
        guard let show, let id = show.id, id > 0 else { return nil }
        // Artwork is a bonus: a failure here keeps the show (its embedded poster is used instead).
        let images = (try? await fetch("/shows/\(id)/images", [], as: MetadataSupport.Lossy<DTO.Image>.self))?.values ?? []
        return Self.map(show, images: images, fetchedAt: Date())
    }

    /// shows/{id}/episodes grouped into seasons (specials without a number are skipped).
    public func episodes(showID: Int) async throws -> [SeasonMetadata] {
        guard showID > 0 else { throw TunaError.invalidInput("Invalid TVMaze show id \(showID)") }
        let list = try await fetch("/shows/\(showID)/episodes", [], as: MetadataSupport.Lossy<DTO.Episode>.self)?.values ?? []
        return Self.seasons(from: list)
    }

    // MARK: - Requests

    /// nil on 404 (TVMaze's "no such show"), throws `TunaError.http` on other failures.
    func fetch<T: Decodable>(_ path: String, _ query: [(String, String)], as type: T.Type) async throws -> T? {
        guard let url = MetadataSupport.makeURL(Self.base, path: path, query: query) else {
            throw TunaError.invalidInput("Could not build TVMaze request for \(path)")
        }
        let response = try await fetcher.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 20))
        if response.status == 404 { return nil }
        guard response.isSuccess else { throw TunaError.http(status: response.status, host: Self.host) }
        return try MetadataSupport.decode(T.self, from: response.body, context: "TVMaze \(path)")
    }

    // MARK: - Mapping

    static func map(_ show: DTO.Show, images: [DTO.Image], fetchedAt: Date) -> MediaMetadata {
        var m = MediaMetadata(kind: .series, source: .tvmaze, title: show.name ?? "", tvmazeID: show.id, fetchedAt: fetchedAt)
        m.imdbID = show.imdbID
        m.overview = show.summary.map(MetadataSupport.stripHTML)?.nonEmpty
        m.releaseDate = show.premiered
        m.firstAirDate = show.premiered
        m.lastAirDate = show.ended
        m.year = MetadataSupport.year(from: show.premiered)
        m.runtimeMinutes = MetadataSupport.positive(show.runtime) ?? MetadataSupport.positive(show.averageRuntime)
        m.genres = MetadataSupport.unique(show.genres)
        m.status = show.status
        switch show.status?.lowercased() {
        case "running", "in development": m.inProduction = true
        case "ended": m.inProduction = false
        default: m.inProduction = nil
        }
        m.voteAverage = show.rating
        m.popularity = show.weight
        if let code = show.language.flatMap(languageCode(forName:)) {
            m.originalLanguage = code
            m.spokenLanguages = [code]
        }
        if let channel = show.network ?? show.webChannel {
            if let country = channel.countryCode { m.originCountries = [country] }
            if let id = channel.id, let name = channel.name {
                m.networks = [Company(id: id, name: name, logoURL: nil, country: channel.countryCode)]
            }
        }
        m.homepage = show.officialSite

        func ranked(_ type: String) -> [DTO.Image] {
            images.enumerated().filter { $0.element.type == type }
                .sorted { lhs, rhs in
                    lhs.element.main != rhs.element.main ? lhs.element.main : lhs.offset < rhs.offset
                }
                .map { $0.element }
        }
        let backgrounds = ranked("background").compactMap { $0.url }
        m.posterURL = ranked("poster").first?.url ?? show.posterOriginal ?? show.posterMedium
        m.backdropURL = backgrounds.first
        m.backdrops = Array(MetadataSupport.unique(backgrounds).prefix(15))
        // "typography" is TVMaze's title treatment; only PNGs can carry the transparency a hero logo needs.
        m.logoURL = ranked("typography").first?.url.flatMap { $0.lowercased().hasSuffix(".png") ? $0 : nil }

        var cast: [CastMember] = []
        var positions: [Int: Int] = [:]
        for credit in show.cast {
            if let position = positions[credit.personID] {
                if let character = credit.character, cast[position].character?.contains(character) != true {
                    cast[position].character = [cast[position].character, character].compactMap { $0 }.joined(separator: " / ")
                }
                continue
            }
            guard cast.count < TMDBClient.castLimit else { continue }
            positions[credit.personID] = cast.count
            cast.append(CastMember(personID: credit.personID, name: credit.name, character: credit.character,
                                   profileURL: credit.imageURL, order: cast.count))
        }
        m.cast = cast

        let seasons = show.seasons.filter { $0.number > 0 }
        m.seasonCount = seasons.isEmpty ? nil : seasons.count
        let episodes = seasons.compactMap { $0.episodeOrder }.reduce(0, +)
        m.episodeCount = episodes > 0 ? episodes : nil
        return m
    }

    static func seasons(from episodes: [DTO.Episode]) -> [SeasonMetadata] {
        var bySeason: [Int: [DTO.Episode]] = [:]
        for episode in episodes {
            guard let season = episode.season, let number = episode.number, season >= 0, number > 0 else { continue }
            bySeason[season, default: []].append(episode)
        }
        return bySeason.keys.sorted().map { season in
            let list = (bySeason[season] ?? []).sorted { ($0.number ?? 0) < ($1.number ?? 0) }
            var seen = Set<Int>()
            let mapped = list.compactMap { episode -> EpisodeMetadata? in
                guard let number = episode.number, seen.insert(number).inserted else { return nil }
                return EpisodeMetadata(episodeNumber: number, name: episode.name, overview: episode.summary.map(MetadataSupport.stripHTML)?.nonEmpty,
                                       stillURL: episode.imageMedium ?? episode.imageOriginal, airDate: episode.airdate,
                                       runtimeMinutes: MetadataSupport.positive(episode.runtime), voteAverage: episode.rating)
            }
            return SeasonMetadata(seasonNumber: season, name: nil, overview: nil, posterURL: nil,
                                  airDate: list.first?.airdate, episodes: mapped)
        }
    }

    /// TVMaze spells languages out ("English"); MediaMetadata wants ISO 639-1.
    static func languageCode(forName name: String) -> String? {
        let key = name.tunaTrimmed.lowercased()
        if key.count == 2, key.allSatisfy({ $0.isASCII && $0.isLetter }) { return key }
        return languageCodes[key]
    }

    static let languageCodes: [String: String] = [
        "afrikaans": "af", "albanian": "sq", "amharic": "am", "arabic": "ar", "armenian": "hy", "azerbaijani": "az",
        "basque": "eu", "belarusian": "be", "bengali": "bn", "bosnian": "bs", "bulgarian": "bg", "burmese": "my",
        "catalan": "ca", "chinese": "zh", "mandarin": "zh", "cantonese": "zh", "croatian": "hr", "czech": "cs",
        "danish": "da", "dutch": "nl", "english": "en", "estonian": "et", "faroese": "fo", "filipino": "tl",
        "finnish": "fi", "french": "fr", "galician": "gl", "georgian": "ka", "german": "de", "greek": "el",
        "gujarati": "gu", "hebrew": "he", "hindi": "hi", "hungarian": "hu", "icelandic": "is", "indonesian": "id",
        "irish": "ga", "italian": "it", "japanese": "ja", "kannada": "kn", "kazakh": "kk", "khmer": "km",
        "korean": "ko", "kurdish": "ku", "kyrgyz": "ky", "lao": "lo", "latin": "la", "latvian": "lv",
        "lithuanian": "lt", "luxembourgish": "lb", "macedonian": "mk", "malay": "ms", "malayalam": "ml",
        "maltese": "mt", "marathi": "mr", "mongolian": "mn", "nepali": "ne", "norwegian": "no", "pashto": "ps",
        "persian": "fa", "polish": "pl", "portuguese": "pt", "punjabi": "pa", "romanian": "ro", "russian": "ru",
        "scottish gaelic": "gd", "serbian": "sr", "sinhala": "si", "slovak": "sk", "slovenian": "sl", "somali": "so",
        "spanish": "es", "swahili": "sw", "swedish": "sv", "tagalog": "tl", "tamil": "ta", "telugu": "te",
        "thai": "th", "turkish": "tr", "ukrainian": "uk", "urdu": "ur", "uzbek": "uz", "vietnamese": "vi",
        "welsh": "cy", "zulu": "zu",
    ]
}

// MARK: - Wire format

extension TVMazeClient {
    /// TVMaze objects, read loosely (a field with an unexpected type becomes nil instead of failing the show).
    /// Every nested object is decoded eagerly inside its own `init(from:)`.
    enum DTO {
        typealias Loose = MetadataSupport.LooseObject

        struct Channel: Decodable {
            let id: Int?
            let name: String?
            let countryCode: String?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                id = o.int("id")
                name = o.string("name")
                countryCode = o.decode(Country.self, "country")?.code
            }
        }

        struct Country: Decodable {
            let code: String?
            init(from decoder: Decoder) throws { code = try Loose(decoder).string("code")?.uppercased() }
        }

        struct Rating: Decodable {
            let average: Double?
            init(from decoder: Decoder) throws { average = try Loose(decoder).double("average") }
        }

        struct Externals: Decodable {
            let imdb: String?
            init(from decoder: Decoder) throws { imdb = try Loose(decoder).string("imdb") }
        }

        struct ImageSet: Decodable {
            let medium: String?
            let original: String?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                medium = o.string("medium")
                original = o.string("original")
            }
        }

        struct Named: Decodable {
            let id: Int?
            let name: String?
            let image: ImageSet?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                id = o.int("id")
                name = o.string("name")
                image = o.decode(ImageSet.self, "image")
            }
        }

        struct CastCredit: Decodable {
            let personID: Int
            let name: String
            let character: String?
            let imageURL: String?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                let person = o.decode(Named.self, "person")
                let character = o.decode(Named.self, "character")
                guard let id = person?.id, let name = person?.name else {
                    throw TunaError.decoding("TVMaze cast entry without a person")
                }
                personID = id
                self.name = name
                self.character = character?.name
                imageURL = person?.image?.medium ?? person?.image?.original ?? character?.image?.medium
            }
        }

        struct SeasonInfo: Decodable {
            let number: Int
            let episodeOrder: Int?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                guard let number = o.int("number") else { throw TunaError.decoding("TVMaze season without a number") }
                self.number = number
                episodeOrder = o.int("episodeOrder")
            }
        }

        struct Embedded: Decodable {
            let cast: [CastCredit]
            let seasons: [SeasonInfo]

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                cast = o.decode(MetadataSupport.Lossy<CastCredit>.self, "cast")?.values ?? []
                seasons = o.decode(MetadataSupport.Lossy<SeasonInfo>.self, "seasons")?.values ?? []
            }
        }

        /// A show object (also the `show` inside search hits).
        struct Show: Decodable {
            let id: Int?
            let name: String?
            let language: String?
            let genres: [String]
            let status: String?
            let runtime: Int?
            let averageRuntime: Int?
            let premiered: String?
            let ended: String?
            let officialSite: String?
            let rating: Double?
            let weight: Double?
            let network: Channel?
            let webChannel: Channel?
            let imdbID: String?
            let posterMedium: String?
            let posterOriginal: String?
            let summary: String?
            let cast: [CastCredit]
            let seasons: [SeasonInfo]

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                id = o.int("id")
                name = o.string("name")
                language = o.string("language")
                genres = o.strings("genres")
                status = o.string("status")
                runtime = o.int("runtime")
                averageRuntime = o.int("averageRuntime")
                premiered = o.string("premiered")
                ended = o.string("ended")
                officialSite = o.string("officialSite")
                rating = o.decode(Rating.self, "rating")?.average
                weight = o.double("weight")
                network = o.decode(Channel.self, "network")
                webChannel = o.decode(Channel.self, "webChannel")
                imdbID = o.decode(Externals.self, "externals")?.imdb
                let image = o.decode(ImageSet.self, "image")
                posterMedium = image?.medium
                posterOriginal = image?.original
                summary = o.string("summary")
                let embedded = o.decode(Embedded.self, "_embedded")
                cast = embedded?.cast ?? []
                seasons = embedded?.seasons ?? []
            }

            var searchResult: TMDBClient.SearchResult? {
                guard let id, let title = name?.nonEmpty else { return nil }
                return TMDBClient.SearchResult(id: id, title: title, originalTitle: nil, year: MetadataSupport.year(from: premiered),
                                               popularity: weight ?? 0, voteCount: 0, originalLanguage: nil)
            }
        }

        struct SearchHit: Decodable {
            let show: Show?
        }

        struct Resolution: Decodable {
            let url: String?
            init(from decoder: Decoder) throws { url = try Loose(decoder).string("url") }
        }

        struct Resolutions: Decodable {
            let original: Resolution?
            let medium: Resolution?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                original = o.decode(Resolution.self, "original")
                medium = o.decode(Resolution.self, "medium")
            }
        }

        struct Image: Decodable {
            let type: String?
            let main: Bool
            let url: String?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                type = o.string("type")?.lowercased()
                main = o.bool("main") ?? false
                let resolutions = o.decode(Resolutions.self, "resolutions")
                url = resolutions?.original?.url ?? resolutions?.medium?.url
            }
        }

        struct Episode: Decodable {
            let season: Int?
            let number: Int?
            let name: String?
            let summary: String?
            let airdate: String?
            let runtime: Int?
            let rating: Double?
            let imageMedium: String?
            let imageOriginal: String?

            init(from decoder: Decoder) throws {
                let o = try Loose(decoder)
                season = o.int("season")
                number = o.int("number")
                name = o.string("name")
                summary = o.string("summary")
                airdate = o.string("airdate")
                runtime = o.int("runtime")
                rating = o.decode(Rating.self, "rating")?.average
                let image = o.decode(ImageSet.self, "image")
                imageMedium = image?.medium
                imageOriginal = image?.original
            }
        }
    }
}
