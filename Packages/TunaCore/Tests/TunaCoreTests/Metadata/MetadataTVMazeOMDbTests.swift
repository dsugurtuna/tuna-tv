import Foundation
import XCTest
@testable import TunaCore

final class MetadataTVMazeOMDbTests: XCTestCase {
    private let tvmazeHost = "api.tvmaze.com"
    private let omdbHost = "www.omdbapi.com"

    private func tvmaze(_ http: MetadataFakeHTTP) -> TVMazeClient {
        TVMazeClient(http: http, limiter: MetadataTestKit.limiter())
    }

    private func omdb(_ http: MetadataFakeHTTP, key: String = "omdb-test-key") -> OMDbClient {
        OMDbClient(apiKey: key, http: http, limiter: MetadataTestKit.limiter())
    }

    // MARK: - TVMaze

    func testShowMapping() async throws {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/singlesearch/shows", query: ["q": "Breaking Bad"], fixture: "tvmaze-singlesearch-breaking-bad")
        http.on(tvmazeHost, "/shows/169/images", fixture: "tvmaze-show-169-images")
        let show = try await tvmaze(http).show(named: "Breaking Bad", year: 2008)
        let m = try XCTUnwrap(show)

        let search = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(search.url.path, "/singlesearch/shows")
        let items = MetadataTestKit.queryItems(search)
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "Breaking Bad")
        XCTAssertEqual(items.filter { $0.name == "embed[]" }.compactMap { $0.value }, ["cast", "seasons"])
        XCTAssertEqual(http.paths(host: tvmazeHost), ["/singlesearch/shows", "/shows/169/images"])

