import Foundation

public enum MetadataSource: String, Codable, Sendable, CaseIterable {
    case tmdb
    case tvmaze
    case omdb
    case provider
    case demo
}

public struct CastMember: Codable, Hashable, Sendable, Identifiable {
    /// TMDB person id (or TVMaze person id when `source == .tvmaze`), 0 when unknown.
    public var personID: Int
    public var name: String
    public var character: String?
    /// Full image URL (already sized, e.g. https://image.tmdb.org/t/p/w185/abc.jpg).
    public var profileURL: String?
    public var order: Int
    public var id: String { "\(personID)-\(name)-\(order)" }

    public init(personID: Int, name: String, character: String? = nil, profileURL: String? = nil, order: Int = 0) {
        self.personID = personID
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.order = order
    }
}

public struct CrewMember: Codable, Hashable, Sendable, Identifiable {
    public var personID: Int
    public var name: String
    /// "Director", "Screenplay", "Original Music Composer", "Director of Photography", "Producer" ...
    public var job: String
    public var department: String?
    public var profileURL: String?
    public var id: String { "\(personID)-\(job)" }

    public init(personID: Int, name: String, job: String, department: String? = nil, profileURL: String? = nil) {
        self.personID = personID
        self.name = name
        self.job = job
        self.department = department
        self.profileURL = profileURL
    }
}

public struct Company: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var logoURL: String?
    public var country: String?

    public init(id: Int, name: String, logoURL: String? = nil, country: String? = nil) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.country = country
    }
}

public struct Trailer: Codable, Hashable, Sendable, Identifiable {
    /// YouTube video key.
    public var youtubeKey: String
    public var name: String
    /// "Trailer", "Teaser", "Clip", "Featurette".
    public var type: String
    public var isOfficial: Bool
    public var id: String { youtubeKey }

    public init(youtubeKey: String, name: String, type: String = "Trailer", isOfficial: Bool = true) {
        self.youtubeKey = youtubeKey
        self.name = name
        self.type = type
        self.isOfficial = isOfficial
    }

    public var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(youtubeKey)") }
}

public struct CollectionRef: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var posterURL: String?
    public var backdropURL: String?

    public init(id: Int, name: String, posterURL: String? = nil, backdropURL: String? = nil) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.backdropURL = backdropURL
    }
}

/// Aggregated metadata for a movie or a series. Every field is optional because sources vary.
public struct MediaMetadata: Codable, Hashable, Sendable {
    public var kind: TitleKind
    public var source: MetadataSource
    public var tmdbID: Int?
    public var imdbID: String?
    public var tvmazeID: Int?

    public var title: String
    public var originalTitle: String?
    public var tagline: String?
    public var overview: String?
    public var releaseDate: String?
    public var year: Int?
    public var runtimeMinutes: Int?
    public var genres: [String]
    /// e.g. "PG-13", "TV-MA", "12".
    public var certification: String?
    public var status: String?

    // Ratings and popularity
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var imdbRating: Double?
    public var imdbVotes: Int?
    public var rottenTomatoes: Int?
    public var metacritic: Int?
    public var awards: String?
    public var boxOffice: String?

    // Origin
    public var originalLanguage: String?
    public var spokenLanguages: [String]
    public var originCountries: [String]
    public var productionCountries: [String]
    public var studios: [Company]
    public var networks: [Company]

    // Artwork (full URLs)
    public var posterURL: String?
    public var backdropURL: String?
    /// Transparent title treatment (TMDB "logos"), used on hero banners.
    public var logoURL: String?
    public var backdrops: [String]

    // People
    public var cast: [CastMember]
    public var crew: [CrewMember]
    public var directors: [String]
    public var writers: [String]
    public var creators: [String]

    // Extras
    public var trailers: [Trailer]
    public var keywords: [String]
    public var collection: CollectionRef?
    /// TMDB ids of recommended / similar titles (intersected with the catalog by the library).
    public var recommendationIDs: [Int]
    public var similarIDs: [Int]
    public var budget: Int?
    public var revenue: Int?
    public var homepage: String?

    // Series
    public var seasonCount: Int?
    public var episodeCount: Int?
    public var firstAirDate: String?
    public var lastAirDate: String?
    public var inProduction: Bool?

    public var fetchedAt: Date

