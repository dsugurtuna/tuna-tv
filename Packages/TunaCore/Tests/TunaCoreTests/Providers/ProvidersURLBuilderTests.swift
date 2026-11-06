import XCTest
@testable import TunaCore

final class ProvidersURLBuilderTests: XCTestCase {
    func testNormalizeServerTable() {
        let table: [(String, String?)] = [
            ("  example.com:8080/ ", "http://example.com:8080"),
            ("example.com", "http://example.com"),
            ("https://h.tv///", "https://h.tv"),
            ("HTTP://Panel.Example.COM:80/", "http://panel.example.com:80"),
            ("http://host:8080/player_api.php?username=u&password=p", "http://host:8080"),
            ("http://host:8080/player_api.php/", "http://host:8080"),
            ("host:8080/get.php?username=u&password=p&type=m3u_plus&output=ts", "http://host:8080"),
            ("http://host/sub/path/get.php?username=u", "http://host/sub/path"),
            ("http://host:2095/sub/", "http://host:2095/sub"),
            ("http://host/a//b/", "http://host/a/b"),
            ("http://host/XMLTV.PHP", "http://host"),
            ("http://host/panel_api.php?username=u&password=p", "http://host"),
            ("http://user:pass@host.example.com/#fragment", "http://host.example.com"),
            ("http://host/c/", "http://host/c"),
            ("\nhttps://secure.example.com:8443/iptv\t", "https://secure.example.com:8443/iptv"),
            ("http://[2001:db8::1]:8080/", "http://[2001:db8::1]:8080"),
            ("", nil),
            ("    ", nil),
            ("http://", nil),
            ("ftp://host.example.com", nil),
            ("http://host with space.com", nil),
        ]
        for (input, expected) in table {
            XCTAssertEqual(XtreamURLBuilder.normalizeServer(input), expected, "input: \(input.debugDescription)")
        }
    }

    func testParseFullLink() throws {
        let m3u = try XCTUnwrap(XtreamURLBuilder.parseFullLink("http://host.example.com:8080/get.php?username=tuna&password=p4ss&type=m3u_plus&output=ts"))
        XCTAssertEqual(m3u.server, "http://host.example.com:8080")
        XCTAssertEqual(m3u.username, "tuna")
        XCTAssertEqual(m3u.password, "p4ss")

        let api = try XCTUnwrap(XtreamURLBuilder.parseFullLink(" host.example.com/sub/player_api.php?password=a%26b%2Bc&username=me%40mail.com "))
        XCTAssertEqual(api.server, "http://host.example.com/sub")
        XCTAssertEqual(api.username, "me@mail.com")
        XCTAssertEqual(api.password, "a&b+c")

        // A literal "+" stays a plus (not a space); "&amp;" copied out of a web page still works.
        let literal = try XCTUnwrap(XtreamURLBuilder.parseFullLink("http://h/get.php?username=u&amp;password=p+q"))
        XCTAssertEqual(literal.username, "u")
        XCTAssertEqual(literal.password, "p+q")

        // A pasted stream URL carries the credentials in its path.
        let stream = try XCTUnwrap(XtreamURLBuilder.parseFullLink("http://h.example.com:8080/live/tuna/p%40ss/1001.ts"))
        XCTAssertEqual(stream.server, "http://h.example.com:8080")
        XCTAssertEqual(stream.username, "tuna")
        XCTAssertEqual(stream.password, "p@ss")

        XCTAssertNil(XtreamURLBuilder.parseFullLink("http://host.example.com:8080/get.php?type=m3u_plus"))
        XCTAssertNil(XtreamURLBuilder.parseFullLink("http://host.example.com:8080/get.php?username=&password=p"))
        XCTAssertNil(XtreamURLBuilder.parseFullLink("not a url at all"))
    }

