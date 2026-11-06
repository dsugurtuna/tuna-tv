import XCTest
@testable import TunaCore

final class ProvidersM3UTests: XCTestCase {
    private func playlist() throws -> M3UPlaylist {
        M3UParser.parse(try ProvidersFixture.data("playlist_edge", "m3u"))
    }

    func testHeaderGuideLinks() throws {
        XCTAssertEqual(try playlist().guideURLs, ["http://epg.example.net/guide.xml", "http://epg2.example.net/guide.xml.gz"])
    }

    func testEntriesAndAttributes() throws {
        let entries = try playlist().entries
        XCTAssertEqual(entries.map(\.name), [
            "BBC One HD", "ITV1, The Best", "News 24", "Jazz FM", "Dash Channel", "EN| The Matrix (1999)", "Heat 1995", "Toy Story",
            "Breaking Bad S01E01 - Pilot", "Breaking Bad S01E02", "breaking bad s02e01 Seven Thirty-Seven",
            "Friends 1x01 The One Where Monica Gets a Roommate", "Sky Sports F1", "Local File", "BBC One HD (same URL again)", "Télé Matin",
        ])   // the URL without #EXTINF is ignored; BOM, CRLF and a CP1252 line are handled

        let bbc = entries[0]
        XCTAssertEqual(bbc.url, "http://stream.example.net/live/u/p/101.ts")
        XCTAssertEqual(bbc.groupTitle, "UK, News & Entertainment")       // comma inside quotes
        XCTAssertEqual(bbc.duration, -1)
        XCTAssertEqual(bbc.attributes["tvg-id"], "BBCOne.uk")
        XCTAssertEqual(bbc.attributes["tvg-chno"], "101")
        XCTAssertEqual(bbc.attributes["catchup-days"], "7")
        XCTAssertNil(bbc.userAgent)

        let itv = entries[1]
        XCTAssertEqual(itv.attributes["tvg-id"], "itv1.uk")              // single quotes
        XCTAssertEqual(itv.groupTitle, "UK")
        XCTAssertEqual(itv.userAgent, "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)")
        XCTAssertEqual(itv.referrer, "https://player.example.net/")

        let news = entries[2]
        XCTAssertEqual(news.attributes["tvg-id"], "news24")              // unquoted value
        XCTAssertEqual(news.groupTitle, "News")                         // group-title wins over #EXTGRP
        XCTAssertEqual(news.duration, 0)
        XCTAssertEqual(news.url, "http://stream.example.net/news24.m3u8")   // "|Header=…" stripped
        XCTAssertEqual(news.userAgent, "Kodi/21.1")
        XCTAssertEqual(news.referrer, "http://ref.example.net/")

        let jazz = entries[3]
        XCTAssertEqual(jazz.groupTitle, "Radio")                        // #EXTGRP before #EXTINF
        XCTAssertEqual(jazz.url, "http://radio.example.net/jazz.mp3")   // surrounding spaces trimmed

        let dash = entries[4]
        XCTAssertEqual(dash.userAgent, "ExoPlayer")                     // #KODIPROP stream headers
        XCTAssertEqual(dash.referrer, "https://dash.example.net/")
        XCTAssertEqual(dash.attributes["kodiprop:inputstream.adaptive.license_type"], "clearkey")

        XCTAssertEqual(entries[12].name, "Sky Sports F1")               // empty display name -> tvg-name
        XCTAssertEqual(entries[15].groupTitle, "FR")
    }

