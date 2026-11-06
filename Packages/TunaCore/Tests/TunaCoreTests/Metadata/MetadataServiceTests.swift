import Foundation
import XCTest
@testable import TunaCore

final class MetadataServiceTests: XCTestCase {
    private let tmdbHost = "api.themoviedb.org"
    private let tvmazeHost = "api.tvmaze.com"
    private let tmdbKeys = MetadataKeys(tmdb: MetadataTestKit.v4Token)

    /// Any /3/movie/<id> → The Matrix fixture (only the request order matters in queue tests).
    private func serveAnyMovie(_ http: MetadataFakeHTTP, status: Int = 200) {
        let body = (try? MetadataTestKit.fixture(status == 200 ? "tmdb-movie-603" : "tmdb-error-401")) ?? Data()
        http.on(where: { $0.url.host == "api.themoviedb.org" && $0.url.path.hasPrefix("/3/movie/") },
                respond: { HTTPResponse(status: status, body: body, url: $0.url) })
    }

    private func moviePaths(_ http: MetadataFakeHTTP) -> [String] {
        http.paths(host: tmdbHost).filter { $0.hasPrefix("/3/movie/") }
    }

    func testProviderTMDBIDResolvesAndMergesOMDb() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        http.on("www.omdbapi.com", "/", query: ["i": "tt0133093"], fixture: "omdb-tt0133093")
        let (service, store, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(tmdb: MetadataTestKit.v4Token, omdb: "omdbkey"), http: http)
        let title = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        let resolved = await service.metadata(for: title)
        let m = try XCTUnwrap(resolved)
        XCTAssertEqual(m.tmdbID, 603)
        XCTAssertEqual(m.imdbRating, 8.7)
        XCTAssertEqual(m.imdbVotes, 2_103_474)
        XCTAssertEqual(m.rottenTomatoes, 83)
        XCTAssertEqual(m.metacritic, 73)
        XCTAssertEqual(m.boxOffice, "$172,076,928")
        XCTAssertEqual(http.requests.count, 2)
        let stored = await store.metadata(for: title.id)
        XCTAssertEqual(stored, m)
    }

    func testSearchThenDetailsWithoutProviderID() async throws {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", query: ["year": "1999"], fixture: "tmdb-search-movie-matrix-1999")
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let m = await service.metadata(for: MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999))
        XCTAssertEqual(m?.tmdbID, 603)
        XCTAssertEqual(http.paths(host: tmdbHost), ["/3/search/movie", "/3/movie/603"])
    }

    func testSearchRetriesWithoutYear() async throws {
        let http = MetadataFakeHTTP()
        let empty = try MetadataTestKit.fixture("tmdb-search-empty")
        let full = try MetadataTestKit.fixture("tmdb-search-movie-matrix")
        http.on(where: { $0.url.path == "/3/search/movie" }, respond: { request in
            HTTPResponse(status: 200, body: MetadataTestKit.query(request)["year"] == nil ? full : empty, url: request.url)
        })
        http.on(tmdbHost, "/3/movie/603", fixture: "tmdb-movie-603")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let m = await service.metadata(for: MetadataTestKit.title("movie:matrix:2000", "The Matrix", year: 2000))
        XCTAssertEqual(m?.tmdbID, 603)
        let requests = http.requests
        XCTAssertEqual(requests.map { $0.url.path }, ["/3/search/movie", "/3/search/movie", "/3/movie/603"])
        XCTAssertEqual(MetadataTestKit.query(requests[0])["year"], "2000")
        XCTAssertNil(MetadataTestKit.query(requests[1])["year"])
    }

    func testNoMatchIsRecordedAsMissAndNotRetried() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/search/movie", fixture: "tmdb-search-movie-matrix")
        let (service, store, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let title = MetadataTestKit.title("movie:other:2010", "A Completely Different Film", year: 2010)
        let first = await service.metadata(for: title)
        XCTAssertNil(first)
        XCTAssertEqual(http.paths(host: tmdbHost), ["/3/search/movie", "/3/search/movie"])
        let missed = await store.isRecentMiss(title.id, now: Date())
        XCTAssertTrue(missed)
        http.clearLog()
        let second = await service.metadata(for: title)
        await service.enqueue([title], priority: .userInitiated)
        await service.waitForIdle()
        XCTAssertNil(second)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCacheHitsMakeZeroRequests() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, store, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let title = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        await store.store(MediaMetadata(kind: .movie, source: .tmdb, title: "The Matrix", tmdbID: 603), for: title.id)
        let cached = await service.metadata(for: title)
        await service.enqueue([title, title], priority: .background)
        await service.enqueue([title], priority: .userInitiated)
        await service.waitForIdle()
        XCTAssertEqual(cached?.title, "The Matrix")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testStaleCacheIsReturnedThenRefreshed() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, store, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let title = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        let old = MediaMetadata(kind: .movie, source: .tmdb, title: "Old Copy", tmdbID: 603, fetchedAt: Date().addingTimeInterval(-40 * 86_400))
        await store.store(old, for: title.id)
        let shown = await service.metadata(for: title)
        XCTAssertEqual(shown?.title, "Old Copy")
        await service.waitForIdle()
        let refreshed = await store.metadata(for: title.id)
        XCTAssertEqual(refreshed?.title, "The Matrix")
        XCTAssertEqual(moviePaths(http), ["/3/movie/603"])
    }

    func testUserInitiatedRunsBeforeBackgroundFIFO() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http, workers: 1)
        await service.setPaused(true)
        let background = (701...703).map { (id: Int) in MetadataTestKit.title("movie:t\(id):0", "Title \(id)", tmdbID: id) }
        await service.enqueue(background, priority: .background)
        await service.enqueue([MetadataTestKit.title("movie:t704:0", "Title 704", tmdbID: 704)], priority: .userInitiated)
        // Re-enqueueing a queued title at higher priority moves it up.
        await service.enqueue([background[2]], priority: .userInitiated)
        XCTAssertTrue(http.requests.isEmpty, "paused queue must not fetch")
        await service.setPaused(false)
        await service.waitForIdle()
        XCTAssertEqual(moviePaths(http), ["/3/movie/704", "/3/movie/703", "/3/movie/701", "/3/movie/702"])
    }

    func testTMDBConcurrencyIsCappedAtFour() async {
        let http = MetadataFakeHTTP(delay: 0.05)
        serveAnyMovie(http)
        let (service, store, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http, workers: 8)
        let titles = (1...12).map { MetadataTestKit.title("movie:c\($0):0", "Title \($0)", tmdbID: 800 + $0) }
        await service.enqueue(titles, priority: .background)
        await service.waitForIdle()
        XCTAssertEqual(http.requests.count, 12)
        XCTAssertLessThanOrEqual(http.peakConcurrency(host: tmdbHost), 4)
        XCTAssertGreaterThanOrEqual(http.peakConcurrency(host: tmdbHost), 2)
        let count = await store.allMetadata().count
        XCTAssertEqual(count, 12)
    }

    func testSeriesWithoutTMDBKeyUseTVMazeSerially() async {
        let http = MetadataFakeHTTP(delay: 0.03)
        http.on(tvmazeHost, "/singlesearch/shows", fixture: "tvmaze-singlesearch-breaking-bad")
        http.on(where: { $0.url.host == "api.tvmaze.com" && $0.url.path.hasSuffix("/images") },
                respond: { HTTPResponse(status: 200, body: Data("[]".utf8), url: $0.url) })
        let (service, store, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(), http: http)
        let series = (1...4).map { MetadataTestKit.title("series:bb\($0)", "Breaking Bad", kind: .series, year: 2008) }
        let movie = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        let movieResult = await service.metadata(for: movie)
        XCTAssertNil(movieResult)
        XCTAssertTrue(http.requests.isEmpty, "movies need TMDB: no request without a key")
        await service.enqueue(series + [movie], priority: .background)
        await service.waitForIdle()
        XCTAssertEqual(http.peakConcurrency(host: tvmazeHost), 1)
        XCTAssertTrue(http.requests(host: tmdbHost).isEmpty)
        let stored = await store.metadata(for: "series:bb1")
        XCTAssertEqual(stored?.source, .tvmaze)
        XCTAssertEqual(stored?.tvmazeID, 169)
        let movieMiss = await store.isRecentMiss(movie.id, now: Date())
        XCTAssertFalse(movieMiss, "a missing key is not a miss")
    }

    func testUpdatesStreamReachesEverySubscriber() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let first = await service.updates()
        let second = await service.updates()
        let titles = [MetadataTestKit.title("movie:u1:0", "U1", tmdbID: 901), MetadataTestKit.title("movie:u2:0", "U2", tmdbID: 902)]
        await service.enqueue(titles, priority: .background)
        await service.waitForIdle()
        let batchA = await MetadataTestKit.next(first)
        let batchB = await MetadataTestKit.next(second)
        XCTAssertEqual(Set(batchA ?? []), ["movie:u1:0", "movie:u2:0"])
        XCTAssertEqual(Set(batchB ?? []), ["movie:u1:0", "movie:u2:0"])
    }

    func testRejectedKeyStopsTMDBWork() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http, status: 401)
        let (service, store, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http, workers: 1)
        let titles = (1...3).map { MetadataTestKit.title("movie:r\($0):0", "R\($0)", tmdbID: 700 + $0) }
        await service.enqueue(titles, priority: .background)
        await service.waitForIdle()
        let direct = await service.metadata(for: MetadataTestKit.title("movie:r9:0", "R9", tmdbID: 709))
        XCTAssertNil(direct)
        XCTAssertEqual(http.requests.count, 1)
        let missed = await store.isRecentMiss("movie:r1:0", now: Date())
        XCTAssertFalse(missed)
        let trending = await service.trendingIDs(kind: .movie)
        XCTAssertEqual(trending, [])
        // A new key brings TMDB back.
        http.removeAllRoutes()
        serveAnyMovie(http)
        await service.updateKeys(MetadataKeys(tmdb: MetadataTestKit.v3Key))
        let resolved = await service.metadata(for: titles[0])
        XCTAssertEqual(resolved?.tmdbID, 603)
    }

    func testUpdateKeysEnablesTMDB() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, _, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(), http: http)
        let title = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        let before = await service.metadata(for: title)
        XCTAssertNil(before)
        XCTAssertTrue(http.requests.isEmpty)
        await service.updateKeys(tmdbKeys)
        let after = await service.metadata(for: title)
        XCTAssertEqual(after?.title, "The Matrix")
    }

    func testTrendingCachedAndEmptyWithoutKey() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/trending/movie/week", fixture: "tmdb-trending-movie-week")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let first = await service.trendingIDs(kind: .movie)
        let second = await service.trendingIDs(kind: .movie)
        XCTAssertEqual(first, [1022789, 603, 533535])
        XCTAssertEqual(second, first)
        XCTAssertEqual(http.requests.count, 1)

        let other = MetadataFakeHTTP()
        let (keyless, _, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(), http: other)
        let none = await keyless.trendingIDs(kind: .movie)
        XCTAssertEqual(none, [])
        XCTAssertTrue(other.requests.isEmpty)
    }

    func testSeasonAndPersonAreCached() async {
        let http = MetadataFakeHTTP()
        http.on(tmdbHost, "/3/tv/1396/season/1", fixture: "tmdb-tv-1396-season-1")
        http.on(tmdbHost, "/3/person/6384", fixture: "tmdb-person-6384")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let show = MetadataTestKit.title("series:breaking bad", "Breaking Bad", kind: .series, year: 2008)
        let season = await service.season(for: show, tvID: 1396, season: 1)
        let again = await service.season(for: show, tvID: 1396, season: 1)
        XCTAssertEqual(season?.episodes.count, 3)
        XCTAssertEqual(again, season)
        let person = await service.person(id: 6384)
        let personAgain = await service.person(id: 6384)
        XCTAssertEqual(person?.name, "Keanu Reeves")
        XCTAssertEqual(personAgain, person)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testTVMazeSeasonsForTVMazeMetadata() async {
        let http = MetadataFakeHTTP()
        http.on(tvmazeHost, "/singlesearch/shows", fixture: "tvmaze-singlesearch-breaking-bad")
        http.on(tvmazeHost, "/shows/169/images", fixture: "tvmaze-show-169-images")
        http.on(tvmazeHost, "/shows/169/episodes", fixture: "tvmaze-show-169-episodes")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(), http: http)
        let show = MetadataTestKit.title("series:breaking bad", "Breaking Bad", kind: .series, year: 2008)
        let m = await service.metadata(for: show)
        XCTAssertEqual(m?.tvmazeID, 169)
        let season = await service.season(for: show, tvID: 0, season: 2)
        let season1 = await service.season(for: show, tvID: 0, season: 1)
        XCTAssertEqual(season?.episodes.map { $0.name }, ["Seven Thirty-Seven"])
        XCTAssertEqual(season1?.episodes.count, 2)
        XCTAssertEqual(http.paths(host: tvmazeHost).filter { $0.hasSuffix("/episodes") }.count, 1)
    }

    func testChannelMatcherIsLoadedOnce() async {
        let http = MetadataFakeHTTP()
        http.on("iptv-org.github.io", "/api/channels.json", fixture: "iptvorg-channels")
        http.on("iptv-org.github.io", "/api/logos.json", fixture: "iptvorg-logos")
        let (service, _, _) = MetadataTestKit.service(for: self, keys: MetadataKeys(), http: http)
        let matcher = await service.channelMatcher()
        XCTAssertEqual(matcher?.match(name: "UK: BBC One FHD", countries: [], epgID: nil)?.id, "BBCOne.uk")
        http.clearLog()
        let again = await service.channelMatcher()
        XCTAssertEqual(again?.count, 27)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testFlushPersistsForNextLaunch() async {
        let http = MetadataFakeHTTP()
        serveAnyMovie(http)
        let (service, _, files) = MetadataTestKit.service(for: self, keys: tmdbKeys, http: http)
        let title = MetadataTestKit.title("movie:matrix:1999", "The Matrix", year: 1999, tmdbID: 603)
        _ = await service.metadata(for: title)
        await service.flush()
        let reloaded = await MetadataStore(files: files).metadata(for: title.id)
        XCTAssertEqual(reloaded?.tmdbID, 603)
    }

    func testSearchQueryCleaning() {
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "Breaking Bad S01", year: nil), "Breaking Bad")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "Dune 2021", year: 2021), "Dune")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "Blade Runner 2049", year: 2017), "Blade Runner 2049")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "1917", year: 2019), "1917")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "The.Matrix.1999", year: 1999), "The Matrix")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "Amélie (2001) [4K]", year: 2001), "Amélie")
        XCTAssertEqual(MetadataServiceCore.searchQuery(for: "Dark S01E02", year: nil), "Dark")
    }
}