    func testAPIURLEncodesCredentialsAndSortsParams() {
        let base = XtreamURLBuilder.apiURL(server: "h", username: "u", password: "a&b+c", action: nil)
        XCTAssertEqual(base?.absoluteString, "http://h/player_api.php?username=u&password=a%26b%2Bc")
        let list = XtreamURLBuilder.apiURL(server: "h", username: "u", password: "a&b+c", action: "get_live_streams")
        XCTAssertEqual(list?.absoluteString, "http://h/player_api.php?username=u&password=a%26b%2Bc&action=get_live_streams")
        let epg = XtreamURLBuilder.apiURL(server: "http://h:8080/", username: " u ", password: "p", action: "get_short_epg",
                                          params: ["stream_id": "12", "limit": "4"])
        XCTAssertEqual(epg?.absoluteString, "http://h:8080/player_api.php?username=u&password=p&action=get_short_epg&limit=4&stream_id=12")
        XCTAssertNil(XtreamURLBuilder.apiURL(server: "", username: "u", password: "p", action: nil))
    }

    func testXMLTVURL() {
        XCTAssertEqual(XtreamURLBuilder.xmltvURL(server: "http://h:8080/sub/", username: "us er", password: "p/w")?.absoluteString,
                       "http://h:8080/sub/xmltv.php?username=us%20er&password=p%2Fw")
    }

    func testStreamURLs() {
        XCTAssertEqual(XtreamURLBuilder.liveURL(server: "  example.com:8080/ ", username: "u", password: "p", streamID: "12", format: "ts")?.absoluteString,
                       "http://example.com:8080/live/u/p/12.ts")
        XCTAssertEqual(XtreamURLBuilder.liveURL(server: "h", username: "us er", password: "p@ss/w", streamID: "1", format: "m3u8")?.absoluteString,
                       "http://h/live/us%20er/p%40ss%2Fw/1.m3u8")
        XCTAssertEqual(XtreamURLBuilder.liveURL(server: "h", username: "u", password: "p", streamID: "1", format: "")?.absoluteString,
                       "http://h/live/u/p/1.ts")
        XCTAssertEqual(XtreamURLBuilder.movieURL(server: "https://h.tv///", username: "u", password: "p", streamID: "3", ext: "mkv")?.absoluteString,
                       "https://h.tv/movie/u/p/3.mkv")
        XCTAssertEqual(XtreamURLBuilder.movieURL(server: "h", username: "u", password: "p", streamID: "3", ext: ".MKV")?.absoluteString,
                       "http://h/movie/u/p/3.mkv")
        XCTAssertEqual(XtreamURLBuilder.movieURL(server: "h", username: "u", password: "p", streamID: "3", ext: "")?.absoluteString,
                       "http://h/movie/u/p/3.mp4")
        XCTAssertEqual(XtreamURLBuilder.episodeURL(server: "h", username: "u", password: "p", episodeID: "40011", ext: "mkv")?.absoluteString,
                       "http://h/series/u/p/40011.mkv")
        XCTAssertNil(XtreamURLBuilder.movieURL(server: "h", username: "u", password: "p", streamID: " ", ext: "mkv"))
    }

    func testCatchupURLIsFormattedInServerTimeZone() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(XtreamURLBuilder.catchupURL(server: "h", username: "u", password: "p", streamID: "5", start: start,
                                                   durationMinutes: 60, serverTimeZone: utc)?.absoluteString,
                       "http://h/timeshift/u/p/60/2023-11-14:22-13/5.ts")
        let istanbul = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))   // UTC+3: the next day on the panel
        XCTAssertEqual(XtreamURLBuilder.catchupURL(server: "http://h:8080", username: "u", password: "p&q", streamID: "5", start: start,
                                                   durationMinutes: 0, serverTimeZone: istanbul)?.absoluteString,
                       "http://h:8080/timeshift/u/p%26q/1/2023-11-15:01-13/5.ts")
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))   // summer time is honoured
        let july = providersUTC(2026, 7, 1, 2, 5)
        XCTAssertEqual(XtreamURLBuilder.catchupURL(server: "h", username: "u", password: "p", streamID: "9", start: july,
                                                   durationMinutes: 90, serverTimeZone: newYork)?.absoluteString,
                       "http://h/timeshift/u/p/90/2026-06-30:22-05/9.ts")
    }

    func testCacheKeyPrefixIsPathSafe() {
        XCTAssertEqual(ProviderSession.cacheKeyPrefix(for: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"), "providers/6F9619FF-8B86-D011-B42D-00CF4FC964FF/")
        XCTAssertEqual(ProviderSession.cacheKeyPrefix(for: "../etc"), "providers/%2E%2E%2Fetc/")
    }
}
