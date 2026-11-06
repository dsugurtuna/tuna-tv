import XCTest
@testable import TunaCore

final class GridTests: XCTestCase {
    func testFilters() {
        let rich = LF.rich()
        let context = rich.context()
        func grid(_ kind: TitleKind?, _ filter: BrowseFilter) -> [Title] { RailComposer.grid(kind, filter: filter, context) }

        XCTAssertEqual(grid(nil, BrowseFilter()).count, 50)
        XCTAssertEqual(grid(.movie, BrowseFilter()).count, 30)
        XCTAssertTrue(grid(.movie, BrowseFilter(genre: "drama")).allSatisfy { ["movie:m1:1991", "movie:m4:1994"].contains($0.id) || $0.id.hasPrefix("movie:") })
        XCTAssertEqual(grid(.movie, BrowseFilter(genre: "Drama")).count, 10)
        XCTAssertEqual(grid(nil, BrowseFilter(genre: "Drama")).count, 20)
        XCTAssertEqual(grid(nil, BrowseFilter(decade: 1990)).map(\.year).compactMap { $0 }.filter { $0 < 1990 || $0 > 1999 }, [])
        XCTAssertEqual(grid(nil, BrowseFilter(decade: 1990)).count, 10)
        XCTAssertEqual(grid(.movie, BrowseFilter(minRating: 9.0)).count, 6)       // 9.2 and 9.6
        XCTAssertEqual(grid(nil, BrowseFilter(country: "tr")).count, 16)
        XCTAssertEqual(grid(.series, BrowseFilter(language: "TR")).count, 10)
        XCTAssertEqual(grid(.movie, BrowseFilter(minQuality: .uhd)).count, 15)
        XCTAssertEqual(grid(.movie, BrowseFilter(genre: "Action", decade: 2000, minQuality: .uhd)).map(\.id),
                       grid(.movie, BrowseFilter(genre: "Action", decade: 2000)).filter { $0.bestQuality == .uhd }.map(\.id))
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "collection:77")).map(\.id), ["movie:m0:1990", "movie:m1:1991"])
        XCTAssertEqual(grid(.series, BrowseFilter(seeAllKey: "world:TR")).count, 10)
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "world:lang:tr")).count, 16)
        XCTAssertEqual(grid(.movie, BrowseFilter(seeAllKey: "top:series")).first?.kind, .series)
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "acclaimed:all")).map(\.id).sorted(),
                       ["movie:m17:2007", "movie:m18:2008", "movie:m27:2017", "movie:m28:2018", "movie:m7:1997", "movie:m8:1998"])
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "gems:all")).count, 24)
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "decade:2010")).count, 20)
        XCTAssertEqual(grid(nil, BrowseFilter(seeAllKey: "unknown:key")).count, 50)
        XCTAssertFalse(grid(nil, BrowseFilter()).contains { $0.isAdult || !$0.placement.isShowcase })
    }

    func testSorts() {
        let rich = LF.rich()
        let context = rich.context()
        func grid(_ sort: BrowseFilter.Sort, kind: TitleKind? = .movie) -> [Title] {
            RailComposer.grid(kind, filter: BrowseFilter(sort: sort), context)
        }
        let recommended = grid(.recommended).map { Ranker.score($0, metadata: rich.metadata[$0.id], now: LF.now) }
        XCTAssertEqual(recommended, recommended.sorted(by: >))
        let topRated = grid(.topRated).map { t -> Double in
            let md = rich.metadata[t.id]!
            return Ranker.weightedRating(average: md.voteAverage!, votes: md.voteCount!)
        }
        XCTAssertEqual(topRated, topRated.sorted(by: >))
        XCTAssertEqual(grid(.newest).first?.id, "movie:m29:2019")
        XCTAssertEqual(grid(.newest).last?.id, "movie:m0:1990")
        XCTAssertEqual(grid(.recentlyAdded).first?.id, "movie:m0:1990")
        XCTAssertEqual(grid(.recentlyAdded, kind: nil).prefix(2).map(\.id), ["movie:m0:1990", "series:s0"])
        let names = grid(.alphabetical).map { TextTokens.sortKey($0.name) }
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(grid(.popularity).first?.id, "movie:m29:2019")
        // Keyed lists keep their own order under .recommended and re-sort otherwise.
        let keyed = RailComposer.grid(nil, filter: BrowseFilter(sort: .alphabetical, seeAllKey: "collection:77"), context).map(\.id)
        XCTAssertEqual(keyed, ["movie:m0:1990", "movie:m1:1991"])
        let popular = RailComposer.grid(nil, filter: BrowseFilter(sort: .popularity, seeAllKey: "collection:77"), context).map(\.id)
        XCTAssertEqual(popular, ["movie:m1:1991", "movie:m0:1990"])
        for sort in BrowseFilter.Sort.allCases { XCTAssertEqual(grid(sort).count, 30, sort.rawValue) }
    }
}
