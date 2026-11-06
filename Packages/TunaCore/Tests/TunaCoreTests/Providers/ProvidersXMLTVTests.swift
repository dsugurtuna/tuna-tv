import XCTest
@testable import TunaCore

final class ProvidersXMLTVTests: XCTestCase {
    private let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7, 6))

    func testDatesWithOffsets() {
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261106203000 +0300"), providersUTC(2026, 11, 6, 17, 30))
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261106203000+0300"), providersUTC(2026, 11, 6, 17, 30))
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261106203000 -0530"), providersUTC(2026, 11, 7, 2, 0))
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261106203000 +03:00"), providersUTC(2026, 11, 6, 17, 30))
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261106203000"), providersUTC(2026, 11, 6, 20, 30))       // no offset = UTC
        XCTAssertEqual(ProviderTextKit.xmltvDate("202611062030 +0100"), providersUTC(2026, 11, 6, 19, 30))   // no seconds
        XCTAssertEqual(ProviderTextKit.xmltvDate("20261231233000 -0100"), providersUTC(2027, 1, 1, 0, 30))   // crosses a year
        XCTAssertEqual(ProviderTextKit.xmltvDate("20240229120000 +0000"), providersUTC(2024, 2, 29, 12, 0))  // leap day
        XCTAssertNil(ProviderTextKit.xmltvDate("2026"))
        XCTAssertNil(ProviderTextKit.xmltvDate("20261306203000 +0300"))      // month 13
        XCTAssertNil(ProviderTextKit.xmltvDate("tomorrow"))
    }

    func testParsesProgrammes() throws {
        let programs = XMLTVParser.parse(try ProvidersFixture.data("guide", "xml"), channels: nil, window: window)
        let bbc = programs.filter { $0.channelKey == "BBCOne.uk" }
        XCTAssertEqual(bbc.map(\.title), ["BBC News at Six", "EastEnders", "A Question of Sport", "The Apprentice"])   // duplicate dropped

        let news = bbc[0]
        XCTAssertEqual(news.start, providersUTC(2026, 11, 6, 18, 0))
        XCTAssertEqual(news.end, providersUTC(2026, 11, 6, 18, 30))
        XCTAssertEqual(news.summary, "The latest national and international news & weather.")
        XCTAssertEqual(news.categories, ["News"])
        XCTAssertEqual(news.iconURL, "http://img.example.net/news.png")
        XCTAssertFalse(news.isNew)

        let soap = bbc[1]
        XCTAssertEqual(soap.title, "EastEnders")                      // the first <title> wins
        XCTAssertEqual(soap.subtitle, "Episode 7012")
        XCTAssertEqual(soap.categories, ["Drama", "Soap"])
        XCTAssertEqual(soap.episodeLabel, "S41 E12")                  // xmltv_ns "40.11.0/1" is zero-based
        XCTAssertTrue(soap.isNew)

        XCTAssertEqual(bbc[2].end, providersUTC(2026, 11, 6, 20, 0))  // no stop: ends when the next programme starts
        XCTAssertEqual(bbc[3].summary, "Business&nbsp;drama &copy; BBC")   // undeclared entities did not abort the parse

        let trt = programs.filter { $0.channelKey == "trt1.tr" }
        XCTAssertEqual(trt.count, 2)
        XCTAssertEqual(trt[0].title, "Kuruluş Osman")
        XCTAssertEqual(trt[0].start, providersUTC(2026, 11, 6, 17, 30))   // "+0300"
        XCTAssertEqual(trt[0].end, providersUTC(2026, 11, 6, 19, 0))
        XCTAssertEqual(trt[0].summary, "Osman Bey'in mücadelesi sürüyor.")   // CDATA
        XCTAssertEqual(trt[0].episodeLabel, "S7 E5")                     // onscreen "S07E05" normalized
        XCTAssertFalse(trt[0].isLive)
        XCTAssertTrue(trt[1].isLive)                                     // <live/>
        XCTAssertEqual(trt[1].categories, ["Sports"])

        XCTAssertTrue(programs.contains { $0.channelKey == "other.ch" })
        XCTAssertFalse(programs.contains { $0.title == "Far Future" })  // outside the window
        XCTAssertEqual(Set(programs.map(\.id)).count, programs.count)
        XCTAssertEqual(programs.map(\.channelKey), programs.map(\.channelKey).sorted())   // grouped by channel
    }

    func testChannelFilterIsCaseInsensitiveAndKeepsTheRequestedKey() throws {
        let data = try ProvidersFixture.data("guide", "xml")
        let programs = XMLTVParser.parse(data, channels: ["bbcone.uk"], window: window)
        XCTAssertEqual(programs.count, 4)
        XCTAssertTrue(programs.allSatisfy { $0.channelKey == "bbcone.uk" })
        XCTAssertEqual(XMLTVParser.parse(data, channels: ["trt1.tr", "missing.ch"], window: window).count, 2)
        XCTAssertEqual(XMLTVParser.parse(data, channels: [], window: window).count, 0)
    }

    func testWindowFilterKeepsOverlaps() throws {
        let data = try ProvidersFixture.data("guide", "xml")
        let narrow = DateInterval(start: providersUTC(2026, 11, 6, 18, 15), end: providersUTC(2026, 11, 6, 18, 45))
        XCTAssertEqual(XMLTVParser.parse(data, channels: ["BBCOne.uk"], window: narrow).map(\.title), ["BBC News at Six", "EastEnders"])
    }

    func testFileVariantMatchesDataVariant() throws {
        let data = try ProvidersFixture.data("guide", "xml")
        let fromFile = XMLTVParser.parse(fileURL: try ProvidersFixture.url("guide", "xml"), channels: nil, window: window)
        XCTAssertEqual(fromFile, XMLTVParser.parse(data, channels: nil, window: window))

        // A clean file (no entity repair needed) goes through the streaming parser.
        let clean = Data("""
        <?xml version="1.0" encoding="UTF-8"?><tv><programme start="20261106100000 +0000" stop="20261106110000 +0000" channel="a">\
        <title>Clean</title></programme></tv>
        """.utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tunatv-xmltv-\(UUID().uuidString).xml")
        try clean.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(XMLTVParser.parse(fileURL: file, channels: ["a"], window: window).map(\.title), ["Clean"])
        XCTAssertEqual(XMLTVParser.parse(fileURL: file.appendingPathExtension("missing"), channels: nil, window: window), [])
    }

    func testBrokenAndCompressedInput() {
        XCTAssertEqual(XMLTVParser.parse(Data([0x1F, 0x8B, 0x08, 0x00]), channels: nil, window: window), [])
        XCTAssertEqual(XMLTVParser.parse(Data("<html>oops".utf8), channels: nil, window: window), [])
        // A truncated download keeps what was complete.
        let truncated = Data("""
        <tv><programme start="20261106100000 +0000" stop="20261106110000 +0000" channel="a"><title>Whole</title></programme>\
        <programme start="20261106110000 +0000" stop="20261106120000 +0000" channel="a"><title>Cut
        """.utf8)
        XCTAssertEqual(XMLTVParser.parse(truncated, channels: nil, window: window).map(\.title), ["Whole"])
    }

    func testEpisodeLabels() {
        XCTAssertEqual(ProvidersXMLTVProbe.label(xmltv: "1.4.0/1", onscreen: nil), "S2 E5")
        XCTAssertEqual(ProvidersXMLTVProbe.label(xmltv: ".4.", onscreen: nil), "E5")
        XCTAssertEqual(ProvidersXMLTVProbe.label(xmltv: "2/3..", onscreen: nil), "S3")
        XCTAssertEqual(ProvidersXMLTVProbe.label(xmltv: nil, onscreen: "Episode 12"), "Episode 12")
        XCTAssertNil(ProvidersXMLTVProbe.label(xmltv: "..", onscreen: nil))
    }
}

/// Reaches the label logic through a tiny guide (the delegate itself is private).
enum ProvidersXMLTVProbe {
    static func label(xmltv: String?, onscreen: String?) -> String? {
        var episodes = ""
        if let xmltv { episodes += "<episode-num system=\"xmltv_ns\">\(xmltv)</episode-num>" }
        if let onscreen { episodes += "<episode-num system=\"onscreen\">\(onscreen)</episode-num>" }
        let xml = "<tv><programme start=\"20261106100000 +0000\" stop=\"20261106110000 +0000\" channel=\"a\"><title>T</title>\(episodes)</programme></tv>"
        let window = DateInterval(start: providersUTC(2026, 11, 6), end: providersUTC(2026, 11, 7))
        return XMLTVParser.parse(Data(xml.utf8), channels: nil, window: window).first?.episodeLabel
    }
}