    func testCatalogClassification() throws {
        let catalog = M3UParser.catalog(from: try playlist(), providerID: "m")
        XCTAssertEqual(catalog.providerID, "m")
        XCTAssertEqual(catalog.guideURL, "http://epg.example.net/guide.xml")
        XCTAssertEqual(catalog.items(of: .live).map(\.name),
                       ["BBC One HD", "ITV1, The Best", "News 24", "Jazz FM", "Dash Channel", "Sky Sports F1", "Télé Matin"])
        XCTAssertEqual(catalog.items(of: .movie).map(\.name), ["EN| The Matrix (1999)", "Heat 1995", "Toy Story"])
        XCTAssertEqual(catalog.items(of: .series).map(\.name), ["Breaking Bad", "Friends"])   // episodes grouped per show
        XCTAssertTrue(catalog.items(of: .episode).isEmpty)
        XCTAssertFalse(catalog.items.contains { $0.name == "Local File" })                  // file:// never accepted
        XCTAssertEqual(catalog.items.filter { $0.directURL == "http://stream.example.net/live/u/p/101.ts" }.count, 1)   // same URL once

        let bbc = try XCTUnwrap(catalog.items.first { $0.name == "BBC One HD" })
        XCTAssertEqual(bbc.ref.streamID, providersFNV1a64Hex("http://stream.example.net/live/u/p/101.ts"))
        XCTAssertEqual(bbc.directURL, "http://stream.example.net/live/u/p/101.ts")
        XCTAssertEqual(bbc.epgChannelID, "BBCOne.uk")
        XCTAssertEqual(bbc.channelNumber, 101)
        XCTAssertEqual(bbc.catchupDays, 7)
        XCTAssertEqual(bbc.tvgCountry, "GB")
        XCTAssertEqual(bbc.tvgLanguage, "English")
        XCTAssertEqual(bbc.iconURL, "http://logos.example.net/bbc1.png")
        XCTAssertEqual(bbc.categoryID, "UK, News & Entertainment")

        let itv = try XCTUnwrap(catalog.items.first { $0.name == "ITV1, The Best" })
        XCTAssertEqual(itv.userAgentOverride, "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)")
        XCTAssertEqual(itv.referrerOverride, "https://player.example.net/")

        let heat = try XCTUnwrap(catalog.items.first { $0.name == "Heat 1995" })
        XCTAssertEqual(heat.containerExtension, "mp4")                  // extension read without the query
        XCTAssertEqual(heat.directURL, "http://files.example.net/films/Heat.1995.1080p.mp4?token=abc")

        let matrix = try XCTUnwrap(catalog.items.first { $0.name == "EN| The Matrix (1999)" })
        XCTAssertEqual(matrix.ref.kind, .movie)                         // Xtream-style /movie/ path
        XCTAssertEqual(matrix.containerExtension, "mkv")

        let breaking = try XCTUnwrap(catalog.items.first { $0.name == "Breaking Bad" })
        XCTAssertNil(breaking.directURL)
        XCTAssertEqual(breaking.iconURL, "http://img.example.net/bb.jpg")
        XCTAssertEqual(breaking.ref.streamID.count, 16)

        XCTAssertEqual(Set(catalog.categories.filter { $0.kind == .movie }.map(\.name)), ["Movies", "Cinema", "VOD | Kids"])
        XCTAssertEqual(catalog.categories.filter { $0.kind == .series }.map(\.name), ["Series"])
        XCTAssertTrue(catalog.categories.contains(RawCategory(id: "Radio", name: "Radio", kind: .live)))
        XCTAssertEqual(Set(catalog.items.map(\.id)).count, catalog.items.count)   // ids are unique
    }

    func testSeriesEpisodesAreGroupedWithNumbers() throws {
        let classified = M3UParsingKit.classify(try playlist(), providerID: "m")
        let breaking = try XCTUnwrap(classified.catalog.items.first { $0.name == "Breaking Bad" })
        let episodes = try XCTUnwrap(classified.episodes[breaking.ref.streamID])
        XCTAssertEqual(episodes.map(\.season), [1, 1, 2])
        XCTAssertEqual(episodes.map(\.episode), [1, 2, 1])
        XCTAssertEqual(episodes.map(\.title), ["Pilot", "Episode 2", "Seven Thirty-Seven"])
        XCTAssertEqual(episodes[0].ref, StreamRef(providerID: "m", kind: .episode, streamID: providersFNV1a64Hex("http://files.example.net/bb/s01e01.mkv")))
        XCTAssertEqual(episodes[0].containerExtension, "mkv")
        let friends = try XCTUnwrap(classified.catalog.items.first { $0.name == "Friends" })
        XCTAssertEqual(classified.episodes[friends.ref.streamID]?.first?.title, "The One Where Monica Gets a Roommate")
    }

    func testStreamIDsAreStableAcrossParses() throws {
        XCTAssertEqual(providersFNV1a64Hex(""), "cbf29ce484222325")      // FNV-1a 64 reference vectors
        XCTAssertEqual(providersFNV1a64Hex("a"), "af63dc4c8601ec8c")
        let first = M3UParser.catalog(from: try playlist(), providerID: "m").items.map(\.id)
        let second = M3UParser.catalog(from: try playlist(), providerID: "m").items.map(\.id)
        XCTAssertEqual(first, second)
    }

