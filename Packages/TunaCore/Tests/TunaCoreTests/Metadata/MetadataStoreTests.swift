import Foundation
import XCTest
@testable import TunaCore

final class MetadataStoreTests: XCTestCase {
    private func sample(_ title: String, fetchedAt: Date = Date()) -> MediaMetadata {
        MediaMetadata(kind: .movie, source: .tmdb, title: title, tmdbID: 603, genres: ["Action"],
                      cast: [CastMember(personID: 6384, name: "Keanu Reeves", character: "Neo")],
                      fetchedAt: Date(timeIntervalSince1970: (fetchedAt.timeIntervalSince1970 * 1000).rounded() / 1000))
    }

    func testStoreFlushAndReloadFromShards() async throws {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        let ids = ["movie:matrix:1999", "movie:dune:2021", "series:breaking bad"]
        for id in ids { await store.store(sample(id), for: id) }
        await store.flush()

        for id in ids {
            let shard = MetadataStore.shard(for: id)
            XCTAssertEqual(shard.count, 2)
            XCTAssertTrue(files.exists("metadata/titles/\(shard).json"), "missing shard for \(id)")
        }
        let reloaded = MetadataStore(files: files)
        let all = await reloaded.allMetadata()
        XCTAssertEqual(Set(all.keys), Set(ids))
        let matrix = await reloaded.metadata(for: "movie:matrix:1999")
        let original = await store.metadata(for: "movie:matrix:1999")
        XCTAssertEqual(matrix, original)
    }

    func testShardIsStable() {
        XCTAssertEqual(MetadataStore.shard(for: "movie:matrix:1999"), MetadataStore.shard(for: "movie:matrix:1999"))
        XCTAssertEqual(MetadataSupport.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(MetadataSupport.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(MetadataStore.hex(0), "00")
        XCTAssertEqual(MetadataStore.hex(255), "ff")
    }

    func testMissTTL() async {
        let store = MetadataStore(files: MetadataTestKit.files(for: self))
        let now = Date()
        await store.markMiss("movie:x:0", at: now)
        let fresh = await store.isRecentMiss("movie:x:0", now: now)
        let sixDays = await store.isRecentMiss("movie:x:0", now: now.addingTimeInterval(6 * 86_400))
        let eightDays = await store.isRecentMiss("movie:x:0", now: now.addingTimeInterval(8 * 86_400))
        XCTAssertTrue(fresh)
        XCTAssertTrue(sixDays)
        XCTAssertFalse(eightDays)
        await store.store(sample("X"), for: "movie:x:0")
        let afterStore = await store.isRecentMiss("movie:x:0", now: now)
        XCTAssertFalse(afterStore)
    }

    func testMissesPersistAndExpiredOnesAreDropped() async {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        await store.markMiss("recent")
        await store.markMiss("old", at: Date().addingTimeInterval(-10 * 86_400))
        await store.flush()
        let reloaded = MetadataStore(files: files)
        let recent = await reloaded.isRecentMiss("recent", now: Date())
        let needed = await reloaded.idsNeedingFetch(["recent", "old"], now: Date())
        XCTAssertTrue(recent)
        XCTAssertEqual(needed, ["old"])
        await reloaded.clearMisses()
        let cleared = await reloaded.isRecentMiss("recent", now: Date())
        XCTAssertFalse(cleared)
    }

    func testDetailsTTLKeepsStaleDataButFlagsIt() async {
        let store = MetadataStore(files: MetadataTestKit.files(for: self))
        await store.store(sample("Old", fetchedAt: Date().addingTimeInterval(-31 * 86_400)), for: "old")
        await store.store(sample("New"), for: "new")
        let oldFresh = await store.isFresh("old")
        let newFresh = await store.isFresh("new")
        let oldValue = await store.metadata(for: "old")
        let needed = await store.idsNeedingFetch(["old", "new", "missing"], now: Date())
        XCTAssertFalse(oldFresh)
        XCTAssertTrue(newFresh)
        XCTAssertEqual(oldValue?.title, "Old")
        XCTAssertEqual(needed, ["old", "missing"])
    }

    func testSeasonTTLAndPersistence() async {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        let season = SeasonMetadata(seasonNumber: 1, name: "Season 1", episodes: [EpisodeMetadata(episodeNumber: 1, name: "Pilot")])
        await store.storeSeason(season, tvID: 1396)
        let cached = await store.season(tvID: 1396, season: 1)
        XCTAssertEqual(cached, season)
        let key = MetadataStore.seasonKey(source: .tmdb, showID: 1396, season: 2)
        var old = season
        old.seasonNumber = 2
        await store.storeSeason(old, key: key, at: Date().addingTimeInterval(-8 * 86_400))
        let expired = await store.season(tvID: 1396, season: 2)
        let stale = await store.cachedSeason(key: key, now: Date(), allowStale: true)
        XCTAssertNil(expired)
        XCTAssertEqual(stale, old)
        await store.flush()
        let reloaded = await MetadataStore(files: files).season(tvID: 1396, season: 1)
        XCTAssertEqual(reloaded, season)
    }

    func testPersonTTL() async {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        await store.storePerson(PersonDetails(id: 1, name: "Fresh"))
        await store.storePerson(PersonDetails(id: 2, name: "Stale", fetchedAt: Date().addingTimeInterval(-31 * 86_400)))
        let fresh = await store.person(1)
        let stale = await store.person(2)
        XCTAssertEqual(fresh?.name, "Fresh")
        XCTAssertNil(stale)
        await store.flush()
        let reloaded = await MetadataStore(files: files).person(1)
        XCTAssertEqual(reloaded?.name, "Fresh")
    }

    func testTrendingRoundTrip() async {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        await store.storeTrending([3, 1, 2], kind: .series, at: at)
        await store.flush()
        let reloaded = await MetadataStore(files: files).trending(kind: .series)
        XCTAssertEqual(reloaded?.ids, [3, 1, 2])
        XCTAssertEqual(reloaded?.fetchedAt, at)
        let movies = await store.trending(kind: .movie)
        XCTAssertNil(movies)
    }

    func testRemoveAllWipesDisk() async {
        let files = MetadataTestKit.files(for: self)
        let store = MetadataStore(files: files)
        await store.store(sample("A"), for: "a")
        await store.flush()
        await store.removeAll()
        let reloaded = await MetadataStore(files: files).allMetadata()
        XCTAssertTrue(reloaded.isEmpty)
    }
}
