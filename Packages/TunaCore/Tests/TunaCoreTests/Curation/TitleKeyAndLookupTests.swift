import XCTest
@testable import TunaCore

final class TitleKeyTests: XCTestCase {
    func testContractCases() {
        let cases: [(String, String)] = [
            ("The Lord of the Rings: The Two Towers", "lord of the rings the two towers"),
            ("The Matrix", "matrix"),
            ("Matrix, The", "matrix"),
            ("Fast & Furious", "fast and furious"),
            ("Kurtlar Vadisi İstanbul Işık", "kurtlar vadisi istanbul isik"),
            ("Ölümlü Dünya", "olumlu dunya"),
            ("Amélie", "amelie"),
            ("Schindler's List", "schindlers list"),
            ("Schindler’s List", "schindlers list"),
            ("Rocky II", "rocky 2"),
            ("Rocky III", "rocky 3"),
            ("Rocky IV", "rocky 4"),
            ("Rocky V", "rocky 5"),
            ("Star Wars: Episode IX", "star wars episode 9"),
            ("Fast X", "fast 10"),
            ("X-Men", "x men"),
            ("Der Untergang", "untergang"),
            ("Die Hard", "hard"),
            ("Das Boot", "boot"),
            ("Le Fabuleux Destin d'Amélie Poulain", "fabuleux destin damelie poulain"),
            ("L'Odyssée", "odyssee"),
            ("La Casa de Papel", "casa de papel"),
            ("Les Misérables", "miserables"),
            ("El Laberinto del Fauno", "laberinto del fauno"),
            ("Los Olvidados", "olvidados"),
            ("Il Postino", "postino"),
            ("A Quiet Place", "quiet place"),
            ("An Education", "education"),
            ("The", "the"),
            ("Dune: Part Two", "dune part 2"),
            ("Kill Bill: Vol. 1", "kill bill vol 1"),
            ("Disney+ Originals", "disney plus originals"),
            ("Tom + Jerry", "tom and jerry"),
            ("  Spider-Man:   No Way   Home  ", "spider man no way home"),
            ("Straße", "strasse"),
            ("Ærø", "aero"),
            ("الفيل الأزرق", "الفيل الازرق"),
            ("Брат 2", "брат 2"),
            ("", ""),
        ]
        for (input, expected) in cases { XCTAssertEqual(TitleKey.make(input), expected, input) }
    }

    func testDuplicatesShareKey() {
        let a = NameParser.parse("EN| The Matrix (1999) 4K", kind: .movie)
        let b = NameParser.parse("The Matrix 1999 FHD", kind: .movie)
        let c = NameParser.parse("|TR| The Matrix (1999) Türkçe Dublaj", kind: .movie)
        XCTAssertEqual(a.key, "matrix")
        XCTAssertEqual(b.key, a.key)
        XCTAssertEqual(c.key, a.key)
    }

    func testLiveKeysKeepArticles() {
        XCTAssertEqual(TitleKey.make("La 1", kind: .live), "la 1")
        XCTAssertEqual(TitleKey.make("Das Erste", kind: .live), "das erste")
        XCTAssertEqual(TitleKey.make("Das Erste", kind: .movie), "erste")
    }
}

final class ScriptDetectorTests: XCTestCase {
    func testScripts() {
        let cases: [(String, String?)] = [
            ("الجزيرة", "ar"), ("Первый канал", "ru"), ("Ελληνική Τηλεόραση", "el"), ("עברית", "he"),
            ("기생충", "ko"), ("ドラゴンボール", "ja"), ("万引き家族", "ja"), ("中国中央电视台", "zh"),
            ("हिन्दी फ़िल्म", "hi"), ("ไทยรัฐ", "th"), ("Hello World", nil), ("1234", nil), ("", nil),
            ("Україна", "uk"), ("فارسی پژواک", "fa"), ("Muhteşem Yüzyıl", "tr"), ("Amélie", nil),
            ("MBC الجزيرة الاخبارية", "ar"),
        ]
        for (text, expected) in cases { XCTAssertEqual(ScriptDetector.languageHint(for: text), expected, text) }
    }
}

final class WorldDirectoryTests: XCTestCase {
    func testCountries() {
        let countries = WorldDirectory.countries
        XCTAssertGreaterThanOrEqual(countries.count, 110)
        XCTAssertEqual(countries.map { $0.name.tunaFolded }, countries.map { $0.name.tunaFolded }.sorted())
        XCTAssertEqual(Set(countries.map(\.code)).count, countries.count)
        for c in countries {
            XCTAssertEqual(c.code.count, 2, c.name)
            XCTAssertFalse(c.flag.isEmpty, c.name)
            XCTAssertFalse(c.languages.isEmpty, c.name)
            XCTAssertFalse(c.nativeName.isEmpty, c.name)
        }
        XCTAssertEqual(WorldDirectory.country("TR")?.nativeName, "Türkiye")
        XCTAssertEqual(WorldDirectory.country("tr")?.languages, ["tr"])
        XCTAssertEqual(WorldDirectory.country("UK")?.code, "GB")
        XCTAssertEqual(WorldDirectory.country("AR")?.languages.first, "es")
        XCTAssertNil(WorldDirectory.country("ZZ"))
    }

