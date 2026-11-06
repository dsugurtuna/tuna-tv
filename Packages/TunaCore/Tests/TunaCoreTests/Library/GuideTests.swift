import XCTest
@testable import TunaCore

final class GuideTests: XCTestCase {
    let t0 = LF.now

    func program(_ key: String, _ startMinutes: Double, _ endMinutes: Double, _ title: String, live: Bool = false,
                 categories: [String] = [], subtitle: String? = nil) -> Program {
        Program(channelKey: key, start: t0.addingTimeInterval(startMinutes * 60), end: t0.addingTimeInterval(endMinutes * 60),
                title: title, subtitle: subtitle, categories: categories, isLive: live)
    }

    func testNowNextInterval() {
        let guide = Guide(programs: [
            program("a", 60, 120, "C"), program("a", 0, 60, "B"), program("a", -60, 0, "A"), program("b", 0, 30, "X"),
        ])
        XCTAssertEqual(guide.channelKeys, ["a", "b"])
        XCTAssertEqual(guide.now("a", at: t0)?.title, "B")
        XCTAssertEqual(guide.now("a", at: t0.addingTimeInterval(-1))?.title, "A")
        XCTAssertEqual(guide.now("a", at: t0.addingTimeInterval(59 * 60))?.title, "B")
        XCTAssertNil(guide.now("a", at: t0.addingTimeInterval(500 * 60)))
        XCTAssertNil(guide.now("zzz", at: t0))
        XCTAssertEqual(guide.next("a", after: t0)?.title, "C")
        XCTAssertEqual(guide.next("a", after: t0.addingTimeInterval(-30 * 60))?.title, "B")
        XCTAssertNil(guide.next("a", after: t0.addingTimeInterval(61 * 60)))
        let window = DateInterval(start: t0.addingTimeInterval(-10 * 60), duration: 80 * 60)
        XCTAssertEqual(guide.programs("a", in: window).map(\.title), ["A", "B", "C"])
        XCTAssertEqual(guide.programs("a", in: DateInterval(start: t0, duration: 60 * 60)).map(\.title), ["B"])
        XCTAssertEqual(guide.programs("a", in: DateInterval(start: t0, duration: 0)).map(\.title), ["B"])
        XCTAssertTrue(Guide.empty.channelKeys.isEmpty)
    }

    func testOverlapsAndMerge() {
        let guide = Guide(programs: [program("a", -120, 120, "Marathon"), program("a", -30, 10, "Short")])
        XCTAssertEqual(guide.now("a", at: t0)?.title, "Short")
        XCTAssertEqual(guide.now("a", at: t0.addingTimeInterval(20 * 60))?.title, "Marathon")
        let merged = guide.merging([program("a", -30, 10, "Short (updated)"), program("c", 0, 10, "New")])
        XCTAssertEqual(merged.now("a", at: t0)?.title, "Short (updated)")
        XCTAssertEqual(merged.allPrograms.count, 3)
        XCTAssertEqual(merged.channelKeys, ["a", "c"])
        let deduped = Guide(programs: [program("a", 0, 10, "One"), program("a", 0, 10, "Two")])
        XCTAssertEqual(deduped.allPrograms.map(\.title), ["Two"])
    }

