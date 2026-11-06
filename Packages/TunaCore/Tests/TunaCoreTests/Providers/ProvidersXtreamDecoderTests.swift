import XCTest
@testable import TunaCore

final class ProvidersXtreamDecoderTests: XCTestCase {
    // MARK: Account

    func testAccount() throws {
        let account = try XtreamDecoder.account(ProvidersFixture.data("xtream_account"))
        XCTAssertTrue(account.isAuthorized)
        XCTAssertTrue(account.isUsable)
        XCTAssertEqual(account.status, "Active")
        XCTAssertEqual(account.expiresAt, Date(timeIntervalSince1970: 1_924_992_000))
        XCTAssertEqual(account.createdAt, Date(timeIntervalSince1970: 1_699_999_999))
        XCTAssertFalse(account.isTrial)
        XCTAssertEqual(account.activeConnections, 0)
        XCTAssertEqual(account.maxConnections, 2)
        XCTAssertEqual(account.allowedOutputFormats, ["m3u8", "ts", "rtmp"])
        XCTAssertEqual(account.serverTimezone, "Europe/Istanbul")
        XCTAssertEqual(account.serverTimeNow, Date(timeIntervalSince1970: 1_762_440_000))
        XCTAssertEqual(account.serverMessage, "Welcome to StarStream!\nSupport: t.me/starstream")
    }

    func testAccountWithLooseTypes() throws {
        let data = try ProvidersFixture.data("xtream_account_m3u8_only")
        let account = try XtreamDecoder.account(data)
        XCTAssertTrue(account.isAuthorized)                       // "auth": "1"
        XCTAssertNil(account.expiresAt)                           // "exp_date": null = never
        XCTAssertNil(account.createdAt)                           // ""
        XCTAssertTrue(account.isTrial)                            // true
        XCTAssertEqual(account.activeConnections, 1)
        XCTAssertEqual(account.maxConnections, 1)
        XCTAssertEqual(account.allowedOutputFormats, ["m3u8"])
        XCTAssertNil(account.serverTimezone)
        XCTAssertNil(account.serverMessage)
        XCTAssertEqual(account.serverTimeNow, Date(timeIntervalSince1970: 1_762_440_000))   // "timestamp_now" as a string
        // Without a zone name, the zone comes from the panel's wall clock vs its Unix time (16:40 vs 14:40 UTC).
        let zone = try XCTUnwrap(XtreamDecodingKit.serverTimeZone(json: XtreamJSONKit.parse(data)))
        XCTAssertEqual(zone.secondsFromGMT(), 7200)
    }

