import Foundation
import XCTest
@testable import TunaCore

final class CacheStoreTests: XCTestCase {
    private var files: FileStore!
    private var cache: CacheStore!
    private let fetched = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        files = FileStore.temporary()
        cache = CacheStore(files: files)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: files.baseURL)
        files = nil
        cache = nil
        super.tearDown()
    }

    func testStoreAndReadBackWithFetchTime() throws {
        let payload = Data(#"[{"stream_id":1}]"#.utf8)
        try cache.store(payload, for: "providers/p1/vod_streams.json", fetchedAt: fetched)
        let entry = try XCTUnwrap(cache.entry("providers/p1/vod_streams.json"))
        XCTAssertEqual(entry.data, payload)
        XCTAssertEqual(entry.fetchedAt, fetched)
        XCTAssertEqual(cache.fetchedAt("providers/p1/vod_streams.json"), fetched)
        // The data sits at exactly files.url(for: key), so big entries can be streamed from disk.
        XCTAssertEqual(try Data(contentsOf: files.url(for: "providers/p1/vod_streams.json")), payload)
        // The sidecar is hidden from listings.
        XCTAssertEqual(files.list("providers/p1"), ["vod_streams.json"])
        XCTAssertNil(cache.entry("providers/p1/missing.json"))
    }

    func testFreshnessWindow() throws {
        try cache.store(Data("x".utf8), for: "k.json", fetchedAt: fetched)
        XCTAssertNotNil(cache.fresh("k.json", maxAge: 600, now: fetched))
        XCTAssertNotNil(cache.fresh("k.json", maxAge: 600, now: fetched.addingTimeInterval(599)))
        XCTAssertNil(cache.fresh("k.json", maxAge: 600, now: fetched.addingTimeInterval(600)), "exactly maxAge old is stale")
        XCTAssertNil(cache.fresh("k.json", maxAge: 600, now: fetched.addingTimeInterval(86_400)))
        XCTAssertNotNil(cache.entry("k.json"), "stale entries are still readable")
        // A fetch time in the future (clock changed) is not trusted beyond maxAge.
        XCTAssertNotNil(cache.fresh("k.json", maxAge: 600, now: fetched.addingTimeInterval(-300)))
        XCTAssertNil(cache.fresh("k.json", maxAge: 600, now: fetched.addingTimeInterval(-3600)))
        XCTAssertNil(cache.fresh("missing.json", maxAge: 600, now: fetched))
    }

    func testMissingOrMismatchedSidecarFallsBackToTheFileDate() throws {
        try files.writeData(Data("written directly".utf8), to: "direct/file.json")
        let direct = try XCTUnwrap(cache.entry("direct/file.json"))
        XCTAssertLessThan(abs(direct.fetchedAt.timeIntervalSinceNow), 300)

        try cache.store(Data("v1".utf8), for: "torn.json", fetchedAt: fetched)
        // Simulate a crash after the data write but before the sidecar write.
        try files.writeData(Data("version two".utf8), to: "torn.json")
        let torn = try XCTUnwrap(cache.entry("torn.json"))
        XCTAssertEqual(torn.data, Data("version two".utf8))
        XCTAssertLessThan(abs(torn.fetchedAt.timeIntervalSinceNow), 300)

        try cache.store(Data("v1".utf8), for: "badmeta.json", fetchedAt: fetched)
        try files.writeData(Data("garbage".utf8), to: CacheStore.metaPath(for: "badmeta.json"))
        XCTAssertNotNil(cache.entry("badmeta.json"))
    }

    func testRemoveAndRemoveAllByPrefix() throws {
        try cache.store(Data("1".utf8), for: "providers/a/live.json", fetchedAt: fetched)
        try cache.store(Data("2".utf8), for: "providers/a/vod/info_1.json", fetchedAt: fetched)
        try cache.store(Data("3".utf8), for: "providers/ab/live.json", fetchedAt: fetched)
        try cache.store(Data("4".utf8), for: "providers/b/live.json", fetchedAt: fetched)
        try cache.store(Data("5".utf8), for: "top.json", fetchedAt: fetched)

        cache.remove("top.json")
        XCTAssertNil(cache.entry("top.json"))
        XCTAssertFalse(files.exists(CacheStore.metaPath(for: "top.json")))

        cache.removeAll(prefix: "providers/a/")
        XCTAssertNil(cache.entry("providers/a/live.json"))
        XCTAssertNil(cache.entry("providers/a/vod/info_1.json"))
        XCTAssertNotNil(cache.entry("providers/ab/live.json"), "prefix ends at the slash")
        XCTAssertNotNil(cache.entry("providers/b/live.json"))
        XCTAssertFalse(files.exists("providers/a"), "emptied directories are pruned")

        cache.removeAll(prefix: "providers/a")
        XCTAssertNil(cache.entry("providers/ab/live.json"), "a prefix without slash is a plain string prefix")
        XCTAssertNotNil(cache.entry("providers/b/live.json"))
    }

    func testClearingTheWholeCacheKeepsNonCacheFiles() throws {
        let state = AppStateStore(files: files)
        var settings = AppSettings()
        settings.reduceMotion = true
        state.saveSettings(settings)
        try files.writeData(Data("direct".utf8), to: "notes/readme.txt")
        try cache.store(Data("1".utf8), for: "providers/a/live.json", fetchedAt: fetched)
        try cache.store(Data("2".utf8), for: "metadata/tmdb.json", fetchedAt: fetched)

        cache.removeAll(prefix: "")
        XCTAssertNil(cache.entry("providers/a/live.json"))
        XCTAssertNil(cache.entry("metadata/tmdb.json"))
        XCTAssertEqual(state.loadSettings(), settings, "settings are not cache entries")
        XCTAssertEqual(files.readData("notes/readme.txt"), Data("direct".utf8))
        XCTAssertEqual(files.list(""), ["notes", "settings.json"])
    }

    func testMetaPath() {
        XCTAssertEqual(CacheStore.metaPath(for: "providers/p/vod.json"), "providers/p/.vod.json.meta.json")
        XCTAssertEqual(CacheStore.metaPath(for: "top.json"), ".top.json.meta.json")
    }
}