    func testMinimalAndBrokenInput() {
        let text = "#EXTM3U\n#EXTINF:-1,Plain\rhttp://h/a\n#EXTINF:-1 group-title=\"Unbalanced,Name\nhttp://h/b\n#EXTINF:-1,\nhttp://h/path/movie.mkv\n"
        let entries = M3UParser.parse(Data(text.utf8)).entries
        XCTAssertEqual(entries.map(\.name), ["Plain", "Name", "movie.mkv"])   // last comma wins on unbalanced quotes
        XCTAssertNil(entries[0].groupTitle)
        XCTAssertEqual(M3UParser.parse(Data()).entries.count, 0)
        XCTAssertEqual(M3UParser.parse(Data("<html>nope</html>".utf8)).entries.count, 0)
        // The name never falls back to the URL (it carries credentials).
        let bare = M3UParser.parse(Data("#EXTINF:-1,\nhttp://h:8080/get.php?username=u&password=p\n".utf8)).entries
        XCTAssertEqual(bare.first?.name, "get.php")
    }

    func testVeryLongLineIsLinear() {
        let longValue = String(repeating: "x", count: 2_000_000)
        let text = "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" junk=\"\(longValue)\" group-title=\"G\",Long One\nhttp://h/long.ts\n"
        let started = Date()
        let entries = M3UParser.parse(Data(text.utf8)).entries
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(entries.first?.name, "Long One")
        XCTAssertEqual(entries.first?.groupTitle, "G")
        XCTAssertEqual(entries.first?.attributes["junk"]?.count, 2_000_000)
    }

    func testCatchupTemplates() throws {
        let start = providersUTC(2026, 11, 6, 18, 0)
        let end = providersUTC(2026, 11, 6, 19, 0)
        let now = providersUTC(2026, 11, 6, 20, 0)
        let shift = M3UEntry(name: "A", url: "http://h/live/1.m3u8?token=t", attributes: ["catchup-days": "3"])
        XCTAssertEqual(M3UParsingKit.catchupURL(for: shift, start: start, end: end, now: now)?.absoluteString,
                       "http://h/live/1.m3u8?token=t&utc=1793988000&lutc=1793995200")
        let template = M3UEntry(name: "B", url: "http://h/live/2.ts",
                                attributes: ["catchup": "default", "catchup-days": "2",
                                             "catchup-source": "http://h/archive/2/{Y}-{m}-{d}/{H}{M}.ts?start={utc}&len={duration:60}"])
        XCTAssertEqual(M3UParsingKit.catchupURL(for: template, start: start, end: end, now: now)?.absoluteString,
                       "http://h/archive/2/2026-11-06/1800.ts?start=1793988000&len=60")
        let append = M3UEntry(name: "C", url: "http://h/live/3.ts", attributes: ["catchup": "append", "catchup-source": "?utc={utc}&lutc={lutc}"])
        XCTAssertEqual(M3UParsingKit.catchupURL(for: append, start: start, end: end, now: now)?.absoluteString,
                       "http://h/live/3.ts?utc=1793988000&lutc=1793995200")
        let flussonic = M3UEntry(name: "D", url: "http://h/ch/index.m3u8?token=x", attributes: ["catchup": "flussonic", "catchup-days": "1"])
        XCTAssertEqual(M3UParsingKit.catchupURL(for: flussonic, start: start, end: end, now: now)?.absoluteString,
                       "http://h/ch/index-1793988000-3600.m3u8?token=x")
        let xc = M3UEntry(name: "E", url: "http://h:8080/live/user/pass/77.ts", attributes: ["catchup": "xc", "catchup-days": "5"])
        XCTAssertEqual(M3UParsingKit.catchupURL(for: xc, start: start, end: end, now: now)?.absoluteString,
                       "http://h:8080/timeshift/user/pass/60/2026-11-06:18-00/77.ts")
        XCTAssertNil(M3UParsingKit.catchupURL(for: M3UEntry(name: "F", url: "http://h/5.ts"), start: start, end: end, now: now))
    }
}
