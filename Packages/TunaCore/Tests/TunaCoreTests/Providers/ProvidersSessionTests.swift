import XCTest
@testable import TunaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProvidersSessionTests: XCTestCase {
    private let prefix = ProviderSession.cacheKeyPrefix(for: "prov-1")

    private func xtream(_ config: ProviderConfig = ProvidersHarness.xtreamConfig()) async throws -> ProvidersHarness {
        let harness = ProvidersHarness(config: config)
        try await harness.installXtreamRoutes()
        return harness
    }

    private func expectError<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                                _ check: (TunaError) -> Bool) async {
        do {
            _ = try await operation()
            XCTFail("expected an error", file: file, line: line)
        } catch let error as TunaError {
            XCTAssertTrue(check(error), "unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    // MARK: - Sync: the request pattern

    func testFreshSyncPerformsSevenSequentialRequestsInOrder() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let progress = ProvidersProgressLog()
        let catalog = try await h.session.sync(force: false) { progress.append($0) }

        let log = await h.client.log
        XCTAssertEqual(log, ProvidersHarness.xtreamSequence)       // ONE call per section, in this order
        let overlap = await h.client.maxInFlight
        XCTAssertEqual(overlap, 1)                                  // never two requests at once
        let requests = await h.client.requests
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.headers["User-Agent"] == UserAgentPreset.vlc.value })
        XCTAssertTrue(requests.allSatisfy {
            $0.url.absoluteString.hasPrefix("http://panel.example.com:8080/player_api.php?username=tuna_user&password=s3cr3t%2Bpass")
        })
        XCTAssertFalse(requests.contains { $0.url.query?.contains("category_id") == true })   // no per-category calls

        XCTAssertEqual(catalog.providerID, "prov-1")
        XCTAssertEqual(catalog.items(of: .live).count, 4)
        XCTAssertEqual(catalog.items(of: .movie).count, 4)
        XCTAssertEqual(catalog.items(of: .series).count, 3)
        XCTAssertEqual(catalog.categories.count, 9)
        XCTAssertEqual(catalog.account?.maxConnections, 2)
        XCTAssertEqual(Set(catalog.fetchedAt.keys), Set(XtreamSyncSection.allCases.map(\.rawValue)))
        XCTAssertEqual(catalog.guideURL, "http://panel.example.com:8080/xmltv.php")   // credential-free
        XCTAssertEqual(catalog.items.first { $0.ref.streamID == "2001" }?.categoryName, "EN | MOVIES 4K")

        let events = progress.all
        XCTAssertEqual(events.map(\.stage), [.checkingAccount, .liveCategories, .movieCategories, .seriesCategories,
                                             .liveChannels, .movies, .series, .done])
        XCTAssertEqual(events.map(\.fraction), events.map(\.fraction).sorted())
        XCTAssertEqual(events.first?.fraction, 0)
        XCTAssertEqual(events.last?.fraction, 1)
        XCTAssertEqual(events[5].counts, ["live": 4])               // the movies stage starts with the live count
        XCTAssertEqual(events.last?.counts, ["live": 4, "movie": 4, "series": 3])
        XCTAssertTrue(events.allSatisfy { $0.providerID == "prov-1" && !$0.message.isEmpty })
    }

    func testSecondSyncWithFreshCacheMakesNoRequests() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()
        h.clock.advance(3600)

        let stale = await h.session.isStale()
        XCTAssertFalse(stale)
        let progress = ProvidersProgressLog()
        let again = try await h.session.sync(force: false) { progress.append($0) }
        let log = await h.client.log
        XCTAssertEqual(log, [])
        XCTAssertEqual(again.items.count, 11)
        XCTAssertEqual(progress.all.map(\.stage), [.done])

        h.clock.advance(24 * 3600)                                   // past the sync interval
        let staleLater = await h.session.isStale()
        XCTAssertTrue(staleLater)
    }

    func testForceRefetchesEverything() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()
        _ = try await h.session.sync(force: true) { _ in }
        let log = await h.client.log
        XCTAssertEqual(log, ProvidersHarness.xtreamSequence)
    }

    func testOnlyStaleSectionsAreFetchedAndAFreshLoginIsReused() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let account = try await h.session.validate()
        XCTAssertTrue(account.isUsable)
        await h.client.resetLog()

        _ = try await h.session.sync(force: false) { _ in }
        var log = await h.client.log
        XCTAssertEqual(log, Array(ProvidersHarness.xtreamSequence.dropFirst()))   // the 10-min-old login is reused

        await h.client.resetLog()
        h.cache.remove(prefix + "vod_streams.json")
        _ = try await h.session.sync(force: false) { _ in }
        log = await h.client.log
        XCTAssertEqual(log, ["get_vod_streams"])
    }

    func testCachedCatalogNeedsNoNetwork() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }

        let relaunch = h.relaunched()                                 // same cache, new session, new client
        let maybeCached = await relaunch.session.cachedCatalog()
        let cached = try XCTUnwrap(maybeCached)
        XCTAssertEqual(cached.items.count, 11)
        XCTAssertEqual(cached.account?.status, "Active")
        XCTAssertEqual(cached.items.first { $0.ref.streamID == "1001" }?.categoryName, "UK | NEWS")
        XCTAssertEqual(cached.fetchedAt.count, 7)
        let log = await relaunch.client.log
        XCTAssertEqual(log, [])

        let fresh = ProvidersHarness()
        defer { fresh.cleanUp() }
        let nothing = await fresh.session.cachedCatalog()
        XCTAssertNil(nothing)
        let staleWhenEmpty = await fresh.session.isStale()
        XCTAssertTrue(staleWhenEmpty)
    }

    func testConcurrentSyncCallsCoalesce() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let first = ProvidersProgressLog()
        let second = ProvidersProgressLog()
        let a = Task { try await h.session.sync(force: false) { first.append($0) } }
        while await h.client.log.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let b = Task { try await h.session.sync(force: true) { second.append($0) } }
        let (one, two) = (try await a.value, try await b.value)

        let log = await h.client.log
        XCTAssertEqual(log, ProvidersHarness.xtreamSequence)         // 7 requests, not 14
        let overlap = await h.client.maxInFlight
        XCTAssertEqual(overlap, 1)
        XCTAssertEqual(one.items.count, 11)
        XCTAssertEqual(two.items.map(\.id), one.items.map(\.id))
        XCTAssertEqual(first.all.last?.stage, .done)
        XCTAssertEqual(second.all.last?.stage, .done)               // the joiner hears the shared sync's progress
    }

    // MARK: - Sync: stopping and protecting the cache

    func testPausedGovernorStopsTheSyncAndKeepsTheCache() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let before = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()

        await h.client.set("get_vod_categories", status: 429, text: "Too Many Requests")
        await expectError({ try await h.session.sync(force: true) { _ in } }) { error in
            if case .http(status: 429, _) = error { return true }
            if case .paused = error { return true }
            return false
        }
        var log = await h.client.log
        XCTAssertEqual(log, ["account", "get_live_categories", "get_vod_categories"])   // nothing after the refusal

        // The breaker is open now: the next sync fails at once and does not touch the network.
        await h.client.resetLog()
        await expectError({ try await h.session.sync(force: true) { _ in } }) { error in
            if case .paused = error { return true }
            return false
        }
        log = await h.client.log
        XCTAssertEqual(log, [])

        let maybeCached = await h.session.cachedCatalog()
        let cached = try XCTUnwrap(maybeCached)
        XCTAssertEqual(cached.items.map(\.id), before.items.map(\.id))
        XCTAssertEqual(cached.categories.count, before.categories.count)
    }

    func testRefusedLoginStopsTheSync() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        await h.client.set("account", body: try ProvidersFixture.data("xtream_account_badauth"))
        await expectError({ try await h.session.sync(force: false) { _ in } }) { error in
            if case .unauthorized = error { return true }
            return false
        }
        let log = await h.client.log
        XCTAssertEqual(log, ["account"])
        let cached = await h.session.cachedCatalog()
        XCTAssertNil(cached)
        await expectError({ try await h.session.validate() }) { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    func testExpiredAccountStopsTheSync() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        await h.client.set("account", body: try ProvidersFixture.data("xtream_account_expired"))
        await expectError({ try await h.session.sync(force: true) { _ in } }) { error in
            if case .unauthorized(let message) = error { return message.lowercased().contains("expired") }
            return false
        }
        let log = await h.client.log
        XCTAssertEqual(log, ["account"])
        let account = try await h.session.account(refresh: false)
        XCTAssertEqual(account?.status, "Expired")                  // the answer is still there to show
    }

    func testEmptyListsNeverReplaceTheCache() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()

        await h.client.set("get_vod_streams", text: "[]")
        await h.client.set("get_series", text: "null")
        let progress = ProvidersProgressLog()
        let catalog = try await h.session.sync(force: true) { progress.append($0) }
        let log = await h.client.log
        XCTAssertEqual(log, ProvidersHarness.xtreamSequence)
        XCTAssertEqual(catalog.items(of: .movie).count, 4)
        XCTAssertEqual(catalog.items(of: .series).count, 3)
        XCTAssertEqual(progress.all.last?.message.contains("kept"), true)
        let stale = await h.session.isStale()
        XCTAssertFalse(stale)                                        // checked: an empty answer is not asked again at once

        let maybeRelaunched = await h.relaunched().session.cachedCatalog()
        let relaunched = try XCTUnwrap(maybeRelaunched)
        XCTAssertEqual(relaunched.items(of: .movie).count, 4)
        XCTAssertEqual(h.cache.entry(prefix + "vod_streams.json")?.data, try ProvidersFixture.data("xtream_vod_streams"))
    }

    func testAProviderWithoutMoviesIsNotAskedAgainAndAgain() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        await h.client.set("get_vod_streams", text: "[]")
        await h.client.set("get_vod_categories", text: "[]")
        let catalog = try await h.session.sync(force: false) { _ in }
        XCTAssertEqual(catalog.items(of: .movie).count, 0)
        let stale = await h.session.isStale()
        XCTAssertFalse(stale)
    }

    func testUnreadableSectionIsSkippedAndKeptFromCache() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()

        // A Cloudflare page with status 200: that section is unreadable, the others still update.
        await h.client.set("get_live_streams", body: try ProvidersFixture.data("cloudflare_520", "html"))
        let progress = ProvidersProgressLog()
        let catalog = try await h.session.sync(force: true) { progress.append($0) }
        let log = await h.client.log
        XCTAssertEqual(log, ProvidersHarness.xtreamSequence)
        XCTAssertEqual(catalog.items(of: .live).count, 4)
        XCTAssertEqual(progress.all.last?.message.contains("Cloudflare"), true)
        XCTAssertEqual(h.cache.entry(prefix + "live_streams.json")?.data, try ProvidersFixture.data("xtream_live_streams"))
    }

    func testServerErrorStopsTheSync() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()

        await h.client.set("get_live_streams", status: 520, body: try ProvidersFixture.data("cloudflare_520", "html"))
        await expectError({ try await h.session.sync(force: true) { _ in } }) { error in
            if case .http(status: 520, _) = error { return true }
            if case .paused = error { return true }
            return false
        }
        let log = await h.client.log
        XCTAssertEqual(log, Array(ProvidersHarness.xtreamSequence.prefix(5)))
        let cached = await h.session.cachedCatalog()
        XCTAssertEqual(cached?.items.count, 11)
    }

    func testRawBytesAreCachedButThePasswordIsNot() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        for (section, fixture) in [("live_categories", "xtream_live_categories"), ("vod_categories", "xtream_vod_categories"),
                                   ("series_categories", "xtream_series_categories"), ("live_streams", "xtream_live_streams"),
                                   ("vod_streams", "xtream_vod_streams"), ("series", "xtream_series")] {
            XCTAssertEqual(h.cache.entry(prefix + section + ".json")?.data, try ProvidersFixture.data(fixture), section)
        }
        let account = String(decoding: try XCTUnwrap(h.cache.entry(prefix + "account.json")).data, as: UTF8.self)
        XCTAssertFalse(account.contains("s3cr3t"))
        XCTAssertTrue(account.contains("tuna_user"))
        XCTAssertTrue(account.contains("Istanbul"))
    }

    func testRenamedCategoriesReachCachedItems() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()
        h.cache.remove(prefix + "live_categories.json")
        await h.client.set("get_live_categories", text: #"[{"category_id":"1","category_name":"UK | NEWS & WEATHER"}]"#)
        let catalog = try await h.session.sync(force: false) { _ in }
        let log = await h.client.log
        XCTAssertEqual(log, ["get_live_categories"])
        XCTAssertEqual(catalog.items.first { $0.ref.streamID == "1001" }?.categoryName, "UK | NEWS & WEATHER")
        XCTAssertNil(catalog.items.first { $0.ref.streamID == "1002" }?.categoryName)
    }

    // MARK: - Account

    func testAccountRefreshHonoursTenMinutes() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let none = try await h.session.account(refresh: false)
        XCTAssertNil(none)
        _ = try await h.session.validate()
        let cached = try await h.session.account(refresh: false)
        XCTAssertEqual(cached?.maxConnections, 2)
        _ = try await h.session.account(refresh: true)               // younger than 10 min: no request
        var log = await h.client.log
        XCTAssertEqual(log, ["account"])
        h.clock.advance(11 * 60)
        _ = try await h.session.account(refresh: true)
        log = await h.client.log
        XCTAssertEqual(log, ["account", "account"])
        let requests = await h.client.requests
        XCTAssertTrue(requests.allSatisfy { $0.url.query == "username=tuna_user&password=s3cr3t%2Bpass" })
    }

    // MARK: - Details

    func testVodInfoIsCachedForFourteenDays() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let ref = StreamRef(providerID: "prov-1", kind: .movie, streamID: "2001")
        let info = try await h.session.vodInfo(ref)
        XCTAssertEqual(info.tmdbID, 603)
        XCTAssertEqual(info.containerExtension, "mkv")
        _ = try await h.session.vodInfo(ref)
        h.clock.advance(13 * 86_400)
        _ = try await h.session.vodInfo(ref)
        var log = await h.client.log
        XCTAssertEqual(log, ["get_vod_info"])
        let query = await h.client.requests.last?.url.query
        XCTAssertEqual(query?.hasSuffix("&action=get_vod_info&vod_id=2001"), true)

        h.clock.advance(2 * 86_400)
        _ = try await h.session.vodInfo(ref)
        log = await h.client.log
        XCTAssertEqual(log, ["get_vod_info", "get_vod_info"])
    }

    func testConcurrentDetailRequestsShareOneRequest() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let ref = StreamRef(providerID: "prov-1", kind: .movie, streamID: "2001")
        async let a = h.session.vodInfo(ref)
        async let b = h.session.vodInfo(ref)
        let (one, two) = try await (a, b)
        XCTAssertEqual(one, two)
        let log = await h.client.log
        XCTAssertEqual(log, ["get_vod_info"])
    }

    func testSeriesInfoIsCachedForThreeDays() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let ref = StreamRef(providerID: "prov-1", kind: .series, streamID: "3001")
        let info = try await h.session.seriesInfo(ref)
        XCTAssertEqual(info.episodes.count, 3)
        XCTAssertEqual(info.seriesRef, ref)
        h.clock.advance(2 * 86_400)
        let cached = try await h.session.seriesInfo(ref)
        XCTAssertEqual(cached.episodes.map(\.id), info.episodes.map(\.id))
        var log = await h.client.log
        XCTAssertEqual(log, ["get_series_info"])
        h.clock.advance(2 * 86_400)
        _ = try await h.session.seriesInfo(ref)
        log = await h.client.log
        XCTAssertEqual(log, ["get_series_info", "get_series_info"])
        let query = await h.client.requests.last?.url.query
        XCTAssertEqual(query?.hasSuffix("&action=get_series_info&series_id=3001"), true)
    }

    func testFailedDetailsAreNotAskedAgainAtOnce() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        await h.client.set("get_vod_info", status: 500, text: "oops")
        let ref = StreamRef(providerID: "prov-1", kind: .movie, streamID: "2001")
        await expectError({ try await h.session.vodInfo(ref) }) { error in
            if case .http(status: 500, _) = error { return true }
            if case .paused = error { return true }
            return false
        }
        await expectError({ try await h.session.vodInfo(ref) }) { _ in true }
        let log = await h.client.log
        XCTAssertEqual(log, ["get_vod_info"])
    }

    func testShortEPGIsCachedTenMinutes() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let ref = StreamRef(providerID: "prov-1", kind: .live, streamID: "1001")
        let programs = try await h.session.shortEPG(ref, channelKey: "BBCOne.uk")
        XCTAssertEqual(programs.count, 3)
        XCTAssertEqual(programs.first?.channelKey, "BBCOne.uk")
        let query = await h.client.requests.last?.url.query
        XCTAssertEqual(query?.hasSuffix("&action=get_short_epg&limit=4&stream_id=1001"), true)
        h.clock.advance(9 * 60)
        _ = try await h.session.shortEPG(ref, channelKey: "BBCOne.uk")
        var log = await h.client.log
        XCTAssertEqual(log, ["get_short_epg"])
        h.clock.advance(2 * 60)
        _ = try await h.session.shortEPG(ref, channelKey: "BBCOne.uk")
        log = await h.client.log
        XCTAssertEqual(log, ["get_short_epg", "get_short_epg"])
        let movie = try await h.session.shortEPG(StreamRef(providerID: "prov-1", kind: .movie, streamID: "2001"), channelKey: "x")
        XCTAssertEqual(movie, [])
    }

    // MARK: - Guide

    func testGuideIsDownloadedOncePerDay() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7, 6))
        let programs = try await h.session.guide(channels: ["BBCOne.uk", "trt1.tr"], window: window)
        XCTAssertEqual(programs.count, 6)
        var log = await h.client.log
        XCTAssertEqual(log, ["xmltv"])
        let url = await h.client.requests.first?.url.absoluteString
        XCTAssertEqual(url, "http://panel.example.com:8080/xmltv.php?username=tuna_user&password=s3cr3t%2Bpass")

        let trt = try await h.session.guide(channels: ["trt1.tr"], window: window)
        XCTAssertEqual(trt.count, 2)
        h.clock.advance(23 * 3600)
        _ = try await h.session.guide(channels: ["BBCOne.uk"], window: window)
        let none = try await h.session.guide(channels: [], window: window)
        XCTAssertEqual(none, [])
        log = await h.client.log
        XCTAssertEqual(log, ["xmltv"])

        h.clock.advance(2 * 3600)
        _ = try await h.session.guide(channels: ["BBCOne.uk"], window: window)
        log = await h.client.log
        XCTAssertEqual(log, ["xmltv", "xmltv"])
        let raw = h.cache.entry(prefix + "guide.xml")?.data
        XCTAssertEqual(raw, try ProvidersFixture.data("guide", "xml"))
    }

    func testFailedGuideIsNotRetriedForAWhile() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7))
        await h.client.set("xmltv", status: 404, text: "not found")
        await expectError({ try await h.session.guide(channels: ["BBCOne.uk"], window: window) }) { error in
            if case .http(status: 404, _) = error { return true }
            return false
        }
        await expectError({ try await h.session.guide(channels: ["BBCOne.uk"], window: window) }) { error in
            if case .paused = error { return true }
            return false
        }
        var log = await h.client.log
        XCTAssertEqual(log, ["xmltv"])

        await h.client.set("xmltv", body: try ProvidersFixture.data("guide", "xml"))
        let forced = try await h.session.guide(channels: ["BBCOne.uk"], window: window, force: true)
        XCTAssertEqual(forced.count, 4)
        log = await h.client.log
        XCTAssertEqual(log, ["xmltv", "xmltv"])
    }

    func testCustomGuideAddressIsUsed() async throws {
        var config = ProvidersHarness.xtreamConfig()
        config.epgURL = "https://epg.example.org/guides/uk.xml"
        let h = try await xtream(config)
        defer { h.cleanUp() }
        await h.client.set("/guides/uk.xml", body: try ProvidersFixture.data("guide", "xml"))
        let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7))
        let programs = try await h.session.guide(channels: ["trt1.tr"], window: window)
        XCTAssertEqual(programs.count, 2)
        let log = await h.client.log
        XCTAssertEqual(log, ["/guides/uk.xml"])
        let catalog = try await h.session.sync(force: false) { _ in }
        XCTAssertEqual(catalog.guideURL, "https://epg.example.org/guides/uk.xml")
    }

    // MARK: - Playback URLs (no network)

    func testStreamURLsAndHeaders() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        await h.client.resetLog()
        let base = "http://panel.example.com:8080"
        let live = await h.session.streamURL(for: StreamRef(providerID: "prov-1", kind: .live, streamID: "1001"), containerExtension: nil, directURL: nil)
        XCTAssertEqual(live?.absoluteString, "\(base)/live/tuna_user/s3cr3t%2Bpass/1001.ts")
        let movie = await h.session.streamURL(for: StreamRef(providerID: "prov-1", kind: .movie, streamID: "2001"), containerExtension: "mkv", directURL: nil)
        XCTAssertEqual(movie?.absoluteString, "\(base)/movie/tuna_user/s3cr3t%2Bpass/2001.mkv")
        let plain = await h.session.streamURL(for: StreamRef(providerID: "prov-1", kind: .movie, streamID: "2004"), containerExtension: nil, directURL: nil)
        XCTAssertEqual(plain?.absoluteString, "\(base)/movie/tuna_user/s3cr3t%2Bpass/2004.mp4")
        let episode = await h.session.streamURL(for: StreamRef(providerID: "prov-1", kind: .episode, streamID: "40011"), containerExtension: "mkv", directURL: nil)
        XCTAssertEqual(episode?.absoluteString, "\(base)/series/tuna_user/s3cr3t%2Bpass/40011.mkv")
        let series = await h.session.streamURL(for: StreamRef(providerID: "prov-1", kind: .series, streamID: "3001"), containerExtension: nil, directURL: nil)
        XCTAssertNil(series)

        let headers = await h.session.streamHeaders(for: nil)
        XCTAssertEqual(headers, ["User-Agent": UserAgentPreset.vlc.value])
        var item = RawItem(ref: StreamRef(providerID: "prov-1", kind: .live, streamID: "1001"), name: "x")
        item.userAgentOverride = "Custom/1.0"
        item.referrerOverride = "https://ref.example.net/"
        let custom = await h.session.streamHeaders(for: item)
        XCTAssertEqual(custom, ["User-Agent": "Custom/1.0", "Referer": "https://ref.example.net/"])
        let log = await h.client.log
        XCTAssertEqual(log, [])
    }

    func testLiveFormatFollowsTheAccount() async throws {
        let auto = try await xtream()
        defer { auto.cleanUp() }
        await auto.client.set("account", body: try ProvidersFixture.data("xtream_account_m3u8_only"))
        _ = try await auto.session.validate()
        let ref = StreamRef(providerID: "prov-1", kind: .live, streamID: "1001")
        let hls = await auto.session.streamURL(for: ref, containerExtension: nil, directURL: nil)
        XCTAssertEqual(hls?.pathExtension, "m3u8")                   // the account does not allow "ts"

        let forced = try await xtream(ProvidersHarness.xtreamConfig(liveFormat: .ts))
        defer { forced.cleanUp() }
        await forced.client.set("account", body: try ProvidersFixture.data("xtream_account_m3u8_only"))
        _ = try await forced.session.validate()
        let ts = await forced.session.streamURL(for: ref, containerExtension: nil, directURL: nil)
        XCTAssertEqual(ts?.pathExtension, "ts")

        let hlsChoice = try await xtream(ProvidersHarness.xtreamConfig(liveFormat: .m3u8))
        defer { hlsChoice.cleanUp() }
        let chosen = await hlsChoice.session.streamURL(for: ref, containerExtension: nil, directURL: nil)
        XCTAssertEqual(chosen?.pathExtension, "m3u8")
    }

    func testCatchupURL() async throws {
        let h = try await xtream()
        defer { h.cleanUp() }
        _ = try await h.session.sync(force: false) { _ in }
        let bbc = StreamRef(providerID: "prov-1", kind: .live, streamID: "1001")
        // ManualClock starts at 2027-01-15 08:00 UTC; the panel runs on Europe/Istanbul (UTC+3).
        let past = Program(channelKey: "BBCOne.uk", start: providersUTC(2027, 1, 15, 5, 0), end: providersUTC(2027, 1, 15, 5, 45), title: "News")
        let url = await h.session.catchupURL(for: bbc, program: past)
        XCTAssertEqual(url?.absoluteString, "http://panel.example.com:8080/timeshift/tuna_user/s3cr3t%2Bpass/45/2027-01-15:08-00/1001.ts")
        let future = Program(channelKey: "BBCOne.uk", start: providersUTC(2027, 1, 15, 12), end: providersUTC(2027, 1, 15, 13), title: "Later")
        let none = await h.session.catchupURL(for: bbc, program: future)
        XCTAssertNil(none)
        let tooOld = Program(channelKey: "BBCOne.uk", start: providersUTC(2027, 1, 5), end: providersUTC(2027, 1, 5, 1), title: "Old")
        let expired = await h.session.catchupURL(for: bbc, program: tooOld)
        XCTAssertNil(expired)                                        // 7-day archive
        let noArchive = await h.session.catchupURL(for: StreamRef(providerID: "prov-1", kind: .live, streamID: "1002"), program: past)
        XCTAssertNil(noArchive)
    }

    // MARK: - M3U providers

    func testPlaylistProviderSyncsWithOneRequest() async throws {
        let h = ProvidersHarness(config: ProvidersHarness.m3uConfig())
        defer { h.cleanUp() }
        await h.client.set("/get.php", body: try ProvidersFixture.data("playlist_edge", "m3u"))
        await h.client.set("/guide.xml", body: try ProvidersFixture.data("guide", "xml"))
        let progress = ProvidersProgressLog()
        let catalog = try await h.session.sync(force: false) { progress.append($0) }
        var log = await h.client.log
        XCTAssertEqual(log, ["/get.php"])
        XCTAssertEqual(progress.all.map(\.stage), [.playlist, .done])
        XCTAssertEqual(catalog.items(of: .live).count, 7)
        XCTAssertEqual(catalog.items(of: .movie).count, 3)
        XCTAssertEqual(catalog.items(of: .series).count, 2)
        XCTAssertEqual(Array(catalog.fetchedAt.keys), ["playlist"])
        XCTAssertNil(catalog.account)
        XCTAssertEqual(catalog.guideURL, "http://epg.example.net/guide.xml")

        _ = try await h.session.sync(force: false) { _ in }       // fresh: no second download
        log = await h.client.log
        XCTAssertEqual(log, ["/get.php"])

        let bbc = try XCTUnwrap(catalog.items.first { $0.name == "BBC One HD" })
        let url = await h.session.streamURL(for: bbc.ref, containerExtension: nil, directURL: nil)
        XCTAssertEqual(url?.absoluteString, "http://stream.example.net/live/u/p/101.ts")
        let itv = try XCTUnwrap(catalog.items.first { $0.name == "ITV1, The Best" })
        let headers = await h.session.streamHeaders(for: itv)
        XCTAssertEqual(headers, ["User-Agent": "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)", "Referer": "https://player.example.net/"])

        let show = try XCTUnwrap(catalog.items.first { $0.name == "Breaking Bad" })
        let info = try await h.session.seriesInfo(show.ref)          // built from the saved playlist
        XCTAssertEqual(info.episodes.count, 3)
        XCTAssertEqual(info.seasons.map(\.number), [1, 2])
        let episodeURL = await h.session.streamURL(for: info.episodes[0].ref, containerExtension: "mkv", directURL: nil)
        XCTAssertEqual(episodeURL?.absoluteString, "http://files.example.net/bb/s01e01.mkv")

        let catchup = await h.session.catchupURL(for: bbc.ref, program: Program(
            channelKey: "BBCOne.uk", start: providersUTC(2027, 1, 15, 6), end: providersUTC(2027, 1, 15, 7), title: "News"))
        XCTAssertEqual(catchup?.query?.hasPrefix("utc=1800000000"), false)
        XCTAssertEqual(catchup?.query?.contains("utc=\(Int(providersUTC(2027, 1, 15, 6).timeIntervalSince1970))"), true)

        let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7))
        let programs = try await h.session.guide(channels: ["BBCOne.uk"], window: window)
        XCTAssertEqual(programs.count, 4)
        log = await h.client.log
        XCTAssertEqual(log, ["/get.php", "/guide.xml"])              // the url-tvg of the playlist header
    }

    func testPlaylistValidationAsksForTheHeadOnly() async throws {
        let partial = ProvidersHarness(config: ProvidersHarness.m3uConfig())
        defer { partial.cleanUp() }
        let full = try ProvidersFixture.data("playlist_edge", "m3u")
        await partial.client.set("/get.php", status: 206, body: full.prefix(1024))
        let account = try await partial.session.validate()
        XCTAssertTrue(account.isAuthorized)
        let range = await partial.client.requests.first?.headers["Range"]
        XCTAssertEqual(range, "bytes=0-1023")
        let nothing = await partial.session.cachedCatalog()
        XCTAssertNil(nothing)                                       // a partial body is never kept

        // A server that ignores Range sends everything: it is kept, so the first sync needs no second download.
        let whole = ProvidersHarness(config: ProvidersHarness.m3uConfig())
        defer { whole.cleanUp() }
        await whole.client.set("/get.php", body: full)
        _ = try await whole.session.validate()
        let catalog = try await whole.session.sync(force: false) { _ in }
        XCTAssertEqual(catalog.items.count, 12)
        let log = await whole.client.log
        XCTAssertEqual(log, ["/get.php"])
    }

    func testPlaylistProblemsKeepTheSavedPlaylist() async throws {
        let h = ProvidersHarness(config: ProvidersHarness.m3uConfig())
        defer { h.cleanUp() }
        await h.client.set("/get.php", body: try ProvidersFixture.data("playlist_edge", "m3u"))
        _ = try await h.session.sync(force: false) { _ in }

        await h.client.set("/get.php", text: "#EXTM3U\n")
        let progress = ProvidersProgressLog()
        let emptied = try await h.session.sync(force: true) { progress.append($0) }
        XCTAssertEqual(emptied.items.count, 12)
        XCTAssertEqual(progress.all.last?.message.contains("kept"), true)

        await h.client.set("/get.php", body: try ProvidersFixture.data("cloudflare_520", "html"))
        await expectError({ try await h.session.sync(force: true) { _ in } }) { error in
            if case .decoding = error { return true }
            return false
        }
        let cached = await h.session.cachedCatalog()
        XCTAssertEqual(cached?.items.count, 12)
    }
}