    func testLanguages() {
        let languages = WorldDirectory.languages
        XCTAssertGreaterThanOrEqual(languages.count, 55)
        XCTAssertEqual(languages.map { $0.name.tunaFolded }, languages.map { $0.name.tunaFolded }.sorted())
        XCTAssertEqual(WorldDirectory.language("en")?.flagCountry, "GB")
        XCTAssertEqual(WorldDirectory.language("TR")?.nativeName, "Türkçe")
        XCTAssertEqual(WorldDirectory.language("ar")?.flag, "🇸🇦")
        for l in languages { XCTAssertFalse(l.flag.isEmpty, l.name) }
    }

    func testRegionsAndFeatured() {
        XCTAssertEqual(WorldDirectory.regionName("LATAM"), "Latin America")
        XCTAssertEqual(WorldDirectory.regionName("EXYU"), "Ex-Yugoslavia")
        XCTAssertEqual(WorldDirectory.regionName("ARAB"), "Arab World")
        XCTAssertEqual(WorldDirectory.regionName("NORDIC"), "Nordic")
        XCTAssertEqual(WorldDirectory.regionName("XYZ"), "XYZ")
        XCTAssertEqual(WorldDirectory.featured.map(\.nativeName),
                       ["English", "Türkiye", "Deutschland", "France", "España", "Italia", "Português (Brasil)", "العربية",
                        "Nederlands", "Polski", "हिन्दी"])
        XCTAssertEqual(WorldDirectory.featured[1].code, "TR")
        XCTAssertEqual(WorldDirectory.featured[1].languages, ["tr"])
    }
}

final class CategoryParserTests: XCTestCase {
    func testCategories() {
        let a = CategoryParser.parse("EN | MOVIES 4K", kind: .movie)
        XCTAssertEqual(a.cleanName, "Movies")
        XCTAssertEqual(a.languages, ["en"])
        XCTAssertEqual(a.quality, .uhd)

        let b = CategoryParser.parse("XXX | Adult", kind: .live)
        XCTAssertTrue(b.isAdult)
        XCTAssertEqual(b.channelCategory, "xxx")

        let c = CategoryParser.parse("TR | YERLİ FİLMLER", kind: .movie)
        XCTAssertEqual(c.cleanName, "Yerli Filmler")
        XCTAssertEqual(c.languages, ["tr"])

        let d = CategoryParser.parse("UK | SPORTS ᴴᴰ", kind: .live)
        XCTAssertEqual(d.cleanName, "Sports")
        XCTAssertEqual(d.countries, ["GB"])
        XCTAssertEqual(d.quality, .hd)
        XCTAssertEqual(d.channelCategory, "sports")

        let e = CategoryParser.parse("TURKISH MOVIES", kind: .movie)
        XCTAssertEqual(e.cleanName, "Movies")
        XCTAssertEqual(e.languages, ["tr"])

        let f = CategoryParser.parse("NETFLIX SERIES", kind: .series)
        XCTAssertEqual(f.platform, "Netflix")

        let g = CategoryParser.parse("|EN| ACTION MOVIES", kind: .movie)
        XCTAssertEqual(g.genre, "Action")
        XCTAssertEqual(g.cleanName, "Action Movies")

        XCTAssertEqual(CategoryParser.parse("Movies 2023", kind: .movie).cleanName, "Movies 2023")
        XCTAssertEqual(CategoryParser.parse("ARABIC | NEWS", kind: .live).channelCategory, "news")
        XCTAssertEqual(CategoryParser.parse("ARABIC | NEWS", kind: .live).languages, ["ar"])
        XCTAssertEqual(CategoryParser.parse("KIDS", kind: .live).channelCategory, "kids")
        XCTAssertEqual(CategoryParser.parse("EN | KIDS", kind: .movie).genre, "Kids")
        XCTAssertEqual(CategoryParser.parse("BELGESEL", kind: .live).channelCategory, "documentary")
        XCTAssertEqual(CategoryParser.parse("PPV EVENTS", kind: .live).channelCategory, "events")
        XCTAssertEqual(CategoryParser.parse("SCI-FI", kind: .movie).genre, "Science Fiction")
        XCTAssertEqual(CategoryParser.parse("FOR ADULTS", kind: .movie).isAdult, true)
        XCTAssertEqual(CategoryParser.parse("Adult Swim", kind: .live).isAdult, false)
        XCTAssertEqual(CategoryParser.parse("LATAM | DEPORTES", kind: .live).regions, ["LATAM"])
        XCTAssertEqual(CategoryParser.parse("VOD | ACTION", kind: .movie).cleanName, "Action")
        XCTAssertEqual(CategoryParser.parse("MOVIES | 4K", kind: .movie).cleanName, "Movies")
    }
}
