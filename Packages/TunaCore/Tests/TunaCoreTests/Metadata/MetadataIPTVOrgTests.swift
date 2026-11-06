import Foundation
import XCTest
@testable import TunaCore

final class MetadataIPTVOrgTests: XCTestCase {
    private let host = "iptv-org.github.io"

    private func routes(_ http: MetadataFakeHTTP) {
        http.on(host, "/api/channels.json", fixture: "iptvorg-channels")
        http.on(host, "/api/logos.json", fixture: "iptvorg-logos")
    }

    private func loadChannels() async throws -> [IPTVOrgChannel] {
        let http = MetadataFakeHTTP()
        routes(http)
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: MetadataTestKit.files(for: self))
        return try await client.channels(maxAge: 3600)
    }

    // MARK: - Client

    func testDownloadSlimsChannelsAndPicksLogos() async throws {
        let http = MetadataFakeHTTP()
        routes(http)
        let files = MetadataTestKit.files(for: self)
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: files)
        let channels = try await client.channels(maxAge: 7 * 86_400)

        XCTAssertEqual(http.paths(host: host), ["/api/channels.json", "/api/logos.json"])
        // 26 real channels + one legacy-format row; the row without an id and the non-object are skipped.
        XCTAssertEqual(channels.count, 27)
        let byID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })

        let bbcOne = try XCTUnwrap(byID["BBCOne.uk"])
        XCTAssertEqual(bbcOne.name, "BBC One")
        XCTAssertEqual(bbcOne.altNames, ["BBC1", "BBC Television", "BBC Television Service"])
        XCTAssertEqual(bbcOne.network, "BBC Television")
        XCTAssertEqual(bbcOne.owners, ["BBC"])
        XCTAssertEqual(bbcOne.country, "UK")
        XCTAssertEqual(bbcOne.categories, ["general"])
        XCTAssertFalse(bbcOne.isNSFW)
        XCTAssertEqual(bbcOne.launched, "1936-11-02")
        XCTAssertNil(bbcOne.closed)
        XCTAssertEqual(bbcOne.website, "http://www.bbc.co.uk/bbcone/")
        XCTAssertEqual(bbcOne.logoURL, "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/BBC_One_logo_2021.svg/960px-BBC_One_logo_2021.svg.png")

        // In use > raster > channel-wide > widest: not the retired 2000 px one, not the SVG, not a station feed's logo.
        XCTAssertEqual(byID["Fox.us"]?.logoURL, "https://upload.wikimedia.org/wikipedia/commons/thumb/9/95/FOX_wordmark-red.svg/960px-FOX_wordmark-red.svg.png")
        XCTAssertEqual(byID["TRT1.tr"]?.logoURL, "https://upload.wikimedia.org/wikipedia/commons/thumb/8/85/TRT_1_logo_%282021-%29.svg/960px-TRT_1_logo_%282021-%29.svg.png")
        XCTAssertEqual(byID["CNN.us"]?.logoURL, "https://upload.wikimedia.org/wikipedia/commons/thumb/b/b1/CNN.svg/960px-CNN.svg.png")

        let fox = try XCTUnwrap(byID["Fox.de"])
        XCTAssertEqual(fox.closed, "2021-10-01")
        XCTAssertEqual(byID["Fox.tr"]?.altNames, ["FOX Türkiye", "FOX TV"])
        XCTAssertEqual(byID["Fox.tr"]?.replacedBy, "NOW.tr")

        // Legacy/loose shapes: ";" lists, string booleans, logo and languages on the channel.
        let legacy = try XCTUnwrap(byID["LegacyTV.us"])
        XCTAssertEqual(legacy.altNames, ["Legacy", "Legacy Television"])
        XCTAssertEqual(legacy.categories, ["general"])
        XCTAssertFalse(legacy.isNSFW)
        XCTAssertEqual(legacy.logoURL, "https://example.org/legacy.png")
        XCTAssertEqual(legacy.languages, ["eng"])

        // Slim copy cached on disk.
        let cached = try XCTUnwrap(files.readData("metadata/iptvorg/channels.json"))
        XCTAssertEqual(try JSONDecoder().decode([IPTVOrgChannel].self, from: cached), channels)
    }

    func testCacheIsServedWithinMaxAge() async throws {
        let http = MetadataFakeHTTP()
        routes(http)
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: MetadataTestKit.files(for: self))
        let first = try await client.channels(maxAge: 3600)
        http.clearLog()
        let second = try await client.channels(maxAge: 3600)
        XCTAssertEqual(first, second)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(client.cachedChannels()?.count, 27)
    }

    func testFailedRefreshFallsBackToCache() async throws {
        let http = MetadataFakeHTTP()
        routes(http)
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: MetadataTestKit.files(for: self))
        let first = try await client.channels(maxAge: 3600)
        http.removeAllRoutes()
        http.on(host, "/api/channels.json", status: 500, body: Data())
        http.clearLog()
        let second = try await client.channels(maxAge: 0)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(second, first)
    }

    func testFailureWithoutCacheThrows() async {
        let http = MetadataFakeHTTP()
        http.on(host, "/api/channels.json", status: 502, body: Data())
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: MetadataTestKit.files(for: self))
        do {
            _ = try await client.channels(maxAge: 3600)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TunaError, .http(status: 502, host: "iptv-org.github.io"))
        }
    }

    func testLogoOutageKeepsPreviouslyKnownLogos() async throws {
        let http = MetadataFakeHTTP()
        routes(http)
        let client = IPTVOrgClient(http: http, limiter: MetadataTestKit.limiter(), files: MetadataTestKit.files(for: self))
        _ = try await client.channels(maxAge: 3600)
        http.on(host, "/api/logos.json", status: 503, body: Data())
        let refreshed = try await client.channels(maxAge: 0)
        XCTAssertEqual(refreshed.count, 27)
        XCTAssertEqual(refreshed.first(where: { $0.id == "BBCOne.uk" })?.logoURL,
                       "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/BBC_One_logo_2021.svg/960px-BBC_One_logo_2021.svg.png")
    }

    // MARK: - ChannelMatcher

    func testNormalization() {
        XCTAssertEqual(ChannelMatcher.normalize("UK: BBC One FHD"), "bbc one")
        XCTAssertEqual(ChannelMatcher.normalize("|UK| BBC One (Backup)"), "bbc one")
        XCTAssertEqual(ChannelMatcher.normalize("UK | BBC One HD"), "bbc one")
        XCTAssertEqual(ChannelMatcher.normalize("[VIP] UK | Sky Sports Main Event 4K"), "sky sports main event")
        XCTAssertEqual(ChannelMatcher.normalize("TR: TRT 1 HD"), "trt 1")
        XCTAssertEqual(ChannelMatcher.normalize("Canal+ HD"), "canal plus")
        XCTAssertEqual(ChannelMatcher.normalize("E4 +1"), "e4")
        XCTAssertEqual(ChannelMatcher.normalize("BBC One UK"), "bbc one")
        XCTAssertEqual(ChannelMatcher.normalize("Télévision française 1"), "television francaise 1")
        XCTAssertEqual(ChannelMatcher.normalize("CNN: International"), "cnn international")
        XCTAssertEqual(ChannelMatcher.parse("UK: BBC One FHD").prefixCountry, "UK")
        XCTAssertEqual(ChannelMatcher.parse("EN | BBC One").prefixCountry, nil)
    }

    func testMatchesProviderNamesToIPTVOrgIDs() async throws {
        let matcher = ChannelMatcher(channels: try await loadChannels())
        XCTAssertEqual(matcher.count, 27)
        XCTAssertEqual(matcher.match(name: "UK: BBC One FHD", countries: [], epgID: nil)?.id, "BBCOne.uk")
        XCTAssertEqual(matcher.match(name: "BBC One", countries: ["GB"], epgID: nil)?.id, "BBCOne.uk")
        XCTAssertEqual(matcher.match(name: "BBC1 HD", countries: ["GB"], epgID: nil)?.id, "BBCOne.uk")
        XCTAssertEqual(matcher.match(name: "UK: BBC TWO HD (Backup)", countries: [], epgID: nil)?.id, "BBCTwo.uk")
        XCTAssertEqual(matcher.match(name: "BBC HD", countries: ["GB"], epgID: nil)?.id, "BBCHD.uk")
        XCTAssertEqual(matcher.match(name: "DE: Das Erste HD", countries: [], epgID: nil)?.id, "DasErste.de")
        XCTAssertEqual(matcher.match(name: "ARD", countries: ["DE"], epgID: nil)?.id, "DasErste.de")
        XCTAssertEqual(matcher.match(name: "FR: Canal+ FHD", countries: [], epgID: nil)?.id, "CanalPlus.fr")
        XCTAssertEqual(matcher.match(name: "TF1 HD", countries: ["FR"], epgID: nil)?.id, "TF1.fr")
        XCTAssertEqual(matcher.match(name: "IT: Rai Uno", countries: [], epgID: nil)?.id, "Rai1.it")
        XCTAssertEqual(matcher.match(name: "TR: TRT 1 HD", countries: [], epgID: nil)?.id, "TRT1.tr")
        XCTAssertEqual(matcher.match(name: "TRT1", countries: ["TR"], epgID: nil)?.id, "TRT1.tr")
        XCTAssertEqual(matcher.match(name: "AR: beIN Sports 2 HD", countries: [], epgID: nil)?.id, "beINSports2.qa")
        XCTAssertEqual(matcher.match(name: "E4 +1", countries: ["GB"], epgID: nil)?.id, "E4.uk")
        XCTAssertEqual(matcher.match(name: "CNNi", countries: [], epgID: nil)?.id, "CNNInternational.us")
    }

    func testEPGIDEqualToIPTVOrgIDWins() async throws {
        let matcher = ChannelMatcher(channels: try await loadChannels())
        XCTAssertEqual(matcher.match(name: "Something else entirely", countries: ["US"], epgID: "bbcone.uk")?.id, "BBCOne.uk")
        XCTAssertEqual(matcher.match(name: "BBC One", countries: [], epgID: "BBCTwo.uk@HD")?.id, "BBCTwo.uk")
        // An unknown EPG id does not block name matching (its suffix still hints the country).
        XCTAssertEqual(matcher.match(name: "Sky Sports Main Event", countries: [], epgID: "skysportsmainevent.ie")?.id, "SkySportsMainEvent.ie")
        XCTAssertEqual(matcher.channel(id: "bbcone.UK")?.name, "BBC One")
    }

    func testCountryDecidesBetweenSameNames() async throws {
        let matcher = ChannelMatcher(channels: try await loadChannels())
        XCTAssertEqual(matcher.match(name: "TR: FOX HD", countries: [], epgID: nil)?.id, "Fox.tr")
        XCTAssertEqual(matcher.match(name: "FOX", countries: ["US"], epgID: nil)?.id, "Fox.us")
        XCTAssertEqual(matcher.match(name: "FOX TV", countries: ["TR"], epgID: nil)?.id, "Fox.tr")
        XCTAssertEqual(matcher.match(name: "Sky Sports Main Event", countries: ["IE"], epgID: nil)?.id, "SkySportsMainEvent.ie")
        XCTAssertEqual(matcher.match(name: "Sky Sports Main Event", countries: ["GB"], epgID: nil)?.id, "SkySportsMainEvent.uk")
    }

    func testFuzzyMatchingToleratesSmallDifferences() async throws {
        let matcher = ChannelMatcher(channels: try await loadChannels())
        XCTAssertEqual(matcher.match(name: "UK: Sky Sport Main Event", countries: [], epgID: nil)?.id, "SkySportsMainEvent.uk")
        XCTAssertEqual(matcher.match(name: "Sky Sports F-1 HD", countries: ["GB"], epgID: nil)?.id, "SkySportsF1.uk")
        XCTAssertEqual(matcher.match(name: "Channel Four", countries: ["GB"], epgID: nil)?.id, "Channel4.uk")
    }

    func testDifferentNumbersOrUnrelatedNamesNeverMatch() async throws {
        let matcher = ChannelMatcher(channels: try await loadChannels())
        // BBC Three is not in the sample: neither BBC One, Two nor Four may stand in for it.
        XCTAssertNil(matcher.match(name: "UK: BBC Three HD", countries: [], epgID: nil))
        XCTAssertNil(matcher.match(name: "beIN Sports 3", countries: [], epgID: nil))
        XCTAssertNil(matcher.match(name: "Totally Unknown Channel", countries: [], epgID: nil))
        XCTAssertNil(matcher.match(name: "FOX News", countries: ["US"], epgID: nil))
        XCTAssertNil(matcher.match(name: "  ", countries: [], epgID: nil))
    }

    func testMatchingManyNamesIsFast() async throws {
        var channels = try await loadChannels()
        for index in 0..<5_000 {
            channels.append(IPTVOrgChannel(id: "Synthetic\(index).us", name: "Synthetic Channel \(index) TV", country: "US"))
        }
        let matcher = ChannelMatcher(channels: channels)
        let started = Date()
        for index in 0..<500 {
            _ = matcher.match(name: "US: Synthetic Chanel \(index * 7) TV HD", countries: ["US"], epgID: nil)
        }
        XCTAssertEqual(matcher.match(name: "US: Synthetic Channel 4242 TV HD", countries: [], epgID: nil)?.id, "Synthetic4242.us")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "500 fuzzy lookups over 5k channels took too long")
    }
}
