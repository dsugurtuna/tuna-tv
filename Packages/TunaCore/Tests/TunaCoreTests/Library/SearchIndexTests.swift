import XCTest
@testable import TunaCore

final class SearchIndexTests: XCTestCase {
    func makeIndex() -> (SearchIndex, LF.Rich) {
        let rich = LF.rich()
        var movies = rich.movies
        var metadata = rich.metadata
        let matrix = LF.title("matrix", name: "The Matrix", year: 1999, tmdb: 603)
        let matrixVault = LF.title("matrixr", name: "Matrix Reloaded", year: 2003, placement: .vault(.highDefinition), quality: .fhd)
        let spider = LF.title("spider", name: "Spider-Man: No Way Home", year: 2021)
        let schindler = LF.title("schindler", name: "Schindler's List", year: 1993)
        let kurtlar = LF.title("kurtlar", .series, name: "Kurtlar Vadisi", year: 2003, languages: ["tr"])
        movies += [matrix, matrixVault, spider, schindler]
        metadata[matrix.id] = LF.md(title: "The Matrix", tmdb: 603, vote: 8.7, votes: 25_000, popularity: 90, year: 1999,
                                    genres: ["Science Fiction"],
                                    cast: [CastMember(personID: 6384, name: "Keanu Reeves", profileURL: "https://p/6384.jpg"),
                                           CastMember(personID: 2975, name: "Laurence Fishburne", order: 1)],
                                    keywords: ["simulation", "dystopia"])
        metadata[kurtlar.id] = LF.md(.series, title: "Valley of the Wolves", tmdb: 1, language: "tr", countries: ["TR"])
        let library = Library(catalog: CuratedCatalog(movies: movies, series: rich.series + [kurtlar], channels: rich.library.channels))
        let index = SearchIndex(library: library, metadata: metadata, guide: rich.guide, includeAdult: false, now: LF.now)
        return (index, rich)
    }

    func ids(_ hits: [SearchHit]) -> [String] { hits.map(\.id) }

    func testRelevancePrefixAndTypos() {
        let (index, _) = makeIndex()
        XCTAssertEqual(index.search("the matrix").first?.id, "t:movie:matrix:1999")
        XCTAssertEqual(index.search("matr").first?.id, "t:movie:matrix:1999")
        XCTAssertEqual(index.search("matirx").first?.id, "t:movie:matrix:1999")   // transposition
        XCTAssertEqual(index.search("mtrix").first?.id, "t:movie:matrix:1999")    // deletion
        XCTAssertEqual(index.search("spiderman").first?.id, "t:movie:spider:2021")
        XCTAssertEqual(index.search("spider man").first?.id, "t:movie:spider:2021")
        XCTAssertEqual(index.search("schindlers").first?.id, "t:movie:schindler:1993")
        XCTAssertEqual(index.search("SCHINDLER'S").first?.id, "t:movie:schindler:1993")
        XCTAssertEqual(index.search("vadisi").first?.id, "t:series:kurtlar")
        XCTAssertEqual(index.search("valley wolves").first?.id, "t:series:kurtlar")   // metadata title
        XCTAssertEqual(index.search("dystopia").first?.id, "t:movie:matrix:1999")     // keyword
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("qqqqzzzz").isEmpty)
        XCTAssertTrue(index.search("matrix", limit: 0).isEmpty)
        // Exact name beats a prefix match ("Movie 1" vs "Movie 10...19").
        XCTAssertEqual(index.search("movie 1").first?.primary, "Movie 1")
        XCTAssertEqual(index.search("movie", limit: 5).count, 5)
    }

    func testShowcaseAboveVaultAndScopes() {
        let (index, _) = makeIndex()
        let hits = index.search("matrix")
        let showcase = hits.firstIndex { $0.id == "t:movie:matrix:1999" }
        let vault = hits.firstIndex { $0.id == "t:movie:matrixr:2003" }
        XCTAssertNotNil(showcase)
        XCTAssertNotNil(vault)
        XCTAssertLessThan(showcase!, vault!)
        XCTAssertTrue(hits[vault!].secondary.contains("Vault"))
        XCTAssertTrue(index.search("matrix", scope: .series).isEmpty)
        XCTAssertEqual(index.search("show 1", scope: .series).first?.primary, "Show 1")
        XCTAssertFalse(index.search("adult").contains { $0.primary == "Adult Movie" })
        let sorted = hits.map(\.score)
        XCTAssertEqual(sorted, sorted.sorted(by: >))
    }

    func testPeopleChannelsAndPrograms() {
        let (index, _) = makeIndex()
        let keanu = index.search("keanu")
        XCTAssertEqual(keanu.first?.target, .person(id: 6384, name: "Keanu Reeves", profileURL: "https://p/6384.jpg"))
        XCTAssertTrue(keanu.contains { $0.id == "t:movie:matrix:1999" })
        XCTAssertEqual(index.search("BBC one").first?.id, "c:live:bbc:gb")
        XCTAssertTrue(index.search("bbc", includeChannels: false).isEmpty)
        let program = index.search("arsenal chelsea").first
        if case .program(let channelID, let p)? = program?.target {
            XCTAssertEqual(channelID, "live:sky:gb")
            XCTAssertEqual(p.title, "Arsenal vs Chelsea")
        } else { XCTFail("expected a programme hit") }
        XCTAssertEqual(index.search("late show").first?.secondary, "Next on BBC One")
        XCTAssertTrue(index.search("keanu", scope: .movie).allSatisfy { if case .title = $0.target { return true } else { return false } })
    }

    func testPerformanceOn150kTitles() {
        let words = ["star", "night", "shadow", "river", "storm", "dragon", "silent", "golden", "broken", "city", "last",
                     "dark", "wild", "secret", "empire", "ghost", "lost", "winter", "summer", "iron", "blood", "crystal",
                     "ocean", "fire", "moon", "king", "queen", "hunter", "garden", "machine", "letter", "voyage", "echo",
                     "legend", "planet", "harbor", "frontier", "kingdom", "promise", "mirror"]
        var movies: [Title] = []
        movies.reserveCapacity(150_000)
        for i in 0..<150_000 {
            let name = "\(words[i % 40].capitalized) \(words[(i / 40) % 40].capitalized) \(words[(i / 1600) % 40]) \(i)"
            movies.append(LF.title("syn\(i)", name: name, year: 1950 + i % 75, placement: i % 3 == 0 ? .vault(.legacy) : .showcase,
                                   quality: i % 2 == 0 ? .uhd : .hd, rating: Double(i % 10)))
        }
        let library = Library(catalog: CuratedCatalog(movies: movies))
        let index = SearchIndex(library: library, metadata: [:], guide: nil, includeAdult: false, now: LF.now)
        let queries = ["star", "night riv", "shadw", "dragon king", "golden", "legend mirror", "frontiar", "s", "ec", "crystal ocean 1"]
        _ = index.search("warm up")
        var total: TimeInterval = 0
        var worst: TimeInterval = 0
        for query in queries {
            let start = Date()
            let hits = index.search(query)
            let elapsed = Date().timeIntervalSince(start)
            total += elapsed
            worst = max(worst, elapsed)
            XCTAssertFalse(hits.isEmpty, query)
        }
        let average = total / Double(queries.count)
        print("SearchIndex 150k: average \(Int(average * 1000)) ms, worst \(Int(worst * 1000)) ms")
        XCTAssertLessThan(average, 0.015, "average search time over 150k titles")
        XCTAssertEqual(index.search("shadw").first.map { $0.primary.lowercased().contains("shadow") }, true)
    }
}
