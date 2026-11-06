import XCTest
@testable import TunaCore

final class LibraryIndexTests: XCTestCase {
    func testLookups() {
        let rich = LF.rich()
        let lib = rich.library
        XCTAssertEqual(lib.title("movie:m3:1993")?.name, "Movie 3")
        XCTAssertEqual(lib.title("series:s2")?.kind, .series)
        XCTAssertNil(lib.title("nope"))
        XCTAssertEqual(lib.channel("live:bbc:gb")?.name, "BBC One")
        let movieVariant = rich.movies[4].variants[0]
        let hit = lib.variant(movieVariant.id)
        XCTAssertEqual(hit?.title?.id, "movie:m4:1994")
        XCTAssertNil(hit?.channel)
        let channelHit = lib.variant("p|live|live-sky")
        XCTAssertEqual(channelHit?.channel?.id, "live:sky:gb")
        XCTAssertNil(channelHit?.title)
        XCTAssertNil(lib.variant("missing"))
        XCTAssertTrue(Library.empty.movies.isEmpty)
        XCTAssertNil(Library.empty.title("x"))
    }

    func testTMDBLookups() {
        let rich = LF.rich()
        let lib = rich.library
        XCTAssertEqual(lib.titles(tmdbIDs: [1005, 1002, 999_999], kind: .movie).map(\.id), ["movie:m5:1995", "movie:m2:1992"])
        XCTAssertTrue(lib.titles(tmdbIDs: [1005], kind: .series).isEmpty)
        // A title without providerTMDBID is found through metadata.
        let plain = LF.title("plain", year: 2001)
        let library = Library(catalog: CuratedCatalog(movies: [plain]))
        let meta = [plain.id: LF.md(title: "Plain", tmdb: 4242)]
        XCTAssertTrue(library.titles(tmdbIDs: [4242], kind: .movie).isEmpty)
        XCTAssertEqual(library.titles(tmdbIDs: [4242], kind: .movie, metadata: meta).map(\.id), [plain.id])
        XCTAssertTrue(library.titles(tmdbIDs: [4242], kind: .series, metadata: meta).isEmpty)
        // Cache invalidates when the metadata changes.
        let other = [plain.id: LF.md(title: "Plain", tmdb: 77)]
        XCTAssertEqual(library.titles(tmdbIDs: [77], kind: nil, metadata: other).count, 1)
        XCTAssertTrue(library.titles(tmdbIDs: [4242], kind: nil, metadata: other).isEmpty)
    }

    func testShowcaseVaultAndAdult() {
        let lib = LF.rich().library
        XCTAssertEqual(lib.showcase(.movie).count, 30)
        XCTAssertEqual(lib.showcase(.series).count, 20)
        XCTAssertEqual(lib.vault(.otherLanguages, kind: .movie).map(\.name), ["Das Boot"])
        XCTAssertEqual(lib.vault(.legacy, kind: nil).count, 1)
        XCTAssertTrue(lib.vault(.legacy, kind: .series).isEmpty)
        XCTAssertEqual(lib.vault(.adult, kind: nil).map(\.name), ["Adult Movie"])
        XCTAssertEqual(lib.vaultChannels(.otherLanguages).map(\.name), ["TRT 1"])
        XCTAssertEqual(lib.vaultCounts[.otherLanguages], 2)
        XCTAssertEqual(lib.vaultCounts[.disc], 0)
        XCTAssertEqual(lib.liveShowcase.count, 2)
        // An adult title mislabelled as showcase still lands on the adult shelf.
        let sneaky = LF.title("sneaky", adult: true)
        let library = Library(catalog: CuratedCatalog(movies: [sneaky]))
        XCTAssertTrue(library.showcase(.movie).isEmpty)
        XCTAssertEqual(library.vault(.adult, kind: .movie).count, 1)
    }

    func testOtherLanguageGroups() {
        let titles = [
            LF.title("a", placement: .vault(.otherLanguages), languages: ["de"]),
            LF.title("b", placement: .vault(.otherLanguages), languages: ["fr"]),
            LF.title("c", placement: .vault(.otherLanguages), languages: ["fr"]),
            LF.title("d", placement: .vault(.otherLanguages), languages: [], countries: ["IT"]),
            LF.title("e", placement: .vault(.otherLanguages), languages: []),
            LF.title("f", .series, placement: .vault(.otherLanguages), languages: ["de"]),
        ]
        let lib = Library(catalog: CuratedCatalog(movies: titles.filter { $0.kind == .movie }, series: titles.filter { $0.kind == .series }))
        let groups = lib.otherLanguageGroups(kind: .movie)
        XCTAssertEqual(groups.map(\.language), ["fr", "de", "it", "und"])
        XCTAssertEqual(groups.first?.titles.count, 2)
        XCTAssertEqual(lib.otherLanguageGroups(kind: nil).prefix(2).map(\.language), ["de", "fr"])
        XCTAssertEqual(lib.otherLanguageGroups(kind: .series).map(\.language), ["de"])
    }