    func testLiveEventDetector() {
        func p(_ title: String, live: Bool = false, categories: [String] = []) -> Program { program("k", 0, 60, title, live: live, categories: categories) }
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Arsenal vs Chelsea")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("England v France")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("LIVE Darts")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Live: Election Night")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("🔴 Breaking")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Snooker (L)")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Anything", live: true)))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Monaco Grand Prix")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Süper Lig: Galatasaray - Fenerbahçe")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("UFC 300")))
        XCTAssertTrue(LiveEventDetector.isLiveEvent(p("Cup Final", categories: ["Sports"])))
        XCTAssertFalse(LiveEventDetector.isLiveEvent(p("Final Destination", categories: ["Movie"])))
        XCTAssertFalse(LiveEventDetector.isLiveEvent(p("Live and Kicking")))
        XCTAssertFalse(LiveEventDetector.isLiveEvent(p("Premier League Highlights")))
        XCTAssertFalse(LiveEventDetector.isLiveEvent(p("The Evening News")))

        XCTAssertEqual(LiveEventDetector.sportsKind(p("Premier League: Arsenal vs Chelsea")), "Football")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("NFL: Chiefs vs Bills")), "American Football")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("NBA Lakers v Celtics")), "Basketball")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("NHL Tonight")), "Ice Hockey")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("MLB: Yankees vs Red Sox")), "Baseball")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("F1 Monaco Grand Prix")), "Motorsport")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("ATP Masters")), "Tennis")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("Boxing: Fury v Usyk")), "Fighting")
        XCTAssertEqual(LiveEventDetector.sportsKind(p("Galatasaray vs Fenerbahçe", categories: ["Soccer"])), "Football")
        XCTAssertNil(LiveEventDetector.sportsKind(p("Election Night")))
    }

    func testLiveEventsOrdering() {
        let channels = [LF.channel("news", epg: "news"), LF.channel("foot", epg: "foot"), LF.channel("f1", epg: "f1"), LF.channel("none")]
        let guide = Guide(programs: [
            program("news", -30, 30, "LIVE: Election Night"),
            program("foot", -10, 100, "Arsenal vs Chelsea", categories: ["Football"]),
            program("f1", -60, 60, "F1: Monaco Grand Prix"),
            program("f1", 60, 120, "Paddock Talk"),
        ])
        let events = guide.liveEvents(at: t0, channels: channels)
        XCTAssertEqual(events.map(\.program.title), ["F1: Monaco Grand Prix", "Arsenal vs Chelsea", "LIVE: Election Night"])
        XCTAssertEqual(events.first?.channel.id, "live:f1:gb")
        XCTAssertTrue(guide.liveEvents(at: t0.addingTimeInterval(7200 * 3), channels: channels).isEmpty)
    }
}

final class InsightsTests: XCTestCase {
    func testBuild() {
        let rich = LF.rich()
        var state = UserState()
        state.record(HistoryEntry(kind: .title, itemID: "movie:m1:1991", watchedAt: LF.now, secondsWatched: 5400))
        state.record(HistoryEntry(kind: .channel, itemID: "live:bbc:gb", watchedAt: LF.now, secondsWatched: 1800))
        let report = InsightsReport.build(library: rich.library, metadata: rich.metadata, userState: state)
        XCTAssertEqual(report.totalRaw, 115)
        XCTAssertEqual(report.totalTitles, 53)
        XCTAssertEqual(report.duplicatesMerged, 7)
        XCTAssertEqual(report.showcaseShare, 50.0 / 53.0, accuracy: 1e-9)
        XCTAssertEqual(report.qualityBreakdown.first?.label, "4K")
        XCTAssertEqual(report.qualityBreakdown.map(\.count).reduce(0, +), 52)
        XCTAssertEqual(report.languageBreakdown.first?.code, "en")
        XCTAssertEqual(report.languageBreakdown.first(where: { $0.code == "tr" })?.count, 16)
        XCTAssertEqual(report.countryBreakdown.first(where: { $0.code == "TR" })?.count, 16)
        XCTAssertEqual(report.genreBreakdown.prefix(3).map(\.name), ["Action", "Comedy", "Drama"])
        XCTAssertEqual(report.decadeBreakdown.map(\.decade), [1950, 1980, 1990, 2000, 2010])
        XCTAssertEqual(report.vaultBreakdown.map(\.shelf), [.legacy, .otherLanguages, .adult])
        XCTAssertEqual(report.metadataCoverage, 50.0 / 52.0, accuracy: 1e-9)
        XCTAssertEqual(report.hoursWatched, 2, accuracy: 1e-9)
        let empty = InsightsReport.build(library: .empty, metadata: [:], userState: UserState())
        XCTAssertEqual(empty.totalTitles, 0)
        XCTAssertEqual(empty.showcaseShare, 0)
    }
}
