import XCTest
@testable import TunaCore

final class RailComposerTests: XCTestCase {
    func homeState() -> UserState {
        var state = UserState()
        state.progress["movie:m0:1990"] = WatchProgress(titleID: "movie:m0:1990", variantID: "v", position: 600, duration: 6000,
                                                         updatedAt: LF.now.addingTimeInterval(-100))
        state.progress["series:s3"] = WatchProgress(titleID: "series:s3", variantID: "v", position: 300, duration: 2400,
                                                     updatedAt: LF.now.addingTimeInterval(-50))
        state.progress["movie:v0:1981"] = WatchProgress(titleID: "movie:v0:1981", variantID: "v", position: 300, duration: 6000,
                                                         updatedAt: LF.now.addingTimeInterval(-10))
        // Show 3 (Comedy: only 9 other comedy series) cannot fill a rail; Movie 0 and Movie 3 can.
        state.history = [HistoryEntry(kind: .title, itemID: "series:s3", watchedAt: LF.now.addingTimeInterval(-50)),
                         HistoryEntry(kind: .title, itemID: "movie:m3:1993", watchedAt: LF.now.addingTimeInterval(-200))]
        state.favoriteChannels = ["live:bbc:gb", "live:trt:gb"]
        return state
    }

    func rail(_ rails: [Rail], _ id: String) -> Rail? { rails.first { $0.id == id } }

    func testHomeRailsFollowTheRules() {
        let rich = LF.rich()
        let context = rich.context(userState: homeState(), trendingMovies: [1003, 1029, 99_999, 1001, 9000],
                                   trendingSeries: [5004, 5001])
        let rails = RailComposer.home(context)
        let ids = rails.map(\.id)
        XCTAssertEqual(Array(ids.prefix(5)), ["hero", "continue", "top10:movie", "top10:series", "live-now"])
        XCTAssertEqual(Set(ids).count, ids.count)
        let showcase = Set((rich.library.showcase(.movie) + rich.library.showcase(.series)).map(\.id))
        for rail in rails {
            XCTAssertFalse(rail.items.isEmpty, rail.id)
            XCTAssertLessThanOrEqual(rail.items.count, 24, rail.id)
            let titleIDs = LF.titleIDs(rail)
            XCTAssertEqual(Set(titleIDs).count, titleIDs.count, rail.id)
            XCTAssertTrue(titleIDs.allSatisfy(showcase.contains), "\(rail.id) has non-showcase content")
            switch rail.style {
            case .poster, .landscape: XCTAssertGreaterThanOrEqual(rail.items.count, 10, rail.id)
            case .top10: XCTAssertLessThanOrEqual(rail.items.count, 10)
            default: break
            }
        }

        let hero = rail(rails, "hero")!
        XCTAssertEqual(hero.style, .hero)
        XCTAssertEqual(hero.items.count, 6)
        let heroIDs = Set(LF.titleIDs(hero))
        for other in rails[1...2] { XCTAssertTrue(heroIDs.isDisjoint(with: LF.titleIDs(other)), other.id) }
        XCTAssertTrue(heroIDs.contains { rich.library.title($0)?.languages == ["tr"] }, "hero mixes in the Turkish world")
        XCTAssertGreaterThanOrEqual(heroIDs.filter { $0.hasPrefix("series:") }.count, 2)

        let cw = rail(rails, "continue")!
        XCTAssertEqual(cw.style, .continueWatching)
        XCTAssertEqual(LF.titleIDs(cw), ["series:s3", "movie:m0:1990"])   // Vault title skipped, newest first

        let topMovies = rail(rails, "top10:movie")!
        XCTAssertEqual(topMovies.style, .top10)
        XCTAssertEqual(topMovies.seeAllKey, "top:movie")
        let scores = LF.titleIDs(topMovies).map { id -> Double in
            let t = rich.library.title(id)!
            return Ranker.score(t, metadata: rich.metadata[id], now: LF.now)
        }
        XCTAssertEqual(scores, scores.sorted(by: >))

        let live = rail(rails, "live-now")!
        XCTAssertEqual(live.style, .liveNow)
        XCTAssertEqual(live.items.map(\.id), ["l:live:bbc:gb", "l:live:sky:gb"])
        if case .live(_, let program)? = live.items.first { XCTAssertEqual(program?.title, "News at Ten") } else { XCTFail() }

        let trending = rail(rails, "trending")
        XCTAssertNil(trending, "only 5 trending titles in the catalog: below the 10-item floor")

        let newArrivals = rail(rails, "new")!
        XCTAssertEqual(newArrivals.seeAllKey, "new:all")
        XCTAssertEqual(Array(LF.titleIDs(newArrivals).prefix(3)), ["movie:m0:1990", "series:s0", "movie:m1:1991"])

        let uhd = rail(rails, "uhd")!
        XCTAssertTrue(LF.titleIDs(uhd).allSatisfy { rich.library.title($0)!.bestQuality == .uhd })

        let because = rails.filter { $0.id.hasPrefix("because:") }
        XCTAssertEqual(because.map(\.title), ["Because You Watched Movie 0", "Because You Watched Movie 3"])
        XCTAssertEqual(Array(LF.titleIDs(because[0]).prefix(3)), ["movie:m7:1997", "movie:m6:1996", "movie:m5:1995"])
        XCTAssertFalse(LF.titleIDs(because[0]).contains("movie:m0:1990"))
        XCTAssertEqual(because[1].seeAllKey, "because:movie:m3:1993")

        XCTAssertNil(rail(rails, "acclaimed"))
        let gems = rail(rails, "gems")!
        XCTAssertEqual(gems.items.count, 24)

        let world = rail(rails, "world:TR")!
        XCTAssertEqual(world.title, "From Türkiye")
        XCTAssertEqual(world.seeAllKey, "world:TR")
        XCTAssertEqual(world.items.count, 16)

        let genres = rails.filter { $0.id.hasPrefix("genre:") }.map(\.title)
        XCTAssertEqual(genres, ["Action", "Comedy", "Drama", "Crime", "Thriller"])

        let collection = rail(rails, "collection:77")!
        XCTAssertEqual(collection.style, .collections)
        XCTAssertEqual(LF.titleIDs(collection), ["movie:m0:1990", "movie:m1:1991"])
        XCTAssertEqual(rails.last?.id, "collection:77")
    }