    func testChannelCategoriesAndGroups() {
        let channels = [
            LF.channel("a", categories: [.news], group: "UK"), LF.channel("b", categories: [.news, .general], group: "UK"),
            LF.channel("c", categories: [.sports], group: "Sports"), LF.channel("d", group: nil),
            LF.channel("e", placement: .vault(.otherLanguages), categories: [.news], group: "UK"),
            LF.channel("x", categories: [.xxx], adult: true),
        ]
        let lib = Library(catalog: CuratedCatalog(channels: channels))
        XCTAssertEqual(lib.channelCategories.first?.category, .news)
        XCTAssertEqual(lib.channelCategories.first?.count, 2)
        XCTAssertEqual(lib.channels(in: .other).map(\.id), ["live:d:gb"])
        XCTAssertTrue(lib.channels(in: .xxx).isEmpty)
        XCTAssertEqual(lib.channelGroups.map(\.name), ["UK", "Other", "Sports"])
        XCTAssertEqual(lib.vaultCounts[.adult], 1)
    }

    func testGenresPreferMetadataAndCanonicalize() {
        let a = LF.title("a", genres: ["SCI-FI"]), b = LF.title("b", genres: ["Documentaries"]), c = LF.title("c", genres: ["Horror"])
        let v = LF.title("v", placement: .vault(.legacy), genres: ["Western"])
        let lib = Library(catalog: CuratedCatalog(movies: [a, b, c, v]))
        let meta = [c.id: LF.md(title: "C", genres: ["Science Fiction", "Action & Adventure"])]
        let genres = lib.genres(.movie, metadata: meta)
        XCTAssertEqual(genres.first?.genre, "Science Fiction")
        XCTAssertEqual(genres.first?.count, 2)
        XCTAssertTrue(genres.contains { $0.genre == "Documentary" })
        XCTAssertTrue(genres.contains { $0.genre == "Adventure" })
        XCTAssertFalse(genres.contains { $0.genre == "Horror" || $0.genre == "Western" })
    }

    func testTokens() {
        XCTAssertEqual(TextTokens.split("Spider-Man: Schindler's List").words, ["spider", "man", "schindlers", "list"])
        XCTAssertEqual(TextTokens.split("Spider-Man").compounds, ["spiderman"])
        XCTAssertEqual(TextTokens.words("Kurtlar Vadisi İstanbul Işık"), ["kurtlar", "vadisi", "istanbul", "isik"])
        XCTAssertEqual(TextTokens.sortKey("The Matrix"), "matrix")
    }
}

final class RankerTests: XCTestCase {
    func testWeightedRating() {
        XCTAssertEqual(Ranker.weightedRating(average: 9, votes: 0), 6.8, accuracy: 1e-9)
        XCTAssertEqual(Ranker.weightedRating(average: 9, votes: 500), 7.9, accuracy: 1e-9)
        XCTAssertEqual(Ranker.weightedRating(average: 8, votes: 100, m: 100, c: 6), 7, accuracy: 1e-9)
        XCTAssertGreaterThan(Ranker.weightedRating(average: 9, votes: 10_000), 8.8)
    }

    func testScoreMonotonicity() {
        let now = LF.now
        let base = LF.title("x", year: 2015, quality: .hd, addedDaysAgo: 100, rating: 6)
        let md = LF.md(title: "X", vote: 8, votes: 1000, popularity: 50, year: 2015)
        let s = Ranker.score(base, metadata: md, now: now)
        var more = md; more.voteCount = 5000
        XCTAssertGreaterThan(Ranker.score(base, metadata: more, now: now), s)
        var higher = md; higher.voteAverage = 8.5
        XCTAssertGreaterThan(Ranker.score(base, metadata: higher, now: now), s)
        var popular = md; popular.popularity = 500
        XCTAssertGreaterThan(Ranker.score(base, metadata: popular, now: now), s)
        var newer = md; newer.releaseDate = "2026-06-01"
        XCTAssertGreaterThan(Ranker.score(base, metadata: newer, now: now), s)
        var uhd = base; uhd.bestQuality = .uhd
        XCTAssertGreaterThan(Ranker.score(uhd, metadata: md, now: now), s)
        var fresh = base; fresh.addedAt = now
        XCTAssertGreaterThan(Ranker.score(fresh, metadata: md, now: now), s)
        var rated = base; rated.providerRating = 9
        XCTAssertGreaterThan(Ranker.score(rated, metadata: md, now: now), s)
        // Without metadata: provider rating, recency and quality still order titles.
        XCTAssertGreaterThan(Ranker.score(rated, metadata: nil, now: now), Ranker.score(base, metadata: nil, now: now))
        XCTAssertGreaterThan(Ranker.score(uhd, metadata: nil, now: now), Ranker.score(base, metadata: nil, now: now))
        XCTAssertGreaterThan(Ranker.score(fresh, metadata: nil, now: now), Ranker.score(base, metadata: nil, now: now))
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 1)
    }

    func testCivilDate() {
        XCTAssertEqual(CivilDate.parse("1970-01-02")?.timeIntervalSince1970, 86_400)
        XCTAssertEqual(CivilDate.parse("2000-03-01")?.timeIntervalSince1970, 951_868_800)
        XCTAssertNil(CivilDate.parse("soon"))
        XCTAssertEqual(CivilDate.year("1999-12-31"), 1999)
    }
}
