import Foundation
import XCTest
@testable import TunaCore

final class RequestRedactionTests: XCTestCase {
    private func summary(_ url: String, method: String = "GET") -> String {
        RequestRedaction.summary(for: URL(string: url)!, method: method)
    }

    func testKeepsPathAndActionOnly() {
        XCTAssertEqual(summary("http://panel.test:8080/player_api.php?username=alice&password=s3cret&action=get_series_info&series_id=9"),
                       "/player_api.php?action=get_series_info")
        XCTAssertEqual(summary("http://panel.test/player_api.php?username=alice&password=s3cret"), "/player_api.php")
        XCTAssertEqual(summary("http://panel.test/get.php?username=alice&password=s3cret&type=m3u_plus&output=ts"), "/get.php")
        XCTAssertEqual(summary("http://panel.test"), "/")
    }

    func testMasksPathSegmentsEqualToCredentials() {
        XCTAssertEqual(summary("http://panel.test/alice/s3cret/xmltv.php?username=alice&password=s3cret"), "/•••/•••/xmltv.php")
        // Percent-encoded credentials are compared decoded.
        XCTAssertEqual(summary("http://panel.test/p%40ss%20word/feed?USERNAME=bob&Password=p%40ss%20word"), "/•••/feed")
    }

    func testMasksXtreamStreamPathsWithoutQuery() {
        XCTAssertEqual(summary("http://panel.test:8080/live/alice/s3cret/1234.ts"), "/live/•••/•••/1234.ts")
        XCTAssertEqual(summary("http://panel.test/sub/movie/alice/s3cret/77.mkv"), "/sub/movie/•••/•••/77.mkv")
        XCTAssertEqual(summary("http://panel.test/timeshift/alice/s3cret/60/2027-01-15:08-00/5.ts"),
                       "/timeshift/•••/•••/60/2027-01-15:08-00/5.ts")
        XCTAssertEqual(summary("http://panel.test/live/logo.png"), "/live/logo.png")
    }

    func testPrefixesNonGetMethodsAndHonoursRegisteredSecrets() {
        XCTAssertEqual(summary("http://panel.test/player_api.php?action=x", method: "post"), "POST /player_api.php?action=x")
        TunaLog.shared.registerSecret("zq-registered-secret-zq")
        XCTAssertEqual(summary("http://panel.test/files/zq-registered-secret-zq.json"), "/files/•••.json")
    }

    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri, 15 Jan 2027 08:00:00 GMT
        func delay(_ value: String) -> TimeInterval? {
            HTTPResponse(status: 503, headers: ["Retry-After": value]).retryAfterDelay(now: now)
        }
        XCTAssertEqual(delay("120"), 120)
        XCTAssertEqual(delay(" 7 "), 7)
        XCTAssertEqual(delay("Fri, 15 Jan 2027 09:00:00 GMT") ?? -1, 3600, accuracy: 0.001)
        XCTAssertEqual(delay("Friday, 15-Jan-27 08:01:00 GMT") ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(delay("Fri Jan 15 08:00:30 2027") ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(delay("Thu, 14 Jan 2027 08:00:00 GMT"), 0, "a date in the past means no wait")
        XCTAssertNil(delay("-5"))
        XCTAssertNil(delay("soon"))
        XCTAssertNil(delay("inf"))
        XCTAssertNil(HTTPResponse(status: 503).retryAfterDelay(now: now))
    }
}