    func testSeeAllKeysReproduceRails() {
        let rich = LF.rich()
        let context = rich.context(userState: homeState(), trendingMovies: Array(1000..<1030), trendingSeries: [5004, 5001])
        // The router opens "See all" with the page's kind (nil on Home).
        let pages: [(TitleKind?, [Rail])] = [(nil, RailComposer.home(context)), (.movie, RailComposer.browse(.movie, context)),
                                             (.series, RailComposer.browse(.series, context))]
        let rails = pages.flatMap { page in page.1.map { (page.0, $0) } }.map { $0 }
        var checked = 0
        for (kind, rail) in rails {
            guard let key = rail.seeAllKey, rail.style != .continueWatching else { continue }
            let grid = RailComposer.grid(kind, filter: BrowseFilter(seeAllKey: key), context).map(\.id)
            XCTAssertEqual(Array(grid.prefix(rail.items.count)), LF.titleIDs(rail), key)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
        let trending = rails.first { $0.1.id == "trending" }!.1
        XCTAssertEqual(Array(LF.titleIDs(trending).prefix(4)), ["movie:m0:1990", "series:s4", "movie:m1:1991", "series:s1"])
    }

    func testBrowseIsKindFilteredWithDecades() {
        let rich = LF.rich()
        let context = rich.context(userState: homeState())
        let rails = RailComposer.browse(.movie, context)
        XCTAssertEqual(rails.first?.id, "hero")
        for rail in rails {
            XCTAssertTrue(LF.titleIDs(rail).allSatisfy { $0.hasPrefix("movie:") }, rail.id)
        }
        XCTAssertEqual(rails.filter { $0.id.hasPrefix("decade:") }.map(\.title), ["Best of the 2010s", "Best of the 2000s", "Best of the 1990s"])
        XCTAssertNotNil(rails.first { $0.id == "top10:movie" })
        XCTAssertNil(rails.first { $0.id == "top10:series" })
        let series = RailComposer.browse(.series, context)
        XCTAssertTrue(series.contains { $0.id == "world:TR" && $0.items.count == 10 })
        XCTAssertTrue(RailComposer.home(RailContext(library: .empty, metadata: [:], userState: UserState(),
                                                    preferences: ContentPreferences())).isEmpty)
    }

    func testSimilarAndPersonCredits() {
        let rich = LF.rich()
        let context = rich.context()
        let m0 = rich.library.title("movie:m0:1990")!
        let similar = RailComposer.similar(to: m0, context, limit: 5)
        XCTAssertEqual(similar.map(\.id).prefix(3), ["movie:m7:1997", "movie:m6:1996", "movie:m5:1995"])
        XCTAssertEqual(similar.count, 5)
        XCTAssertFalse(similar.contains { $0.id == m0.id })
        // Same genre + collection beats genre alone: m1 (Drama) shares the collection.
        let m3 = rich.library.title("movie:m3:1993")!
        XCTAssertTrue(RailComposer.similar(to: m3, context).allSatisfy { !$0.id.hasPrefix("series:") })

        let person = PersonDetails(id: 42, name: "Keanu Reeves", movieCredits: [1010, 9000], tvCredits: [5002])
        let credited = RailComposer.titles(for: person, context).map(\.id)
        XCTAssertEqual(Set(credited), ["movie:m0:1990", "movie:m1:1991", "movie:m2:1992", "movie:m10:2000", "series:s2", "movie:v0:1981"])
        XCTAssertEqual(credited.last, "movie:v0:1981")   // Vault titles after showcase
    }
}