    func testAccountRefusals() throws {
        XCTAssertFalse(try XtreamDecoder.account(ProvidersFixture.data("xtream_account_badauth")).isAuthorized)
        for body in ["", "  \n", "[]", "null", "false", "{}", #"{"error":"Invalid credentials"}"#] {
            XCTAssertFalse(try XtreamDecoder.account(Data(body.utf8)).isAuthorized, "body \(body)")
        }
        let expired = try XtreamDecoder.account(ProvidersFixture.data("xtream_account_expired"))
        XCTAssertTrue(expired.isAuthorized)
        XCTAssertFalse(expired.isUsable)
        XCTAssertEqual(expired.expiresAt, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertThrowsError(try XtreamDecoder.account(ProvidersFixture.data("cloudflare_520", "html"))) { error in
            guard case TunaError.decoding(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("Cloudflare"), message)
        }
    }

    // MARK: Lists

    func testCategories() throws {
        let live = try XtreamDecoder.categories(ProvidersFixture.data("xtream_live_categories"), kind: .live)
        XCTAssertEqual(live.map(\.id), ["1", "2", "3", "4"])                 // duplicate id and id-less row dropped
        XCTAssertEqual(live.map(\.name), ["UK | NEWS", "UK | SPORTS ⚽", "TR | ULUSAL", "4"])
        XCTAssertTrue(live.allSatisfy { $0.kind == .live && $0.parentID == nil })
        let vod = try XtreamDecoder.categories(ProvidersFixture.data("xtream_vod_categories"), kind: .movie)
        XCTAssertEqual(vod.last?.parentID, "10")
        XCTAssertEqual(try XtreamDecoder.categories(Data("null".utf8), kind: .series), [])
        XCTAssertEqual(try XtreamDecoder.categories(Data("false".utf8), kind: .series), [])
        XCTAssertEqual(try XtreamDecoder.categories(Data(), kind: .series), [])
        // Index-keyed object instead of an array.
        let keyed = try XtreamDecoder.categories(Data(#"{"0":{"category_id":"7","category_name":"A"},"1":{"category_id":8,"category_name":"B"}}"#.utf8), kind: .movie)
        XCTAssertEqual(keyed.map(\.id), ["7", "8"])
        // The auth object some panels send for any action when the login fails.
        XCTAssertThrowsError(try XtreamDecoder.categories(ProvidersFixture.data("xtream_account_badauth"), kind: .live)) { error in
            guard case TunaError.unauthorized = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertThrowsError(try XtreamDecoder.categories(ProvidersFixture.data("cloudflare_520", "html"), kind: .live))
    }

    func testLiveItems() throws {
        let names = ["1": "UK | NEWS", "2": "UK | SPORTS", "3": "TR | ULUSAL"]
        let items = try XtreamDecoder.items(ProvidersFixture.data("xtream_live_streams"), kind: .live, providerID: "p", categories: names)
        XCTAssertEqual(items.map(\.ref.streamID), ["1001", "1002", "1003", "1004"])   // duplicate + id-less dropped
        XCTAssertTrue(items.allSatisfy { $0.ref.kind == .live && $0.ref.providerID == "p" && $0.directURL == nil })

        let bbc = items[0]
        XCTAssertEqual(bbc.ref.id, "p|live|1001")
        XCTAssertEqual(bbc.name, "UK: BBC One FHD")
        XCTAssertEqual(bbc.channelNumber, 1)
        XCTAssertEqual(bbc.epgChannelID, "BBCOne.uk")
        XCTAssertEqual(bbc.catchupDays, 7)
        XCTAssertEqual(bbc.categoryID, "1")
        XCTAssertEqual(bbc.categoryName, "UK | NEWS")
        XCTAssertEqual(bbc.iconURL, "http://logos.example.net/bbc1.png")
        XCTAssertEqual(bbc.addedAt, Date(timeIntervalSince1970: 1_690_000_000))

        let sky = items[1]
        XCTAssertEqual(sky.channelNumber, 2)            // "num": "2"
        XCTAssertNil(sky.epgChannelID)                  // null
        XCTAssertNil(sky.catchupDays)                   // tv_archive 0
        XCTAssertNil(sky.iconURL)                       // ""

        let trt = items[2]
        XCTAssertEqual(trt.categoryID, "3")             // category_id null -> first of category_ids
        XCTAssertEqual(trt.categoryName, "TR | ULUSAL")
        XCTAssertEqual(trt.catchupDays, 3)              // tv_archive "1"
        XCTAssertEqual(trt.addedAt, Date(timeIntervalSince1970: 1_690_001_000))

        let separator = items[3]
        XCTAssertNil(separator.epgChannelID)
        XCTAssertNil(separator.catchupDays)             // false
        XCTAssertNil(separator.addedAt)
    }

    func testMovieItems() throws {
        let items = try XtreamDecoder.items(ProvidersFixture.data("xtream_vod_streams"), kind: .movie, providerID: "p",
                                            categories: ["10": "EN | MOVIES 4K", "11": "TR | YERLI FILMLER"])
        XCTAssertEqual(items.count, 4)
        let matrix = items[0]
        XCTAssertEqual(matrix.name, "EN| The Matrix (1999) 4K")
        XCTAssertEqual(matrix.providerRating, 8.2)
        XCTAssertEqual(matrix.tmdbID, 603)
        XCTAssertEqual(matrix.year, 1999)
        XCTAssertEqual(matrix.containerExtension, "mkv")
        XCTAssertEqual(matrix.categoryName, "EN | MOVIES 4K")
        XCTAssertEqual(matrix.addedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(matrix.channelNumber)

        let ayla = items[1]
        XCTAssertEqual(ayla.ref.streamID, "2002")
        XCTAssertEqual(ayla.providerRating, 9.0)        // rating "" -> rating_5based "4.5" x 2
        XCTAssertNil(ayla.tmdbID)                        // "0"
        XCTAssertEqual(ayla.containerExtension, "mp4")  // ".MP4"
        XCTAssertEqual(ayla.year, 2017)                  // from releasedate
        XCTAssertEqual(ayla.releaseDate, "2017-10-27")
        XCTAssertEqual(ayla.cast, "Çetin Tekindor, İsmail Hacıoğlu")   // array joined
        XCTAssertEqual(ayla.genre, "Dram, Savaş")
        XCTAssertEqual(ayla.plot, "Kore Savaşı'nda bir Türk askeri...")
        XCTAssertNil(ayla.iconURL)

        let heat = items[2]
        XCTAssertEqual(heat.providerRating, 8.5)        // 0-100 scale
        XCTAssertEqual(heat.tmdbID, 949)                 // TMDB link
        XCTAssertEqual(heat.year, 1995)

        let junk = items[3]
        XCTAssertNil(junk.iconURL)                       // javascript: link dropped
        XCTAssertNil(junk.providerRating)
        XCTAssertNil(junk.containerExtension)
        XCTAssertNil(junk.categoryName)                  // unknown category id
    }

    func testSeriesItems() throws {
        let items = try XtreamDecoder.items(ProvidersFixture.data("xtream_series"), kind: .series, providerID: "p",
                                            categories: ["20": "EN | SERIES", "21": "TR | DIZILER"])
        XCTAssertEqual(items.map(\.ref.id), ["p|series|3001", "p|series|3002", "p|series|3003"])
        let breaking = items[0]
        XCTAssertEqual(breaking.iconURL, "https://image.tmdb.org/t/p/w600/ggFHVNu6YYI5L9pCfOacjizRGt.jpg")
        XCTAssertEqual(breaking.plot, "A high school chemistry teacher diagnosed with cancer turns to crime.")
        XCTAssertEqual(breaking.cast, "Bryan Cranston, Aaron Paul")
        XCTAssertEqual(breaking.director, "Vince Gilligan")
        XCTAssertEqual(breaking.genre, "Drama / Crime")
        XCTAssertEqual(breaking.releaseDate, "2008-01-20")
        XCTAssertEqual(breaking.year, 2008)
        XCTAssertEqual(breaking.providerRating, 9.5)
        XCTAssertEqual(breaking.backdropURLs, ["https://image.tmdb.org/t/p/w1280/tsRy63Mu5cu8etL1X7ZLyf7UP1M.jpg"])
        XCTAssertEqual(breaking.trailerYouTubeID, "HhesaQXLuRY")
        XCTAssertEqual(breaking.episodeRunTimeMinutes, 47)
        XCTAssertEqual(breaking.addedAt, Date(timeIntervalSince1970: 1_700_000_300))   // last_modified
        XCTAssertEqual(breaking.tmdbID, 1396)
        XCTAssertEqual(breaking.categoryName, "EN | SERIES")

        let kurtlar = items[1]
        XCTAssertNil(kurtlar.iconURL)
        XCTAssertNil(kurtlar.plot)
        XCTAssertNil(kurtlar.cast)
        XCTAssertEqual(kurtlar.year, 2003)                              // release_date spelling
        XCTAssertEqual(kurtlar.providerRating, 7.8)                     // rating "0" -> rating_5based 3.9
        XCTAssertEqual(kurtlar.backdropURLs, ["https://img.example.net/kv.jpg"])   // string, not array
        XCTAssertEqual(kurtlar.trailerYouTubeID, "dQw4w9WgXcQ")         // id taken from a watch URL
        XCTAssertNil(kurtlar.episodeRunTimeMinutes)
        XCTAssertEqual(kurtlar.addedAt, providersUTC(2023, 10, 1))     // date-only text
        XCTAssertEqual(kurtlar.categoryID, "21")                        // numeric id
        XCTAssertEqual(kurtlar.categoryName, "TR | DIZILER")

        let dark = items[2]
        XCTAssertEqual(dark.backdropURLs, [])
        XCTAssertNil(dark.trailerYouTubeID)
        XCTAssertEqual(dark.episodeRunTimeMinutes, 60)                  // "60 min"
        XCTAssertNil(dark.addedAt)                                      // 0
        XCTAssertEqual(dark.tmdbID, 70523)
    }

    // MARK: Details

    func testVodInfo() throws {
        let info = try XtreamDecoder.vodInfo(ProvidersFixture.data("xtream_vod_info"))
        XCTAssertEqual(info.tmdbID, 603)
        XCTAssertEqual(info.name, "The Matrix")
        XCTAssertEqual(info.originalName, "The Matrix")
        XCTAssertEqual(info.plot?.hasPrefix("Set in the 22nd century, The Matrix"), true)
        XCTAssertEqual(info.cast, "Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss")
        XCTAssertEqual(info.director, "Lana Wachowski, Lilly Wachowski")
        XCTAssertEqual(info.genre, "Action, Science Fiction")
        XCTAssertEqual(info.country, "United States of America")
        XCTAssertEqual(info.releaseDate, "1999-03-30")
        XCTAssertEqual(info.rating, 8.2)
        XCTAssertEqual(info.durationSeconds, 8160)
        XCTAssertEqual(info.posterURL, "https://image.tmdb.org/t/p/w600/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg")
        XCTAssertEqual(info.backdropURLs, ["https://image.tmdb.org/t/p/w1280/icmmSD4vTTDKOq2vvdulafOGw93.jpg"])   // "" and null dropped
        XCTAssertEqual(info.trailerYouTubeID, "vKQi3bBA1y8")
        XCTAssertEqual(info.tech, StreamTechInfo(videoCodec: "hevc", width: 3840, height: 1608, audioCodec: "eac3", audioChannels: 6, bitrateKbps: 18234))
        XCTAssertEqual(info.containerExtension, "mkv")   // from movie_data
    }

    func testVodInfoForUnknownTitle() throws {
        let info = try XtreamDecoder.vodInfo(ProvidersFixture.data("xtream_vod_info_empty"))   // "info": []
        XCTAssertEqual(info.name, "EN| Untitled Junk")
        XCTAssertEqual(info.containerExtension, "mp4")
        XCTAssertNil(info.plot)
        XCTAssertNil(info.tech)
        XCTAssertEqual(try XtreamDecoder.vodInfo(Data("[]".utf8)), RawItemInfo())
        XCTAssertEqual(try XtreamDecoder.vodInfo(Data("null".utf8)), RawItemInfo())
    }

    func testSeriesInfoWithSeasonKeyedEpisodes() throws {
        let ref = StreamRef(providerID: "p", kind: .series, streamID: "3001")
        let info = try XtreamDecoder.seriesInfo(ProvidersFixture.data("xtream_series_info_dict"), seriesRef: ref)
        XCTAssertEqual(info.seriesRef, ref)
        XCTAssertEqual(info.info?.name, "Breaking Bad")
        XCTAssertEqual(info.info?.posterURL, "https://image.tmdb.org/t/p/w600/ggFHVNu6YYI5L9pCfOacjizRGt.jpg")
        XCTAssertEqual(info.info?.tmdbID, 1396)
        XCTAssertEqual(info.info?.durationSeconds, 47 * 60)
        XCTAssertEqual(info.episodes.map(\.ref.streamID), ["40011", "40012", "40021"])   // sorted, duplicate dropped
        XCTAssertTrue(info.episodes.allSatisfy { $0.ref.kind == .episode && $0.ref.providerID == "p" })
        XCTAssertEqual(info.episodes.map(\.season), [1, 1, 2])
        XCTAssertEqual(info.episodes.map(\.episode), [1, 2, 1])

        let pilot = info.episodes[0]
        XCTAssertEqual(pilot.title, "Breaking Bad - S01E01 - Pilot")
        XCTAssertEqual(pilot.containerExtension, "mkv")
        XCTAssertNil(pilot.plot)                           // "info": [] on the episode
        XCTAssertNil(pilot.tech)

        let second = info.episodes[1]
        XCTAssertEqual(second.durationSeconds, 2880)        // "duration_secs" as a string
        XCTAssertEqual(second.rating, 8.1)
        XCTAssertNil(second.stillURL)                       // ""
        XCTAssertEqual(second.airDate, "2008-01-27")

        let seasonTwo = info.episodes[2]
        XCTAssertEqual(seasonTwo.tech, StreamTechInfo(videoCodec: "h264", width: 1920, height: 1080, audioCodec: "aac", audioChannels: 2, bitrateKbps: 4210))
        XCTAssertEqual(seasonTwo.stillURL, "https://image.tmdb.org/t/p/w300/ep201.jpg")

        XCTAssertEqual(info.seasons.map(\.number), [1, 2])
        XCTAssertEqual(info.seasons.map(\.episodeCount), [7, 13])   // the panel's own counts
        XCTAssertEqual(info.seasons[0].name, "Season 1")
        XCTAssertEqual(info.seasons[0].coverURL, "https://image.tmdb.org/t/p/w600/s1.jpg")
        XCTAssertNil(info.seasons[1].coverURL)
        XCTAssertEqual(info.episodesBySeason.map(\.season), [1, 2])
    }

    func testSeriesInfoWithArrayEpisodes() throws {
        let ref = StreamRef(providerID: "p", kind: .series, streamID: "3003")
        let info = try XtreamDecoder.seriesInfo(ProvidersFixture.data("xtream_series_info_array"), seriesRef: ref)
        XCTAssertEqual(info.episodes.map(\.ref.streamID), ["50011", "50012", "50021"])
        XCTAssertEqual(info.episodes.map(\.season), [1, 1, 2])           // second group has no "season": its position
        XCTAssertEqual(info.episodes[0].durationSeconds, 51 * 60)        // "51 min"
        XCTAssertEqual(info.episodes[2].durationSeconds, 3300)
        XCTAssertEqual(info.seasons.map(\.number), [1, 2])               // "seasons": [] -> derived
        XCTAssertEqual(info.seasons.map(\.episodeCount), [2, 1])
        XCTAssertNil(info.info?.rating)                                  // "0" and 0 are "unrated"
        XCTAssertEqual(info.info?.backdropURLs, ["http://img.example.net/dark-bg.jpg"])

        let unknown = try XtreamDecoder.seriesInfo(Data("[]".utf8), seriesRef: ref)
        XCTAssertNil(unknown.info)
        XCTAssertTrue(unknown.episodes.isEmpty && unknown.seasons.isEmpty)
    }

    // MARK: Short EPG

    func testShortEPG() throws {
        let programs = try XtreamDecoder.shortEPG(ProvidersFixture.data("xtream_short_epg"), channelKey: "BBCOne.uk")
        XCTAssertEqual(programs.map(\.title), ["BBC News at Six", "LIVE: Premier League – Arsenal v Chelsea", "Plain Title Not Base64"])
        XCTAssertEqual(programs[0].start, providersUTC(2026, 11, 6, 18, 0))
        XCTAssertEqual(programs[0].end, providersUTC(2026, 11, 6, 18, 30))
        XCTAssertEqual(programs[0].summary, "The latest national and international news.")
        XCTAssertTrue(programs[0].hasArchive)
        XCTAssertFalse(programs[0].isLive)
        XCTAssertTrue(programs[1].isLive)
        XCTAssertFalse(programs[1].hasArchive)              // "0"
        XCTAssertNil(programs[2].summary)                   // ""
        XCTAssertTrue(programs.allSatisfy { $0.channelKey == "BBCOne.uk" })
    }

    func testShortEPGWallClockTimesUseServerTimeZone() throws {
        let data = try ProvidersFixture.data("xtream_short_epg_strings")
        let istanbul = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        let local = try XtreamDecoder.shortEPG(data, channelKey: "k", serverTimeZone: istanbul)
        XCTAssertEqual(local.first?.title, "Morning Show")
        XCTAssertEqual(local.first?.start, providersUTC(2026, 11, 6, 6, 0))
        XCTAssertEqual(try XtreamDecoder.shortEPG(data, channelKey: "k").first?.start, providersUTC(2026, 11, 6, 9, 0))
        XCTAssertEqual(try XtreamDecoder.shortEPG(Data(#"{"epg_listings":[]}"#.utf8), channelKey: "k"), [])
        XCTAssertEqual(try XtreamDecoder.shortEPG(Data("null".utf8), channelKey: "k"), [])
    }

    // MARK: Tolerant readers

    func testJSONReadersTellBooleansFromNumbers() throws {
        let object = try XCTUnwrap(XtreamJSONKit.parse(Data(#"{"t":true,"f":false,"one":1,"zero":0,"d":7.5,"s":" 12 ","n":null,"big":12345678901234}"#.utf8)) as? [String: Any])
        XCTAssertNil(XtreamJSONKit.string(object["f"]))           // panels send false for "empty"
        XCTAssertNil(XtreamJSONKit.string(object["t"]))
        XCTAssertEqual(XtreamJSONKit.string(object["one"]), "1")
        XCTAssertEqual(XtreamJSONKit.string(object["zero"]), "0")
        XCTAssertEqual(XtreamJSONKit.string(object["d"]), "7.5")
        XCTAssertEqual(XtreamJSONKit.string(object["s"]), "12")
        XCTAssertEqual(XtreamJSONKit.string(object["big"]), "12345678901234")
        XCTAssertNil(XtreamJSONKit.string(object["n"]))
        XCTAssertNil(XtreamJSONKit.int(object["t"]))
        XCTAssertEqual(XtreamJSONKit.int(object["one"]), 1)
        XCTAssertEqual(XtreamJSONKit.int(object["s"]), 12)
        XCTAssertEqual(XtreamJSONKit.double(object["d"]), 7.5)
        XCTAssertEqual(XtreamJSONKit.bool(object["t"]), true)
        XCTAssertEqual(XtreamJSONKit.bool(object["zero"]), false)
        XCTAssertEqual(XtreamJSONKit.bool("1"), true)
        XCTAssertNil(XtreamJSONKit.bool(object["n"]))
    }

    func testTextHelpers() {
        XCTAssertEqual(ProviderTextKit.line("  A\u{202E}B\nC\u{0007}  "), "AB C")
        XCTAssertEqual(ProviderTextKit.paragraph("One\r\nTwo\r\n\r\n\r\n\r\nThree\u{202D}"), "One\nTwo\n\nThree")
        XCTAssertNil(ProviderTextKit.line(" \n "))
        XCTAssertEqual(ProviderTextKit.base64Text("QkJDIE5ld3M="), "BBC News")
        XCTAssertEqual(ProviderTextKit.base64Text("QkJDIE5ld3M"), "BBC News")       // missing padding
        XCTAssertNil(ProviderTextKit.base64Text("Plain title"))
        XCTAssertNil(ProviderTextKit.base64Text("News"))                             // decodes to non-text
        XCTAssertEqual(ProviderTextKit.minutes(fromDuration: "01:45:00"), 105)
        XCTAssertEqual(ProviderTextKit.minutes(fromDuration: "1h 45m"), 105)
        XCTAssertEqual(ProviderTextKit.minutes(fromDuration: "6300"), 105)
        XCTAssertEqual(ProviderTextKit.minutes(fromDuration: "45"), 45)
        XCTAssertNil(ProviderTextKit.minutes(fromDuration: "soon"))
        XCTAssertEqual(ProviderTextKit.youTubeID("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(ProviderTextKit.youTubeID("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(ProviderTextKit.youTubeID("https://evil.example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(ProviderTextKit.looksLive("LIVE: Arsenal v Chelsea"))
        XCTAssertTrue(ProviderTextKit.looksLive("NFL Sunday 🔴"))
        XCTAssertTrue(ProviderTextKit.looksLive("Live: Election night"))
        XCTAssertFalse(ProviderTextKit.looksLive("Live and Let Die"))
        XCTAssertFalse(ProviderTextKit.looksLive("Liverpool v Everton"))
    }
}
