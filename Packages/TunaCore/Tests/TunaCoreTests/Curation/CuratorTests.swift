import XCTest
@testable import TunaCore

enum CurationFixtures {
    static func item(_ name: String, _ kind: StreamKind = .movie, id: String? = nil, provider: String = "p1",
                     category: String? = nil, icon: String? = nil, year: Int? = nil) -> RawItem {
        let sid = id ?? String(UInt(bitPattern: name.hashValue) % 1_000_000_007) + "-" + String(name.count)
        return RawItem(ref: StreamRef(providerID: provider, kind: kind, streamID: sid), name: name, categoryName: category,
                       iconURL: icon, year: year)
    }

    static func catalog(_ items: [RawItem], provider: String = "p1") -> ProviderCatalog {
        ProviderCatalog(providerID: provider, items: items)
    }

    /// Prefs with relaxing off so placement tests see the raw rules.
    static func strict(_ worlds: WorldSelection = .english) -> ContentPreferences {
        ContentPreferences(worlds: worlds, autoRelaxShowcase: false)
    }
}

final class CuratorTests: XCTestCase {
    typealias F = CurationFixtures

    func testDuplicatesMergeIntoOneTitle() throws {
        let items = [F.item("EN| The Matrix (1999) 4K", id: "1"), F.item("The Matrix 1999 FHD", id: "2"),
                     F.item("|TR| The Matrix (1999) Türkçe Dublaj", id: "3")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(out.movies.count, 1)
        let title = try XCTUnwrap(out.movies.first)
        XCTAssertEqual(title.id, "movie:matrix:1999")
        XCTAssertEqual(title.name, "The Matrix")
        XCTAssertEqual(title.variants.count, 3)
        XCTAssertEqual(title.variants.first?.id, "p1|movie|1")
        XCTAssertEqual(title.variants.last?.id, "p1|movie|3")
        XCTAssertFalse(title.variants.last!.matchesWorld)
        XCTAssertEqual(title.variants[0].score, 4 * 100 + 300)
        XCTAssertEqual(title.placement, .showcase)
        XCTAssertEqual(title.bestQuality, .uhd)
        XCTAssertEqual(out.stats.duplicatesMerged, 2)
        XCTAssertEqual(out.stats.rawCounts["movie"], 3)
        XCTAssertEqual(out.stats.titleCounts["movie"], 1)
    }

    func testYearlessRecordJoinsSingleYearGroup() {
        let out = Curator(preferences: F.strict()).curate([F.catalog([
            F.item("The Matrix (1999) 4K", id: "1"), F.item("The Matrix FHD", id: "2"),
            F.item("Dune (1984)", id: "3"), F.item("Dune (2021) 4K", id: "4"), F.item("Dune 4K", id: "5"),
        ])])
        XCTAssertEqual(out.movies.map(\.id), ["movie:matrix:1999", "movie:dune:1984", "movie:dune:2021", "movie:dune:0"])
        XCTAssertEqual(out.movies[0].variants.count, 2)
    }

    func testShowcaseVersusVaultShelves() {
        let items = [
            F.item("Uhd Movie (2020) 4K", id: "1"),
            F.item("Disc Movie (2019) 1080p BluRay", id: "2"),
            F.item("Fhd Movie (2018) 1080p WEB-DL", id: "3"),
            F.item("Old Movie (1950)", id: "4"),
            F.item("Cam Movie (2024) 4K HDCAM", id: "5"),
            F.item("|TR| Yerli Film (2015) 4K", id: "6"),
            F.item("Dvd Movie (2001) DVDRip", id: "7"),
        ]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        let shelf = Dictionary(uniqueKeysWithValues: out.movies.map { ($0.name, $0.placement) })
        XCTAssertEqual(shelf["Uhd Movie"], .showcase)
        XCTAssertEqual(shelf["Disc Movie"], .vault(.disc))
        XCTAssertEqual(shelf["Fhd Movie"], .vault(.highDefinition))
        XCTAssertEqual(shelf["Old Movie"], .vault(.legacy))
        XCTAssertEqual(shelf["Cam Movie"], .vault(.lowQuality))
        XCTAssertEqual(shelf["Yerli Film"], .vault(.otherLanguages))
        XCTAssertEqual(shelf["Dvd Movie"], .vault(.disc))
        XCTAssertEqual(out.stats.showcaseCounts["movie"], 1)
        XCTAssertEqual(out.stats.vaultCounts["disc"], 2)
        XCTAssertEqual(out.stats.vaultCounts["otherLanguages"], 1)
        XCTAssertFalse(out.stats.showcaseRelaxed)
    }

    func testAutoRelaxBelowThresholdPerKind() {
        var items: [RawItem] = [F.item("Only Uhd (2020) 4K", id: "u")]
        for i in 0..<5 { items.append(F.item("Movie \(i) (2010) 1080p", id: "m\(i)")) }
        items.append(F.item("Show One S01E01 1080p", .series, id: "s1"))
        var prefs = ContentPreferences(relaxThreshold: 3)
        let relaxed = Curator(preferences: prefs).curate([F.catalog(items)])
        XCTAssertTrue(relaxed.stats.showcaseRelaxed)
        XCTAssertEqual(relaxed.stats.showcaseCounts["movie"], 6)
        XCTAssertEqual(relaxed.stats.showcaseCounts["series"], 1)

        prefs.relaxThreshold = 1
        let enough = Curator(preferences: prefs).curate([F.catalog(items)])
        XCTAssertEqual(enough.stats.showcaseCounts["movie"], 1)
        XCTAssertEqual(enough.stats.showcaseCounts["series"], 1)  // series still relaxed: 0 < 1
        XCTAssertTrue(enough.stats.showcaseRelaxed)

        prefs.autoRelaxShowcase = false
        let off = Curator(preferences: prefs).curate([F.catalog(items)])
        XCTAssertEqual(off.stats.showcaseCounts["movie"], 1)
        XCTAssertEqual(off.stats.showcaseCounts["series"], 0)
        XCTAssertFalse(off.stats.showcaseRelaxed)

        let empty = Curator(preferences: ContentPreferences()).curate([])
        XCTAssertFalse(empty.stats.showcaseRelaxed)
    }

    func testAddingTurkeyMovesTurkishContentIntoShowcase() throws {
        let items = [F.item("|TR| Ayla (2017) 4K", id: "1"), F.item("TR: Kanal D HD", .live, id: "2"),
                     F.item("EN| The Matrix (1999) 4K", id: "3"), F.item("|TR| The Matrix (1999) 4K Türkçe Dublaj", id: "4")]
        let english = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(english.movies.first { $0.name == "Ayla" }?.placement, .vault(.otherLanguages))
        XCTAssertEqual(english.channels.first?.placement, .vault(.otherLanguages))

        let worlds = WorldSelection.english.adding(country: "TR", language: "tr")
        let both = Curator(preferences: F.strict(worlds)).curate([F.catalog(items)])
        XCTAssertEqual(both.movies.first { $0.name == "Ayla" }?.placement, .showcase)
        XCTAssertEqual(both.channels.first?.placement, .showcase)
        let matrix = try XCTUnwrap(both.movies.first { $0.name == "The Matrix" })
        XCTAssertTrue(matrix.variants.allSatisfy(\.matchesWorld))
        XCTAssertEqual(matrix.defaultVariant?.id, "p1|movie|3")  // primary language first on a score tie
    }

    func testOtherLanguageShelfAndScriptHint() {
        let items = [F.item("مسلسل الهيبة", .series, id: "1"), F.item("Untagged Show", .series, id: "2"),
                     F.item("الجزيرة", .live, id: "3")]
        let out = Curator(preferences: ContentPreferences(showcaseQuality: .everything)).curate([F.catalog(items)])
        XCTAssertEqual(out.series.first { $0.name == "مسلسل الهيبة" }?.placement, .vault(.otherLanguages))
        XCTAssertEqual(out.series.first { $0.name == "Untagged Show" }?.placement, .showcase)
        XCTAssertEqual(out.channels.first?.placement, .vault(.otherLanguages))
        let arabic = ContentPreferences(worlds: WorldSelection(languages: ["ar"], countries: ["SA"]), showcaseQuality: .everything)
        XCTAssertEqual(Curator(preferences: arabic).curate([F.catalog(items)]).channels.first?.placement, .showcase)
    }

    func testUntaggedAssumedInWorld() {
        let out = Curator(preferences: F.strict()).curate([F.catalog([F.item("Some Movie (2020) 4K", id: "1"),
                                                                      F.item("Some Channel HD", .live, id: "2")])])
        XCTAssertEqual(out.movies.first?.placement, .showcase)
        XCTAssertTrue(out.movies.first?.variants.first?.matchesWorld ?? false)
        XCTAssertEqual(out.channels.first?.placement, .showcase)
    }

    func testAdultIsolation() {
        let items = [F.item("XXX | Brazzers HD", .live, id: "1"), F.item("Hot Night (2020) 4K", id: "2", category: "XXX | ADULT"),
                     F.item("Adult Swim HD", .live, id: "3")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(out.channels.first { $0.name == "Brazzers" }?.placement, .vault(.adult))
        XCTAssertEqual(out.channels.first { $0.name == "Brazzers" }?.categories, [.xxx])
        XCTAssertEqual(out.movies.first?.placement, .vault(.adult))
        XCTAssertTrue(out.movies.first?.isAdult ?? false)
        XCTAssertEqual(out.channels.first { $0.name == "Adult Swim" }?.placement, .showcase)
        XCTAssertEqual(out.stats.adultHidden, 2)
        XCTAssertEqual(out.stats.showcaseCounts["movie"], 0)
        XCTAssertEqual(out.stats.vaultCounts["adult"], 2)
    }

    func testLiveBackupOrderingAndMerge() throws {
        let items = [F.item("BBC One (Backup)", .live, id: "b", category: "UK | ENTERTAINMENT", icon: "http://logo/b.png"),
                     F.item("UK: BBC One HD", .live, id: "hd"), F.item("UK: BBC One FHD", .live, id: "fhd"),
                     F.item("UK: BBC One FHD (Backup)", .live, id: "fhdb")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(out.channels.count, 1)
        let ch = try XCTUnwrap(out.channels.first)
        XCTAssertEqual(ch.id, "live:bbc one:gb")
        XCTAssertEqual(ch.name, "BBC One")
        XCTAssertEqual(ch.variants.map(\.raw.ref.streamID), ["fhd", "fhdb", "hd", "b"])
        XCTAssertEqual(ch.defaultVariant?.raw.ref.streamID, "fhd")
        XCTAssertEqual(ch.logoURL, "http://logo/b.png")
        XCTAssertEqual(ch.groupName, "Entertainment")
        XCTAssertEqual(ch.categories.first, .entertainment)
        XCTAssertEqual(ch.bestQuality, .fhd)
    }

    func testFailingVariantsAreDemoted() throws {
        let items = [F.item("UK: ITV FHD", .live, id: "a"), F.item("UK: ITV HD", .live, id: "b")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)], failingVariants: ["p1|live|a": 3])
        XCTAssertEqual(try XCTUnwrap(out.channels.first).variants.map(\.raw.ref.streamID), ["b", "a"])
        let verified = Curator(preferences: F.strict()).curate([F.catalog([F.item("Fake (2020) 4K", id: "x")])],
                                                                 verifiedQualities: ["p1|movie|x": Quality.fhd.rawValue])
        XCTAssertEqual(verified.movies.first?.bestQuality, .fhd)
        XCTAssertEqual(verified.movies.first?.placement, .vault(.highDefinition))
    }

    func testTimeshiftKeptSeparate() {
        let items = [F.item("UK: ITV HD", .live, id: "1"), F.item("UK: ITV+1 HD", .live, id: "2"),
                     F.item("UK: ITV +1", .live, id: "3")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(out.channels.map(\.id), ["live:itv:gb", "live:itv +1:gb"])
        XCTAssertEqual(out.channels.map(\.name), ["ITV", "ITV +1"])
        XCTAssertEqual(out.channels[1].variants.count, 2)
    }

    func testSeriesIdsAndJunk() {
        let items = [F.item("Doctor Who (2005)", .series, id: "1"), F.item("EN| Doctor Who (2005) 4K", .series, id: "2"),
                     F.item("Doctor Who (1963)", .series, id: "3"), F.item("##### UK SPORTS #####", .live, id: "4"),
                     F.item("Kurtlar Vadisi", .series, id: "5")]
        let out = Curator(preferences: F.strict()).curate([F.catalog(items)])
        XCTAssertEqual(out.series.map(\.id), ["series:doctor who", "series:doctor who:1963", "series:kurtlar vadisi"])
        XCTAssertEqual(out.channels.first?.placement, .vault(.unsorted))
    }

    func testCrossProviderMergeDeterminismAndStats() {
        let a = F.catalog([F.item("EN| Inception (2010) 4K HDR", id: "1", provider: "a"),
                           F.item("Inception 2010 1080p", id: "2", provider: "a")], provider: "a")
        let b = F.catalog([F.item("|DE| Inception (2010) 4K", id: "9", provider: "b"),
                           F.item("DE: Das Erste HD", .live, id: "10", provider: "b")], provider: "b")
        let curator = Curator(preferences: F.strict())
        let one = curator.curate([a, b])
        let two = curator.curate([a, b])
        XCTAssertEqual(one.movies, two.movies)
        XCTAssertEqual(one.channels, two.channels)
        XCTAssertEqual(one.stats, two.stats)
        XCTAssertEqual(one.movies.count, 1)
        XCTAssertEqual(one.movies[0].variants.count, 3)
        XCTAssertEqual(one.movies[0].hdr, .hdr)
        XCTAssertEqual(one.movies[0].languages, ["en", "de"])
        XCTAssertEqual(one.stats.qualityCounts["uhd"], 1)
        XCTAssertEqual(one.stats.languageCounts["de"], 2)
        XCTAssertEqual(one.stats.countryCounts["DE"], 2)
        XCTAssertEqual(one.stats.rawCounts["live"], 1)
        XCTAssertEqual(one.channels.first?.placement, .vault(.otherLanguages))
    }

    func testCategoryIDResolutionAndChannelCategories() {
        var catalog = F.catalog([RawItem(ref: StreamRef(providerID: "p1", kind: .live, streamID: "1"), name: "beIN Sports 1 HD",
                                         categoryID: "7")])
        catalog.categories = [RawCategory(id: "7", name: "AR | SPORTS", kind: .live)]
        let out = Curator(preferences: F.strict()).curate([catalog])
        XCTAssertEqual(out.channels.first?.languages, ["ar"])
        XCTAssertEqual(out.channels.first?.categories.first, .sports)
        XCTAssertEqual(out.channels.first?.groupName, "Sports")
    }

    func testShowLowQualityOff() {
        let prefs = ContentPreferences(autoRelaxShowcase: false, showLowQuality: false)
        let out = Curator(preferences: prefs).curate([F.catalog([F.item("Cam (2024) HDCAM", id: "1"),
                                                                 F.item("Good (2024) 4K", id: "2")])])
        XCTAssertEqual(out.movies.map(\.name), ["Good"])
    }

    func testScoreFormula() {
        let p = NameParser.parse("Movie (2020) 4K HDR HEVC", kind: .movie)
        XCTAssertEqual(Curator.score(for: p, matchesWorld: true), 400 + 20 + 300 + 5)
        let cam = NameParser.parse("Movie (2020) HDCAM", kind: .movie)
        XCTAssertEqual(Curator.score(for: cam, matchesWorld: false, failures: 1), -400 - 80)
        let backup = NameParser.parse("UK: BBC One FHD (Backup)", kind: .live)
        XCTAssertEqual(Curator.score(for: backup, matchesWorld: true), 300 + 300 - 50)
        XCTAssertTrue(Curator.matchesWorld(NameParser.parse("NORDIC | TV4", kind: .live),
                                           worlds: WorldSelection(languages: ["sv"], countries: ["SE"])))
    }
}

final class CurationPerformanceTests: XCTestCase {
    /// 150k mixed names (ASCII, Turkish, Arabic, superscripts; movie/series/live). The batch API spreads work over
    /// all cores; single-thread throughput is printed and guarded against large regressions.
    func testParses150kNamesQuickly() {
        let base = ["EN| The Matrix (1999) 4K", "|TR| Kurtlar Vadisi S01 E01", "UK: BBC One FHD", "NF-4K | Wednesday S02E03",
                    "AR: الجزيرة HD", "Dune Part Two (2024) HDCAM", "DE - Das Boot (1981) BluRay 1080p", "ITV+1 HD",
                    "Muhteşem Yüzyıl 1. Sezon 3. Bölüm", "◉ AR | MBC 1 ᴴᴰ"]
        let kinds: [StreamKind] = [.movie, .series, .live, .series, .live, .movie, .movie, .live, .series, .live]
        var byKind: [StreamKind: [String]] = [:]
        for i in 0..<150_000 {
            byKind[kinds[i % kinds.count], default: []].append(base[i % base.count] + (i % 3 == 0 ? "" : " \(i % 97)"))
        }
        _ = NameParser.parse("warm up", kind: .movie)

        let sample = Array(byKind[.movie, default: []].prefix(10_000)) + Array(byKind[.live, default: []].prefix(10_000))
            + Array(byKind[.series, default: []].prefix(10_000))
        var start = Date()
        var checksum = 0
        for (i, name) in sample.enumerated() { checksum &+= NameParser.parse(name, kind: i < 10_000 ? .movie : (i < 20_000 ? .live : .series)).key.utf8.count }
        let single = Date().timeIntervalSince(start) / Double(sample.count)

        start = Date()
        var total = 0
        for kind in [StreamKind.movie, .series, .live] {
            let parsed = NameParser.parseAll(byKind[kind, default: []], kind: kind)
            total += parsed.count
            checksum &+= parsed.last?.key.utf8.count ?? 0
        }
        let batch = Date().timeIntervalSince(start)
        print(String(format: "NameParser: 150000 names in %.3f s with parseAll (%d cores); single thread %.2f µs/name "
                     + "(~%.2f s for 150k); checksum %d", batch, ProcessInfo.processInfo.activeProcessorCount,
                     single * 1_000_000, single * 150_000, checksum))
        XCTAssertEqual(total, 150_000)
        XCTAssertLessThan(batch, 2.0)
        XCTAssertLessThan(single, 100e-6)
    }

    func testParseAllMatchesSequentialParse() {
        let names = (0..<5_000).map { "EN| Movie \($0 % 700) (\(1950 + $0 % 70)) \($0 % 2 == 0 ? "4K" : "1080p")" }
        let batch = NameParser.parseAll(names, kind: .movie)
        XCTAssertEqual(batch, names.map { NameParser.parse($0, kind: .movie) })
    }

    func testCuratesLargeCatalog() {
        var items: [RawItem] = []
        for i in 0..<30_000 {
            let kind: StreamKind = i % 3 == 0 ? .live : (i % 3 == 1 ? .movie : .series)
            let name = kind == .live ? "UK: Channel \(i % 2000) HD" : "EN| Title \(i % 5000) (\(1990 + i % 30)) 4K"
            items.append(RawItem(ref: StreamRef(providerID: "p", kind: kind, streamID: "\(i)"), name: name,
                                 categoryName: "EN | CATEGORY \(i % 40)"))
        }
        let start = Date()
        let out = Curator(preferences: ContentPreferences()).curate([ProviderCatalog(providerID: "p", items: items)])
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "Curator: 30000 items in %.3f s -> %d movies, %d series, %d channels", elapsed,
                     out.movies.count, out.series.count, out.channels.count))
        XCTAssertLessThan(elapsed, 5.0)
    }
}
