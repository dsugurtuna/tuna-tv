import Foundation
import XCTest
@testable import TunaCore

final class MetadataTMDBClientTests: XCTestCase {
    private let tmdbHost = "api.themoviedb.org"

    private func client(_ http: MetadataFakeHTTP, token: String = MetadataTestKit.v4Token, language: String = "en-US") -> TMDBClient {
        TMDBClient(keys: MetadataKeys(tmdb: token, language: language), http: http, limiter: MetadataTestKit.limiter())
    }

    // MARK: - Auth

    func testV3KeyIsSentAsAPIKeyQueryItem() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", fixture: "tmdb-search-movie-matrix")
        _ = try await client(http, token: MetadataTestKit.v3Key).search("The Matrix", kind: .movie, year: nil)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(MetadataTestKit.query(request)["api_key"], MetadataTestKit.v3Key)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.hostKey, tmdbHost)
    }

    func testV4TokenIsSentAsBearerHeader() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", fixture: "tmdb-search-movie-matrix")
        _ = try await client(http).search("The Matrix", kind: .movie, year: nil)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(MetadataTestKit.v4Token)")
        XCTAssertNil(MetadataTestKit.query(request)["api_key"])
    }

    func testCredentialDetection() {
        XCTAssertEqual(TMDBClient.credential(for: MetadataTestKit.v3Key), .apiKey(MetadataTestKit.v3Key))
        XCTAssertEqual(TMDBClient.credential(for: "0123456789ABCDEF0123456789ABCDEF"), .apiKey("0123456789ABCDEF0123456789ABCDEF"))
        // 32 characters but not hex, or hex but not 32 characters: bearer tokens.
        XCTAssertEqual(TMDBClient.credential(for: "0123456789abcdef0123456789abcdeg"), .bearer("0123456789abcdef0123456789abcdeg"))
        XCTAssertEqual(TMDBClient.credential(for: "0123456789abcdef"), .bearer("0123456789abcdef"))
        XCTAssertNil(TMDBClient.credential(for: nil))
        XCTAssertNil(TMDBClient.credential(for: "   "))
    }

    func testMissingKeyThrowsNotConfiguredWithoutNetwork() async {
        let http = MetadataFakeHTTP()
        let client = TMDBClient(keys: MetadataKeys(), http: http, limiter: MetadataTestKit.limiter())
        do {
            _ = try await client.details(id: 603, kind: .movie)
            XCTFail("expected notConfigured")
        } catch let error as TunaError {
            guard case .notConfigured = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: - Errors

    func testHTTP401MapsToUnauthorized() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", status: 401, fixture: "tmdb-error-401")
        do {
            _ = try await client(http).details(id: 603, kind: .movie)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? TunaError, .unauthorized("TMDB key rejected"))
        }
    }

    func testOtherFailuresMapToHTTPError() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", status: 503, body: Data("busy".utf8))
        do {
            _ = try await client(http).details(id: 603, kind: .movie)
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? TunaError, .http(status: 503, host: "api.themoviedb.org"))
        }
        do {
            _ = try await client(http).details(id: 999_999, kind: .movie)
            XCTFail("expected 404")
        } catch {
            XCTAssertEqual(error as? TunaError, .http(status: 404, host: "api.themoviedb.org"))
        }
    }

    func testGarbageBodyMapsToDecodingError() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", body: Data("<html>oops</html>".utf8))
        do {
            _ = try await client(http).details(id: 603, kind: .movie)
            XCTFail("expected decoding error")
        } catch {
            guard case .decoding? = error as? TunaError else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - Search

    func testSearchMovieSendsQueryYearAndMapsResults() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", query: ["year": "1999"], fixture: "tmdb-search-movie-matrix-1999")
        let results = try await client(http).search("The Matrix", kind: .movie, year: 1999)
        let request = try XCTUnwrap(http.requests.first)
        let query = MetadataTestKit.query(request)
        XCTAssertEqual(query["query"], "The Matrix")
        XCTAssertEqual(query["year"], "1999")
        XCTAssertEqual(query["include_adult"], "false")
        XCTAssertEqual(query["language"], "en-US")
        XCTAssertNil(query["first_air_date_year"])
        XCTAssertTrue(request.url.absoluteString.contains("query=The%20Matrix"), request.url.absoluteString)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first, TMDBClient.SearchResult(id: 603, title: "The Matrix", originalTitle: "The Matrix", year: 1999,
                                                              popularity: 81.613, voteCount: 26412, originalLanguage: "en"))
    }

    func testSearchTVUsesFirstAirDateYearAndNames() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/tv", fixture: "tmdb-search-tv-breaking-bad")
        let results = try await client(http).search("Breaking Bad", kind: .series, year: 2008)
        let query = MetadataTestKit.query(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(query["first_air_date_year"], "2008")
        XCTAssertNil(query["year"])
        XCTAssertEqual(results.map { $0.id }, [1396, 64409])
        XCTAssertEqual(results.first?.title, "Breaking Bad")
        XCTAssertEqual(results.first?.originalTitle, "Breaking Bad")
        XCTAssertEqual(results.first?.year, 2008)
    }

    func testSearchEscapesReservedCharacters() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", fixture: "tmdb-search-empty")
        _ = try await client(http).search("Fast & Furious + 6", kind: .movie, year: nil)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(MetadataTestKit.query(request)["query"], "Fast & Furious + 6")
        XCTAssertTrue(request.url.absoluteString.contains("Fast%20%26%20Furious%20%2B%206"), request.url.absoluteString)
    }

    // MARK: - Movie details

    func testMovieDetailsRequestAppendsEverything() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        _ = try await client(http).details(id: 603, kind: .movie)
        let query = MetadataTestKit.query(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(query["append_to_response"], "credits,videos,images,release_dates,keywords,recommendations,similar,external_ids")
        XCTAssertEqual(query["include_image_language"], "en,null")
        XCTAssertEqual(query["include_video_language"], "en")
        XCTAssertEqual(query["language"], "en-US")
    }

    func testMovieDetailsMapsEveryField() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        let m = try await client(http).details(id: 603, kind: .movie)

        XCTAssertEqual(m.kind, .movie)
        XCTAssertEqual(m.source, .tmdb)
        XCTAssertEqual(m.tmdbID, 603)
        XCTAssertEqual(m.imdbID, "tt0133093")
        XCTAssertNil(m.tvmazeID)
        XCTAssertEqual(m.title, "The Matrix")
        XCTAssertEqual(m.originalTitle, "The Matrix")
        XCTAssertEqual(m.tagline, "Welcome to the Real World.")
        XCTAssertTrue(m.overview?.hasPrefix("Set in the 22nd century") == true)
        XCTAssertEqual(m.releaseDate, "1999-03-31")
        XCTAssertEqual(m.year, 1999)
        XCTAssertEqual(m.runtimeMinutes, 136)
        XCTAssertEqual(m.genres, ["Action", "Science Fiction"])
        XCTAssertEqual(m.certification, "R")
        XCTAssertEqual(m.status, "Released")
        XCTAssertEqual(m.voteAverage, 8.218)
        XCTAssertEqual(m.voteCount, 26412)
        XCTAssertEqual(m.popularity, 81.613)
        XCTAssertEqual(m.originalLanguage, "en")
        XCTAssertEqual(m.spokenLanguages, ["en"])
        XCTAssertEqual(m.originCountries, ["US"])
        XCTAssertEqual(m.productionCountries, ["US", "AU"])
        XCTAssertEqual(m.displayCountries, ["US", "AU"])

        XCTAssertEqual(m.studios.map { $0.name }, ["Village Roadshow Pictures", "Groucho II Film Partnership", "Silver Pictures", "Warner Bros. Pictures"])
        XCTAssertEqual(m.studios[0], Company(id: 79, name: "Village Roadshow Pictures",
                                             logoURL: "https://image.tmdb.org/t/p/w92/at4uYdwAAgNRKhZuuFX8ShKSybw.png", country: "US"))
        XCTAssertNil(m.studios[1].logoURL)
        XCTAssertNil(m.studios[1].country)
        // SVG company logos are requested as rasterized PNGs.
        XCTAssertEqual(m.studios[3].logoURL, "https://image.tmdb.org/t/p/w92/zhD3hhtKB5qyv7ZeL4uLpNxgMVU.png")
        XCTAssertTrue(m.networks.isEmpty)

        XCTAssertEqual(m.posterURL, "https://image.tmdb.org/t/p/w500/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg")
        XCTAssertEqual(m.backdropURL, "https://image.tmdb.org/t/p/w1280/ncEsesgOJDNrTUED89hYbA117wo.jpg")
        // English logos first; the higher-rated one is an SVG served as PNG. Japanese logos are never used.
        XCTAssertEqual(m.logoURL, "https://image.tmdb.org/t/p/w500/vZB5ldQMLpgmOSWvHYXSMZFbqhy.png")
        // Textless backdrops first (best rated first), then English ones.
        XCTAssertEqual(m.backdrops, ["https://image.tmdb.org/t/p/w1280/7u3pxc0K1wx32IleAkLv78MKgrw.jpg",
                                     "https://image.tmdb.org/t/p/w1280/ncEsesgOJDNrTUED89hYbA117wo.jpg",
                                     "https://image.tmdb.org/t/p/w1280/l4QHerTSbMI7qgvasqxP36pqjN6.jpg"])

        // Cast: top 20 by `order`, one entry per person.
        XCTAssertEqual(m.cast.count, 20)
        XCTAssertEqual(m.cast.map { $0.order }, Array(0..<20))
        XCTAssertEqual(m.cast[0].personID, 6384)
        XCTAssertEqual(m.cast[0].name, "Keanu Reeves")
        XCTAssertEqual(m.cast[0].profileURL, "https://image.tmdb.org/t/p/w185/4D0PpNI0kmP58hgrwGC3wCjxhnm.jpg")
        XCTAssertEqual(m.cast[0].character, "Thomas A. Anderson / Neo / Neo (voice)")
        XCTAssertEqual(m.cast[1].name, "Laurence Fishburne")
        XCTAssertEqual(m.cast[1].character, "Morpheus")
        XCTAssertEqual(m.cast[10].name, "Julian Arahanga")
        XCTAssertNil(m.cast[10].profileURL)
        XCTAssertFalse(m.cast.contains(where: { $0.name == "Eleanor Witt" }))
        XCTAssertEqual(Set(m.cast.map { $0.personID }).count, 20)

        // Crew: interesting jobs only, most important first.
        XCTAssertEqual(m.crew.map { $0.job }, ["Director", "Director", "Writer", "Writer", "Original Music Composer",
                                              "Director of Photography", "Editor", "Producer"])
        XCTAssertEqual(m.crew[0], CrewMember(personID: 9340, name: "Lana Wachowski", job: "Director", department: "Directing",
                                             profileURL: "https://image.tmdb.org/t/p/w185/c7Elk9u1lWcmJNIcdsD5y4yT7xF.jpg"))
        XCTAssertFalse(m.crew.contains(where: { $0.job == "Stunt Coordinator" || $0.job == "Makeup Artist" }))
        XCTAssertEqual(m.directors, ["Lana Wachowski", "Lilly Wachowski"])
        XCTAssertEqual(m.writers, ["Lana Wachowski", "Lilly Wachowski"])
        XCTAssertTrue(m.creators.isEmpty)

        // Trailers: YouTube only; official trailers first, earliest first; then other trailers, teasers, extras.
        XCTAssertEqual(m.trailers.map { $0.youtubeKey }, ["vKQi3bBA1y8", "rerelease01", "frTrailer01", "fanTrailer01", "teaser00001", "bts000001"])
        XCTAssertEqual(m.trailers[0], Trailer(youtubeKey: "vKQi3bBA1y8", name: "Official Trailer", type: "Trailer", isOfficial: true))
        XCTAssertEqual(m.bestTrailer?.youtubeKey, "vKQi3bBA1y8")
        XCTAssertFalse(m.trailers.contains(where: { $0.youtubeKey == "123456789" }))

        XCTAssertEqual(m.keywords, ["saving the world", "artificial intelligence (a.i.)", "man vs machine", "philosophy", "dystopia", "cyberpunk"])
        XCTAssertEqual(m.collection, CollectionRef(id: 2344, name: "The Matrix Collection",
                                                   posterURL: "https://image.tmdb.org/t/p/w500/bV9qTVHTVf0gkW0j7p7M0ILD4pG.jpg",
                                                   backdropURL: "https://image.tmdb.org/t/p/w1280/bRm2DEgUiYciDw3myHuYFInD7la.jpg"))
        XCTAssertEqual(m.recommendationIDs, [604, 605, 1891])
        XCTAssertEqual(m.similarIDs, [1858, 2048])
        XCTAssertEqual(m.budget, 63_000_000)
        XCTAssertEqual(m.revenue, 463_517_383)
        XCTAssertEqual(m.homepage, "http://www.warnerbros.com/matrix")

        XCTAssertNil(m.seasonCount)
        XCTAssertNil(m.episodeCount)
        XCTAssertNil(m.firstAirDate)
        XCTAssertNil(m.lastAirDate)
        XCTAssertNil(m.inProduction)
        XCTAssertNil(m.imdbRating)
    }

    func testUserLanguagePicksLocalizedLogoAndTrailer() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        let m = try await client(http, language: "fr-FR").details(id: 603, kind: .movie)
        let query = MetadataTestKit.query(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(query["include_image_language"], "fr,en,null")
        XCTAssertEqual(query["include_video_language"], "fr,en")
        XCTAssertEqual(query["language"], "fr-FR")
        XCTAssertEqual(m.logoURL, "https://image.tmdb.org/t/p/w500/frLogoMatrix0001.png")
        XCTAssertEqual(m.bestTrailer?.youtubeKey, "frTrailer01")
    }

    func testLogoFallsBackToTextlessThenNothing() throws {
        let json = """
        [{"file_path": "/de.png", "iso_639_1": "de", "vote_average": 9.9},
         {"file_path": "/none.png", "iso_639_1": null, "vote_average": 1.0},
         {"file_path": "/xx.png", "iso_639_1": "xx", "vote_average": 2.0}]
        """
        let logos = try JSONDecoder().decode([TMDBClient.DTO.Image].self, from: Data(json.utf8))
        XCTAssertEqual(TMDBClient.pickLogo(logos, language: "tr")?.filePath, "/xx.png")
        XCTAssertNil(TMDBClient.pickLogo([logos[0]], language: "tr"))
        XCTAssertEqual(TMDBClient.pickLogo([logos[0]], language: "de")?.filePath, "/de.png")
    }

    func testCertificationFallbacks() throws {
        func movie(_ json: String) throws -> String? {
            TMDBClient.certification(movie: try JSONDecoder().decode(TMDBClient.DTO.ReleaseDates.self, from: Data(json.utf8)))
        }
        // US theatrical/digital preferred over other US releases.
        XCTAssertEqual(try movie(#"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"NR","type":1},{"certification":"PG","type":4}]}]}"#), "PG")
        // Any non-empty US certification next.
        XCTAssertEqual(try movie(#"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"","type":3},{"certification":"NR","type":1}]}]}"#), "NR")
        // No US: first non-empty certification of any country.
        XCTAssertEqual(try movie(#"{"results":[{"iso_3166_1":"FR","release_dates":[{"certification":"","type":3}]},{"iso_3166_1":"GB","release_dates":[{"certification":"15","type":3}]}]}"#), "15")
        XCTAssertNil(try movie(#"{"results":[]}"#))

        func tv(_ json: String) throws -> String? {
            TMDBClient.certification(tv: try JSONDecoder().decode(TMDBClient.DTO.ContentRatings.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try tv(#"{"results":[{"iso_3166_1":"DE","rating":"16"},{"iso_3166_1":"US","rating":"TV-14"}]}"#), "TV-14")
        XCTAssertEqual(try tv(#"{"results":[{"iso_3166_1":"DE","rating":""},{"iso_3166_1":"TR","rating":"18+"}]}"#), "18+")
    }

    // MARK: - TV details

    func testTVDetailsMapping() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/tv/1396", fixture: "tmdb-tv-1396")
        let m = try await client(http).details(id: 1396, kind: .series)
        let query = MetadataTestKit.query(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(query["append_to_response"], "aggregate_credits,credits,videos,images,content_ratings,keywords,recommendations,similar,external_ids")

        XCTAssertEqual(m.kind, .series)
        XCTAssertEqual(m.tmdbID, 1396)
        XCTAssertEqual(m.imdbID, "tt0903747")
        XCTAssertEqual(m.title, "Breaking Bad")
        XCTAssertEqual(m.originalTitle, "Breaking Bad")
        XCTAssertEqual(m.tagline, "Change the equation.")
        XCTAssertEqual(m.releaseDate, "2008-01-20")
        XCTAssertEqual(m.firstAirDate, "2008-01-20")
        XCTAssertEqual(m.lastAirDate, "2013-09-29")
        XCTAssertEqual(m.year, 2008)
        // episode_run_time is empty: the last aired episode's runtime is used.
        XCTAssertEqual(m.runtimeMinutes, 56)
        XCTAssertEqual(m.genres, ["Drama", "Crime"])
        XCTAssertEqual(m.certification, "TV-MA")
        XCTAssertEqual(m.status, "Ended")
        XCTAssertEqual(m.spokenLanguages, ["en", "es"])
        XCTAssertEqual(m.originCountries, ["US"])
        XCTAssertEqual(m.networks, [Company(id: 174, name: "AMC", logoURL: "https://image.tmdb.org/t/p/w92/alqLicR1ZMHMaZGP3xRQxn9sq7p.png", country: "US")])
        XCTAssertEqual(m.studios.count, 3)
        XCTAssertEqual(m.creators, ["Vince Gilligan"])
        XCTAssertEqual(m.seasonCount, 5)
        XCTAssertEqual(m.episodeCount, 62)
        XCTAssertEqual(m.inProduction, false)
        XCTAssertEqual(m.logoURL, "https://image.tmdb.org/t/p/w500/ggFHVNu6YYI5L9pCfOacjizRGt.png")

        // aggregate_credits: ordered, character from roles[0].
        XCTAssertEqual(m.cast.map { $0.name }, ["Bryan Cranston", "Aaron Paul", "Anna Gunn", "RJ Mitte", "Dean Norris"])
        XCTAssertEqual(m.cast[0].character, "Walter White")
        XCTAssertEqual(m.cast[1].character, "Jesse Pinkman")
        // Directors ordered by episode count; jobs flattened from aggregate crew.
        XCTAssertEqual(m.directors, ["Michelle MacLaren", "Vince Gilligan"])
        XCTAssertEqual(m.writers, ["Vince Gilligan"])
        XCTAssertTrue(m.crew.contains(CrewMember(personID: 1_223_192, name: "Dave Porter", job: "Original Music Composer", department: "Sound")))
        XCTAssertTrue(m.crew.contains(where: { $0.personID == 66633 && $0.job == "Executive Producer" }))
        XCTAssertFalse(m.crew.contains(where: { $0.job == "Driver" }))

        XCTAssertEqual(m.keywords, ["drug dealer", "high school teacher", "cancer", "methamphetamine"])
        XCTAssertEqual(m.trailers.map { $0.youtubeKey }, ["HhesaQXLuRY", "Wle5qn2tVjA"])
        XCTAssertEqual(m.recommendationIDs, [60059, 1398])
        XCTAssertEqual(m.similarIDs, [46648])
        XCTAssertEqual(m.homepage, "https://www.sonypictures.com/tv/breakingbad")
        XCTAssertNil(m.budget)
        XCTAssertNil(m.collection)
    }

    // MARK: - Season, person, trending, find

    func testSeasonMapping() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/tv/1396/season/1", fixture: "tmdb-tv-1396-season-1")
        let season = try await client(http).season(tvID: 1396, season: 1)
        XCTAssertEqual(season.seasonNumber, 1)
        XCTAssertEqual(season.name, "Season 1")
        XCTAssertEqual(season.airDate, "2008-01-20")
        XCTAssertEqual(season.posterURL, "https://image.tmdb.org/t/p/w500/1BP4xYv9ZG4ZVHkL7ocOziBbSYH.jpg")
        XCTAssertEqual(season.episodes.map { $0.episodeNumber }, [1, 2, 3])
        XCTAssertEqual(season.episodes[0], EpisodeMetadata(episodeNumber: 1, name: "Pilot", overview: season.episodes[0].overview,
                                                           stillURL: "https://image.tmdb.org/t/p/w300/ydlY3iPfeOAvu8gVqrxPoMvzNCn.jpg",
                                                           airDate: "2008-01-20", runtimeMinutes: 58, voteAverage: 8.3))
        XCTAssertTrue(season.episodes[0].overview?.hasPrefix("When an unassuming") == true)
        XCTAssertNil(season.episodes[2].stillURL)
        XCTAssertNil(season.episodes[2].voteAverage)
    }

    func testPersonMapping() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/person/6384", fixture: "tmdb-person-6384")
        let person = try await client(http).person(id: 6384)
        XCTAssertEqual(MetadataTestKit.query(try XCTUnwrap(http.requests.first))["append_to_response"], "combined_credits")
        XCTAssertEqual(person.id, 6384)
        XCTAssertEqual(person.name, "Keanu Reeves")
        XCTAssertEqual(person.birthday, "1964-09-02")
        XCTAssertNil(person.deathday)
        XCTAssertEqual(person.placeOfBirth, "Beirut, Lebanon")
        XCTAssertEqual(person.knownForDepartment, "Acting")
        XCTAssertEqual(person.profileURL, "https://image.tmdb.org/t/p/w185/4D0PpNI0kmP58hgrwGC3wCjxhnm.jpg")
        XCTAssertEqual(person.popularity, 49.987)
        XCTAssertTrue(person.biography?.contains("Canadian actor") == true)
        // Most popular first, cast and crew merged, deduplicated.
        XCTAssertEqual(person.movieCredits, [245891, 603, 604, 157353])
        // Talk-show guest spots and "Himself" appearances are not credits.
        XCTAssertEqual(person.tvCredits, [222766, 67221])
    }

    func testTrendingKeepsRankOrder() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/trending/movie/week", fixture: "tmdb-trending-movie-week")
        let ids = try await client(http).trending(kind: .movie, window: "week")
        XCTAssertEqual(ids, [1022789, 603, 533535])
        http.on(tmdbHost, "/3/trending/tv/day", fixture: "tmdb-trending-movie-week")
        _ = try await client(http).trending(kind: .series, window: "day")
        XCTAssertEqual(http.requests.last?.url.path, "/3/trending/tv/day")
    }

    func testFindByIMDbID() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/find/tt0133093", query: ["external_source": "imdb_id"], fixture: "tmdb-find-tt0133093")
        let found = try await client(http).find(imdbID: "tt0133093")
        XCTAssertEqual(found?.kind, .movie)
        XCTAssertEqual(found?.id, 603)
        do {
            _ = try await client(http).find(imdbID: "../movie/603")
            XCTFail("expected invalid input")
        } catch {
            guard case .invalidInput? = error as? TunaError else { return XCTFail("unexpected \(error)") }
        }
    }

    func testDetailsSurviveUnexpectedShapes() throws {
        let json = """
        {"id": 7, "title": "Odd", "runtime": "long", "genres": [{"id": 1, "name": "Drama"}, 5, null],
         "images": "none", "videos": {"results": [{"key": "abc", "site": "YouTube", "type": "Trailer"}, 42]},
         "credits": {"cast": [{"id": 1, "name": "A", "order": 0}, {"name": "No id"}]}}
        """
        let dto = try JSONDecoder().decode(TMDBClient.DTO.Details.self, from: Data(json.utf8))
        let m = TMDBClient.map(dto, kind: .movie, language: "en", fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.title, "Odd")
        XCTAssertNil(m.runtimeMinutes)
        XCTAssertEqual(m.genres, ["Drama"])
        XCTAssertEqual(m.trailers.map { $0.youtubeKey }, ["abc"])
        XCTAssertEqual(m.cast.map { $0.name }, ["A"])
        XCTAssertNil(m.logoURL)
    }
}