    public init(kind: TitleKind, source: MetadataSource, title: String, tmdbID: Int? = nil, imdbID: String? = nil,
                tvmazeID: Int? = nil, originalTitle: String? = nil, tagline: String? = nil, overview: String? = nil,
                releaseDate: String? = nil, year: Int? = nil, runtimeMinutes: Int? = nil, genres: [String] = [],
                certification: String? = nil, status: String? = nil, voteAverage: Double? = nil, voteCount: Int? = nil,
                popularity: Double? = nil, imdbRating: Double? = nil, imdbVotes: Int? = nil, rottenTomatoes: Int? = nil,
                metacritic: Int? = nil, awards: String? = nil, boxOffice: String? = nil, originalLanguage: String? = nil,
                spokenLanguages: [String] = [], originCountries: [String] = [], productionCountries: [String] = [],
                studios: [Company] = [], networks: [Company] = [], posterURL: String? = nil, backdropURL: String? = nil,
                logoURL: String? = nil, backdrops: [String] = [], cast: [CastMember] = [], crew: [CrewMember] = [],
                directors: [String] = [], writers: [String] = [], creators: [String] = [], trailers: [Trailer] = [],
                keywords: [String] = [], collection: CollectionRef? = nil, recommendationIDs: [Int] = [],
                similarIDs: [Int] = [], budget: Int? = nil, revenue: Int? = nil, homepage: String? = nil,
                seasonCount: Int? = nil, episodeCount: Int? = nil, firstAirDate: String? = nil,
                lastAirDate: String? = nil, inProduction: Bool? = nil, fetchedAt: Date = Date()) {
        self.kind = kind
        self.source = source
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.tvmazeID = tvmazeID
        self.title = title
        self.originalTitle = originalTitle
        self.tagline = tagline
        self.overview = overview
        self.releaseDate = releaseDate
        self.year = year
        self.runtimeMinutes = runtimeMinutes
        self.genres = genres
        self.certification = certification
        self.status = status
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.popularity = popularity
        self.imdbRating = imdbRating
        self.imdbVotes = imdbVotes
        self.rottenTomatoes = rottenTomatoes
        self.metacritic = metacritic
        self.awards = awards
        self.boxOffice = boxOffice
        self.originalLanguage = originalLanguage
        self.spokenLanguages = spokenLanguages
        self.originCountries = originCountries
        self.productionCountries = productionCountries
        self.studios = studios
        self.networks = networks
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.logoURL = logoURL
        self.backdrops = backdrops
        self.cast = cast
        self.crew = crew
        self.directors = directors
        self.writers = writers
        self.creators = creators
        self.trailers = trailers
        self.keywords = keywords
        self.collection = collection
        self.recommendationIDs = recommendationIDs
        self.similarIDs = similarIDs
        self.budget = budget
        self.revenue = revenue
        self.homepage = homepage
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.firstAirDate = firstAirDate
        self.lastAirDate = lastAirDate
        self.inProduction = inProduction
        self.fetchedAt = fetchedAt
    }

    /// Countries to show as flags: production/origin countries, deduplicated, order kept.
    public var displayCountries: [String] {
        var seen = Set<String>()
        return (originCountries + productionCountries).filter { seen.insert($0.uppercased()).inserted }
    }

    public var bestTrailer: Trailer? {
        trailers.first(where: { $0.isOfficial && $0.type == "Trailer" }) ?? trailers.first
    }
}

/// TMDB season details (episode stills, names, overviews).
public struct SeasonMetadata: Codable, Hashable, Sendable {
    public var seasonNumber: Int
    public var name: String?
    public var overview: String?
    public var posterURL: String?
    public var airDate: String?
    public var episodes: [EpisodeMetadata]

    public init(seasonNumber: Int, name: String? = nil, overview: String? = nil, posterURL: String? = nil,
                airDate: String? = nil, episodes: [EpisodeMetadata] = []) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.overview = overview
        self.posterURL = posterURL
        self.airDate = airDate
        self.episodes = episodes
    }
}

public struct EpisodeMetadata: Codable, Hashable, Sendable, Identifiable {
    public var episodeNumber: Int
    public var name: String?
    public var overview: String?
    public var stillURL: String?
    public var airDate: String?
    public var runtimeMinutes: Int?
    public var voteAverage: Double?
    public var id: Int { episodeNumber }

    public init(episodeNumber: Int, name: String? = nil, overview: String? = nil, stillURL: String? = nil,
                airDate: String? = nil, runtimeMinutes: Int? = nil, voteAverage: Double? = nil) {
        self.episodeNumber = episodeNumber
        self.name = name
        self.overview = overview
        self.stillURL = stillURL
        self.airDate = airDate
        self.runtimeMinutes = runtimeMinutes
        self.voteAverage = voteAverage
    }
}

/// A person page (actor/director).
public struct PersonDetails: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var biography: String?
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    public var knownForDepartment: String?
    public var profileURL: String?
    public var popularity: Double?
    /// TMDB ids of movies/series this person is credited on.
    public var movieCredits: [Int]
    public var tvCredits: [Int]
    public var fetchedAt: Date

    public init(id: Int, name: String, biography: String? = nil, birthday: String? = nil, deathday: String? = nil,
                placeOfBirth: String? = nil, knownForDepartment: String? = nil, profileURL: String? = nil,
                popularity: Double? = nil, movieCredits: [Int] = [], tvCredits: [Int] = [], fetchedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.knownForDepartment = knownForDepartment
        self.profileURL = profileURL
        self.popularity = popularity
        self.movieCredits = movieCredits
        self.tvCredits = tvCredits
        self.fetchedAt = fetchedAt
    }
}

/// iptv-org channel record (subset we keep on device).
public struct IPTVOrgChannel: Codable, Hashable, Sendable, Identifiable {
    /// e.g. "BBCOne.uk"
    public var id: String
    public var name: String
    public var altNames: [String]
    public var network: String?
    public var owners: [String]
    public var country: String
    public var categories: [String]
    public var isNSFW: Bool
    public var launched: String?
    public var closed: String?
    public var replacedBy: String?
    public var website: String?
    public var logoURL: String?
    public var languages: [String]

    public init(id: String, name: String, altNames: [String] = [], network: String? = nil, owners: [String] = [],
                country: String, categories: [String] = [], isNSFW: Bool = false, launched: String? = nil,
                closed: String? = nil, replacedBy: String? = nil, website: String? = nil, logoURL: String? = nil,
                languages: [String] = []) {
        self.id = id
        self.name = name
        self.altNames = altNames
        self.network = network
        self.owners = owners
        self.country = country
        self.categories = categories
        self.isNSFW = isNSFW
        self.launched = launched
        self.closed = closed
        self.replacedBy = replacedBy
        self.website = website
        self.logoURL = logoURL
        self.languages = languages
    }
}
