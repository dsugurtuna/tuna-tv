import Foundation
import XCTest
@testable import TunaCore

/// One data-driven parser case of `Fixtures/curation/parser-cases.json`.
/// `expected` lists every non-default field; anything omitted must be the default (strict comparison).
struct CurationFixtureCase: Codable {
    var input: String
    var kind: String
    var category: String?
    var note: String?
    var expected: Expected

    struct Expected: Codable, Equatable {
        var title: String
        var key: String
        var year: Int?
        var season: Int?
        var episode: Int?
        var episodeTitle: String?
        var quality: String?
        var source: String?
        var hdr: String?
        var codec: String?
        var highFrameRate: Bool?
        var is3D: Bool?
        var languages: [String]?
        var countries: [String]?
        var regions: [String]?
        var audio: String?
        var platform: String?
        var isAdult: Bool?
        var isBackup: Bool?
        var timeshiftHours: Int?
        var isEvent: Bool?

        init(_ p: ParsedName) {
            title = p.title
            key = p.key
            year = p.year
            season = p.season
            episode = p.episode
            episodeTitle = p.episodeTitle
            quality = p.quality == .unknown ? nil : CurationFixtureCase.qualityName(p.quality)
            source = p.source?.rawValue
            hdr = p.hdr?.rawValue
            codec = p.codec?.rawValue
            highFrameRate = p.highFrameRate ? true : nil
            is3D = p.is3D ? true : nil
            languages = p.languages.isEmpty ? nil : p.languages
            countries = p.countries.isEmpty ? nil : p.countries
            regions = p.regions.isEmpty ? nil : p.regions
            audio = p.audio?.rawValue
            platform = p.platform
            isAdult = p.isAdult ? true : nil
            isBackup = p.isBackup ? true : nil
            timeshiftHours = p.timeshiftHours
            isEvent = p.isEvent ? true : nil
        }
    }

    static func qualityName(_ q: Quality) -> String {
        switch q {
        case .unknown: return "unknown"
        case .sd: return "sd"
        case .hd: return "hd"
        case .fhd: return "fhd"
        case .uhd: return "uhd"
        }
    }
}

final class NameParserFixtureTests: XCTestCase {
    static func loadCases() throws -> [CurationFixtureCase] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "parser-cases", withExtension: "json",
                                                  subdirectory: "Fixtures/curation"))
        return try JSONDecoder().decode([CurationFixtureCase].self, from: Data(contentsOf: url))
    }

    func testFixtureCases() throws {
        let cases = try Self.loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 150)
        var failures = 0
        for c in cases {
            let kind = try XCTUnwrap(StreamKind(rawValue: c.kind), c.input)
            let hints = c.category.map { CategoryParser.parse($0, kind: kind) }
            let got = CurationFixtureCase.Expected(NameParser.parse(c.input, kind: kind, category: hints))
            if got != c.expected {
                failures += 1
                let enc = JSONEncoder()
                enc.outputFormatting = [.sortedKeys]
                let g = String(decoding: try enc.encode(got), as: UTF8.self)
                let e = String(decoding: try enc.encode(c.expected), as: UTF8.self)
                XCTFail("\(c.kind) \"\(c.input)\"\n  expected \(e)\n  got      \(g)")
            }
        }
        print("parser fixture: \(cases.count) cases, \(failures) failures")
    }

    func testOriginalAndTagsArePopulated() {
        let p = NameParser.parse("EN| The Matrix (1999) 4K", kind: .movie)
        XCTAssertEqual(p.original, "EN| The Matrix (1999) 4K")
        XCTAssertEqual(p.tags, ["EN", "4K"])
        XCTAssertEqual(p.badgeLine, "4K · EN")
    }

    func testContractExamples() {
        let a = NameParser.parse("EN| The Matrix (1999) 4K", kind: .movie)
        XCTAssertEqual(a.title, "The Matrix")
        XCTAssertEqual(a.year, 1999)
        XCTAssertEqual(a.quality, .uhd)
        XCTAssertEqual(a.languages, ["en"])
        let b = NameParser.parse("|TR| Kurtlar Vadisi S01 E05", kind: .series)
        XCTAssertEqual(b.title, "Kurtlar Vadisi")
        XCTAssertEqual(b.season, 1)
        XCTAssertEqual(b.episode, 5)
        XCTAssertEqual(b.languages, ["tr"])
        let c = NameParser.parse("UK: BBC One FHD (Backup)", kind: .live)
        XCTAssertEqual(c.title, "BBC One")
        XCTAssertEqual(c.quality, .fhd)
        XCTAssertEqual(c.countries, ["GB"])
        XCTAssertTrue(c.isBackup)
    }

    func testCategoryFillsGaps() {
        let hints = CategoryParser.parse("TR | FİLMLER 4K", kind: .movie)
        let p = NameParser.parse("Ayla (2017)", kind: .movie, category: hints)
        XCTAssertEqual(p.languages, ["tr"])
        XCTAssertEqual(p.quality, .uhd)
        let explicit = NameParser.parse("EN| Ayla (2017) FHD", kind: .movie, category: hints)
        XCTAssertEqual(explicit.languages, ["en"])
        XCTAssertEqual(explicit.quality, .fhd)
    }

    func testDeterministic() {
        let names = ["EN| The Matrix (1999) 4K", "|AR| مسلسل الهيبة الحلقة 5", "🇹🇷 Kanal D ᴴᴰ"]
        for name in names {
            XCTAssertEqual(NameParser.parse(name, kind: .live), NameParser.parse(name, kind: .live))
        }
    }

    func testNeverCrashesOnJunk() {
        for name in ["", " ", "|", "((((", "]]]]", "----", "★★★", "🇹", "S01E", "+", "-1h", "()", "[]", "1x", "\u{200B}",
                     String(repeating: "(", count: 50), "a|b|c|d|e|f|g|h|i", "EN|", "|TR|"] {
            let p = NameParser.parse(name, kind: .movie)
            XCTAssertNotNil(p.title)
            _ = NameParser.parse(name, kind: .live)
            _ = NameParser.parse(name, kind: .series)
            _ = CategoryParser.parse(name, kind: .live)
        }
    }
}