        XCTAssertEqual(m.kind, .series)
        XCTAssertEqual(m.source, .tvmaze)
        XCTAssertEqual(m.tvmazeID, 169)
        XCTAssertNil(m.tmdbID)
        XCTAssertEqual(m.imdbID, "tt0903747")
        XCTAssertEqual(m.title, "Breaking Bad")
        XCTAssertEqual(m.overview, """
            Breaking Bad follows protagonist Walter White, a chemistry teacher who lives in New Mexico with his wife and teenage son who has cerebral palsy. White is diagnosed with Stage III cancer and given a prognosis of two years left to live.

            With a new sense of fearlessness based on his medical prognosis, and a desire to secure his family's financial security, White chooses to enter a dangerous world of drugs & crime.
            """)
        XCTAssertEqual(m.genres, ["Drama", "Crime", "Thriller"])
        XCTAssertEqual(m.status, "Ended")
        XCTAssertEqual(m.inProduction, false)
        XCTAssertEqual(m.runtimeMinutes, 60)
        XCTAssertEqual(m.voteAverage, 9.2)
        XCTAssertEqual(m.popularity, 98)
        XCTAssertEqual(m.originalLanguage, "en")
        XCTAssertEqual(m.spokenLanguages, ["en"])
        XCTAssertEqual(m.originCountries, ["US"])
        XCTAssertEqual(m.networks, [Company(id: 20, name: "AMC", logoURL: nil, country: "US")])
        XCTAssertEqual(m.homepage, "http://www.amc.com/shows/breaking-bad")
        XCTAssertEqual(m.releaseDate, "2008-01-20")
        XCTAssertEqual(m.firstAirDate, "2008-01-20")
        XCTAssertEqual(m.lastAirDate, "2013-09-29")
        XCTAssertEqual(m.year, 2008)
        XCTAssertEqual(m.posterURL, "https://static.tvmaze.com/uploads/images/original_untouched/501/1253519.jpg")
        // The main background first.
        XCTAssertEqual(m.backdropURL, "https://static.tvmaze.com/uploads/images/original_untouched/2/4490.jpg")
        XCTAssertEqual(m.backdrops, ["https://static.tvmaze.com/uploads/images/original_untouched/2/4490.jpg",
                                     "https://static.tvmaze.com/uploads/images/original_untouched/2/4489.jpg"])
        XCTAssertEqual(m.logoURL, "https://static.tvmaze.com/uploads/images/original_untouched/0/67890.png")
        XCTAssertEqual(m.cast.map { $0.name }, ["Bryan Cranston", "Aaron Paul", "Anna Gunn"])
        XCTAssertEqual(m.cast[0], CastMember(personID: 14245, name: "Bryan Cranston", character: "Walter White",
                                             profileURL: "https://static.tvmaze.com/uploads/images/medium_portrait/0/1815.jpg", order: 0))
        // No person photo: the character image stands in.
        XCTAssertEqual(m.cast[2].profileURL, "https://static.tvmaze.com/uploads/images/medium_portrait/0/2143.jpg")
        XCTAssertEqual(m.seasonCount, 5)
        XCTAssertEqual(m.episodeCount, 62)
        XCTAssertNil(m.certification)
    }

    func testUnknownShowReturnsNil() async throws {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/singlesearch/shows", status: 404, body: Data(#"{"name":"Not Found","status":404}"#.utf8))
        let show = try await tvmaze(http).show(named: "No Such Show", year: nil)
        XCTAssertNil(show)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRateLimitIsAnError() async {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/singlesearch/shows", status: 429, body: Data())
        do {
            _ = try await tvmaze(http).show(named: "Breaking Bad", year: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TunaError, .http(status: 429, host: "api.tvmaze.com"))
        }
    }

    func testYearMismatchFallsBackToMultiSearch() async throws {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/singlesearch/shows", fixture: "tvmaze-singlesearch-shameless-uk")
        http.on(tvmazeHost, "/search/shows", fixture: "tvmaze-search-shameless")
        http.on(tvmazeHost, "/shows/150", fixture: "tvmaze-show-150")
        http.on(tvmazeHost, "/shows/150/images", body: Data("[]".utf8))
        let shameless = try await tvmaze(http).show(named: "Shameless", year: 2011)
        let m = try XCTUnwrap(shameless)
        XCTAssertEqual(http.paths(host: tvmazeHost), ["/singlesearch/shows", "/search/shows", "/shows/150", "/shows/150/images"])
        let refetch = http.requests[2]
        XCTAssertEqual(MetadataTestKit.queryItems(refetch).filter { $0.name == "embed[]" }.compactMap { $0.value }, ["cast", "seasons"])
        XCTAssertEqual(m.tvmazeID, 150)
        XCTAssertEqual(m.year, 2011)
        XCTAssertEqual(m.runtimeMinutes, 55)
        XCTAssertEqual(m.inProduction, false)
        XCTAssertEqual(m.cast.first?.character, "Frank Gallagher")
        XCTAssertEqual(m.seasonCount, 2)
        XCTAssertEqual(m.episodeCount, 24)
        // No images: the show's own poster is used.
        XCTAssertEqual(m.posterURL, "https://static.tvmaze.com/uploads/images/original_untouched/298/745362.jpg")
        XCTAssertNil(m.backdropURL)
    }

    func testEpisodesGroupedIntoSeasons() async throws {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/shows/169/episodes", fixture: "tvmaze-show-169-episodes")
        let seasons = try await tvmaze(http).episodes(showID: 169)
        XCTAssertEqual(seasons.map { $0.seasonNumber }, [1, 2])
        XCTAssertEqual(seasons[0].episodes.map { $0.episodeNumber }, [1, 2])
        XCTAssertEqual(seasons[0].airDate, "2008-01-20")
        XCTAssertEqual(seasons[0].episodes[0], EpisodeMetadata(
            episodeNumber: 1, name: "Pilot",
            overview: "When an unassuming high school chemistry teacher discovers he has a rare form of lung cancer, he decides to team up with a former student.",
            stillURL: "https://static.tvmaze.com/uploads/images/medium_landscape/27/68840.jpg", airDate: "2008-01-20",
            runtimeMinutes: 60, voteAverage: 8.2))
        XCTAssertNil(seasons[1].episodes[0].stillURL)
    }

    func testLanguageNamesBecomeISOCodes() {
        XCTAssertEqual(TVMazeClient.languageCode(forName: "English"), "en")
        XCTAssertEqual(TVMazeClient.languageCode(forName: "Turkish"), "tr")
        XCTAssertEqual(TVMazeClient.languageCode(forName: "Korean"), "ko")
        XCTAssertEqual(TVMazeClient.languageCode(forName: "Scottish Gaelic"), "gd")
        XCTAssertEqual(TVMazeClient.languageCode(forName: "de"), "de")
        XCTAssertNil(TVMazeClient.languageCode(forName: "Klingon"))
    }

    func testStripHTML() {
        XCTAssertEqual(MetadataSupport.stripHTML("<p><b>Lost</b> is a <i>show</i> &amp; more&hellip;</p>"), "Lost is a show & more…")
        XCTAssertEqual(MetadataSupport.stripHTML("<p>One</p><p>Two<br>Three</p>"), "One\n\nTwo\nThree")
        XCTAssertEqual(MetadataSupport.stripHTML("Tom &#39;n&#x27; Jerry &lt;3"), "Tom 'n' Jerry <3")
        XCTAssertEqual(MetadataSupport.stripHTML("  plain   text  "), "plain text")
        XCTAssertEqual(MetadataSupport.stripHTML("AT&T &unknown; rocks"), "AT&T &unknown; rocks")
    }

    // MARK: - OMDb

    func testOMDbRatingsParsing() async throws {
        let http = MetadataFakeHTTP()
        http.on(omdbHost, "/", query: ["i": "tt0133093"], fixture: "omdb-tt0133093")
        let ratings = try await omdb(http).ratings(imdbID: "tt0133093")
        XCTAssertEqual(ratings.imdb, 8.7)
        XCTAssertEqual(ratings.votes, 2_103_474)
        XCTAssertEqual(ratings.rottenTomatoes, 83)
        XCTAssertEqual(ratings.metacritic, 73)
        XCTAssertEqual(ratings.awards, "Won 4 Oscars. 42 wins & 52 nominations total")
        XCTAssertEqual(ratings.boxOffice, "$172,076,928")
        let query = MetadataTestKit.query(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(query["i"], "tt0133093")
        XCTAssertEqual(query["apikey"], "omdb-test-key")
        XCTAssertEqual(http.requests.first?.url.absoluteString.hasPrefix("https://www.omdbapi.com/?"), true)
    }

    func testOMDbNotAvailableValuesBecomeNil() async throws {
        let http = MetadataFakeHTTP()
        http.on(omdbHost, "/", fixture: "omdb-tt0903747")
        let ratings = try await omdb(http).ratings(imdbID: "tt0903747")
        XCTAssertEqual(ratings.imdb, 9.5)
        XCTAssertEqual(ratings.votes, 2_140_505)
        XCTAssertNil(ratings.rottenTomatoes)
        XCTAssertNil(ratings.metacritic)
        XCTAssertNil(ratings.boxOffice)
        XCTAssertEqual(ratings.awards, "Won 16 Primetime Emmys. 163 wins & 271 nominations total")
    }

    func testOMDbUnknownIDGivesNoValues() async throws {
        let http = MetadataFakeHTTP()
        http.on(omdbHost, "/", fixture: "omdb-not-found")
        let ratings = try await omdb(http).ratings(imdbID: "tt9999999")
        XCTAssertNil(ratings.imdb)
        XCTAssertNil(ratings.votes)
        XCTAssertNil(ratings.awards)
    }

    func testOMDbKeyAndLimitErrors() async {
        let http = MetadataFakeHTTP()
        http.on(omdbHost, "/", status: 401, fixture: "omdb-invalid-key")
        do {
            _ = try await omdb(http).ratings(imdbID: "tt0133093")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? TunaError, .unauthorized("OMDb key rejected"))
        }
        http.on(omdbHost, "/", status: 401, fixture: "omdb-limit")
        do {
            _ = try await omdb(http).ratings(imdbID: "tt0133093")
            XCTFail("expected limit")
        } catch {
            XCTAssertEqual(error as? TunaError, .http(status: 429, host: "www.omdbapi.com"))
        }
    }

    func testOMDbRejectsMalformedIDsWithoutNetwork() async {
        let http = MetadataFakeHTTP()
        do {
            _ = try await omdb(http).ratings(imdbID: "tt12&apikey=x")
            XCTFail("expected invalid input")
        } catch {
            guard case .invalidInput? = error as? TunaError else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(http.requests.isEmpty)
    }
}
