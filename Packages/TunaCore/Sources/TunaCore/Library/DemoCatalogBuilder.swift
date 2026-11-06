import Foundation

/// Ratings shared by the catalog (provider rating) and the metadata (TMDB-style votes).
struct DemoStats: Sendable {
    let voteAverage: Double
    let voteCount: Int
    let popularity: Double
    let isHiddenGem: Bool

    static func of(_ spec: DemoTitleSpec) -> DemoStats {
        var rng = DemoRNG("stats/\(DemoPeople.key(spec))")
        let gem = rng.chance(0.09)
        let average: Double
        let votes: Int
        if gem {
            average = rng.double(7.8, 8.9)
            votes = rng.int(300...1_400)
        } else {
            average = rng.double(5.8, 8.6)
            // Log-uniform 600...40,000, a bit larger for well-rated titles.
            let exponent = rng.double(log(600), log(40_000)) + (average - 7) * 0.25
            votes = min(40_000, max(300, Int(exp(exponent))))
        }
        let recency = max(0, Double(spec.year - 1985)) / 41
        let popularity = (log(Double(votes)) * 6 + recency * 40 + rng.double(0, 25)) * (spec.year >= 2025 ? 1.6 : 1)
        return DemoStats(voteAverage: (average * 10).rounded() / 10, voteCount: votes,
                         popularity: (popularity * 1000).rounded() / 1000, isHiddenGem: gem)
    }
}

enum DemoCatalogBuilder {
    static let movieCategories: [(id: String, name: String)] = [
        ("101", "EN | MOVIES 4K UHD"), ("102", "EN | MOVIES"), ("103", "EN | NEW RELEASES"), ("104", "EN | KIDS & FAMILY"),
        ("105", "EN | DOCUMENTARIES"), ("106", "EN | HORROR"), ("107", "EN | CLASSICS"), ("108", "VOD | BLURAY 1080P"),
        ("109", "VOD | 4K REMUX"), ("110", "EN | CINEMA CAM"), ("111", "TR | YABANCI FİLMLER (DUBLAJ)"),
        ("112", "TR | YERLİ FİLMLER"), ("113", "TR | YERLİ FİLMLER 4K"), ("114", "DE | FILME"), ("115", "FR | FILMS"),
        ("116", "ES | PELÍCULAS"), ("117", "AR | أفلام عربية"), ("118", "EN | WORLD CINEMA"), ("119", "EN | WEB-DL"),
        ("199", "XXX | Adult"),
    ]

    static let seriesCategories: [(id: String, name: String)] = [
        ("201", "EN | SERIES"), ("202", "EN | SERIES 4K UHD"), ("203", "TR | YABANCI DİZİLER"), ("204", "TR | YERLİ DİZİLER"),
        ("205", "DE | SERIEN"), ("206", "AR | مسلسلات"), ("207", "EN | KIDS SERIES"), ("208", "EN | DOCUSERIES"),
        ("209", "FR | SÉRIES"), ("210", "ES | SERIES"),
    ]

    static func categories() -> [RawCategory] {
        movieCategories.map { RawCategory(id: $0.id, name: $0.name, kind: .movie) }
            + seriesCategories.map { RawCategory(id: $0.id, name: $0.name, kind: .series) }
            + DemoTables.liveCategories.map { RawCategory(id: $0.id, name: $0.name, kind: .live) }
    }

    private static let categoryNames: [String: String] = {
        var map: [String: String] = [:]
        for c in movieCategories + seriesCategories + DemoTables.liveCategories { map[c.id] = c.name }
        return map
    }()

    // MARK: Stream ids (stable: derived from table positions)

    static func movieStreamID(_ index: Int, variant: Int) -> String { String(100_000 + index * 10 + variant) }
    static func seriesStreamID(_ index: Int, record: Int) -> String { String(200_000 + index * 10 + record) }
    static func liveStreamID(_ index: Int, variant: Int) -> String { String(300_000 + index * 10 + variant) }

    /// Maps a demo stream id back to its title spec.
    static func spec(forStreamID streamID: String) -> DemoTitleSpec? {
        guard let number = Int(streamID) else { return nil }
        switch number {
        case 100_000..<200_000:
            let i = (number - 100_000) / 10
            return DemoSpecs.movies.indices.contains(i) ? DemoSpecs.movies[i] : nil
        case 200_000..<300_000:
            let i = (number - 200_000) / 10
            return DemoSpecs.series.indices.contains(i) ? DemoSpecs.series[i] : nil
        default:
            return nil
        }
    }

    // MARK: Catalog

    static func catalog(now: Date) -> ProviderCatalog {
        var items: [RawItem] = []
        for spec in DemoSpecs.movies { items += movieItems(spec, now: now) }
        items += adultItems(now: now)
        for spec in DemoSpecs.series { items += seriesItems(spec, now: now) }
        items += DemoLiveBuilder.items()
        let fetched = now.addingTimeInterval(-1_800)
        return ProviderCatalog(providerID: DemoContent.providerID, account: DemoContent.account(now: now),
                               categories: categories(), items: items,
                               fetchedAt: ["live": fetched, "movie": fetched, "series": fetched, "account": now],
                               guideURL: "demo://tuna/xmltv.php")
    }

    private static func prefix(_ language: String, rng: inout DemoRNG) -> String {
        switch language {
        case "tr": return rng.pick(["|TR| ", "TR: ", "TR| "])
        case "de": return rng.pick(["DE| ", "DE: "])
        case "fr": return rng.pick(["FR| ", "FR: "])
        case "es": return rng.pick(["ES| ", "ES: "])
        case "ar": return "AR| "
        default: return rng.pick(["EN| ", "EN - ", "EN: ", "EN| "])
        }
    }

    private static func languageCategory(_ language: String, uhd: Bool) -> String {
        switch language {
        case "tr": return uhd ? "113" : "112"
        case "de": return "114"
        case "fr": return "115"
        case "es": return "116"
        case "ar": return "117"
        default: return uhd ? "101" : "102"
        }
    }

    private static func englishCategory(_ spec: DemoTitleSpec) -> String {
        if spec.genres.contains("Animation") || spec.genres.first == "Family" { return "104" }
        if spec.genres.contains("Documentary") { return "105" }
        if spec.genres.first == "Horror" { return "106" }
        if spec.year >= 2025 { return "103" }
        if spec.year < 1995 { return "107" }
        return "102"
    }

    private static func dotted(_ title: String) -> String {
        DemoText.slug(title).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ".")
    }

    /// Provider-style name + category + container for one variant code.
    static func movieVariant(_ spec: DemoTitleSpec, code: Character, rng: inout DemoRNG) -> (name: String, category: String, ext: String) {
        let t = spec.title
        let y = spec.year
        let lang = spec.listingLanguage
        let p = prefix(lang, rng: &rng)
        switch code {
        case "U":
            let name = rng.pick(["\(p)\(t) (\(y)) 4K HDR", "\(p)\(t) (\(y)) 2160p UHD HDR10", "\(p)\(t) (\(y)) 4K Dolby Vision",
                                 "\(p)\(t) [\(y)] [4K HEVC HDR10+]", "\(p)\(t) (\(y)) UHD", "\(p)\(t) (\(y)) 4K"])
            return (name, languageCategory(lang, uhd: true), "mkv")
        case "F":
            let name = rng.pick(["\(p)\(t) (\(y)) FHD", "\(p)\(t) (\(y)) 1080p", "\(p)\(t) [\(y)] [1080p WEB-DL]", "\(p)\(t) (\(y)) FHD"])
            return (name, lang == "en" ? englishCategory(spec) : languageCategory(lang, uhd: false), "mp4")
        case "H":
            let name = rng.pick(["\(p)\(t) (\(y)) HD", "\(p)\(t) (\(y)) 720p", "\(p)\(t) (\(y)) SD", "\(t) (\(y)) DVDRip"])
            return (name, lang == "en" ? (y < 2000 ? "107" : "102") : languageCategory(lang, uhd: false),
                    name.hasSuffix("DVDRip") || name.hasSuffix("SD") ? "avi" : "mp4")
        case "B":
            let name = rng.pick(["\(t) \(y) BluRay 1080p", "\(t) (\(y)) BluRay REMUX 1080p", "\(dotted(t)).\(y).1080p.BluRay.x264"])
            return (name, "108", "mkv")
        case "R":
            return (rng.pick(["\(t) (\(y)) 2160p REMUX HDR", "\(t) (\(y)) UHD BluRay REMUX DV"]), "109", "mkv")
        case "C":
            let name = rng.pick(["\(t.uppercased()) (\(y)) HDCAM", "\(t) (\(y)) CAM", "\(p)\(t) (\(y)) [TS]", "\(t) (\(y)) HDTS"])
            return (name, "110", "mp4")
        case "W":
            return (rng.pick(["\(t) (\(y)) WEB-DL 720p", "\(t) \(y) 1080p WEBRip x265"]), "119", "mp4")
        case "T":
            return (rng.pick(["|TR| \(t) (\(y)) [Türkçe Dublaj] 1080p", "TR: \(t) (\(y)) [Türkçe Altyazılı] FHD",
                              "|TR| \(t) (\(y)) Türkçe Dublaj FHD"]), "111", "mp4")
        case "D":
            return (rng.pick(["DE| \(t) (\(y)) FHD", "DE: \(t) (\(y)) [Deutsch] 1080p"]), "114", "mp4")
        case "V":
            return (rng.pick(["FR| \(t) (\(y)) VF 1080p", "FR: \(t) (\(y)) [VOSTFR] HD"]), "115", "mp4")
        case "S":
            return (rng.pick(["ES| \(t) (\(y)) [Latino] 1080p", "ES| \(t) (\(y)) Castellano FHD"]), "116", "mp4")
        default: // "E"
            return (rng.pick(["EN| \(t) (\(y)) [Multi-Sub] FHD", "EN| \(t) (\(y)) [English Subs] 1080p"]), "118", "mp4")
        }
    }

    private static func addedAt(now: Date, spec: DemoTitleSpec, rng: inout DemoRNG) -> Date {
        let maxDays = spec.year >= 2025 ? 45 : 119
        let seconds = rng.int(0...(maxDays * 86_400 + 80_000))
        return now.addingTimeInterval(-TimeInterval(3_600 + seconds))
    }

    private static func providerRating(_ spec: DemoTitleSpec, rng: inout DemoRNG) -> Double? {
        guard rng.chance(0.85) else { return nil }
        let value = DemoStats.of(spec).voteAverage + rng.double(-0.6, 0.4)
        return (min(10, max(1, value)) * 10).rounded() / 10
    }

    static func movieItems(_ spec: DemoTitleSpec, now: Date) -> [RawItem] {
        var rng = DemoRNG("movie-items/\(spec.seed)")
        return spec.codes.enumerated().map { offset, code in
            let v = movieVariant(spec, code: code, rng: &rng)
            return RawItem(
                ref: StreamRef(providerID: DemoContent.providerID, kind: .movie, streamID: movieStreamID(spec.index, variant: offset)),
                name: v.name, categoryID: v.category, categoryName: categoryNames[v.category],
                iconURL: "demo://poster/\(spec.seed)", addedAt: addedAt(now: now, spec: spec, rng: &rng),
                providerRating: providerRating(spec, rng: &rng), tmdbID: rng.chance(0.93) ? spec.tmdbID : nil,
                year: code == "B" || code == "W" || rng.chance(0.3) ? nil : spec.year, containerExtension: v.ext,
                genre: rng.chance(0.5) ? spec.genres.joined(separator: ", ") : nil)
        }
    }

    private static func adultItems(now: Date) -> [RawItem] {
        (1...3).map { n in
            let seed = "adult-placeholder-0\(n)"
            return RawItem(ref: StreamRef(providerID: DemoContent.providerID, kind: .movie, streamID: String(190_000 + n)),
                           name: "Adult Placeholder 0\(n)", categoryID: "199", categoryName: "XXX | Adult",
                           iconURL: "demo://poster/\(seed)", addedAt: now.addingTimeInterval(-TimeInterval(n * 9 * 86_400)),
                           containerExtension: "mp4")
        }
    }

    static func seriesRecordName(_ spec: DemoTitleSpec, code: Character, rng: inout DemoRNG) -> (name: String, category: String) {
        let t = spec.title
        let y = spec.year
        let lang = spec.listingLanguage
        let p = prefix(lang, rng: &rng)
        let base: String
        switch lang {
        case "tr": base = "204"
        case "de": base = "205"
        case "ar": base = "206"
        case "fr": base = "209"
        case "es": base = "210"
        default:
            if spec.genres.contains("Kids") || spec.genres.contains("Animation") { base = "207" }
            else if spec.genres.contains("Documentary") { base = "208" } else { base = "201" }
        }
        switch code {
        case "U":
            return (rng.pick(["\(p)\(t) 4K", "\(p)\(t) (\(y)) [4K HDR]", "\(p)\(t) (\(y)) 4K"]), lang == "en" ? "202" : base)
        case "H": return (rng.pick(["\(p)\(t) (\(y)) HD", "\(p)\(t) HD"]), base)
        case "N": return (lang == "tr" ? "TR: \(t)" : "\(p)\(t) (\(y))", base)
        case "T": return (rng.pick(["|TR| \(t) [Türkçe Dublaj]", "|TR| \(t) (\(y)) [Türkçe Dublaj] 1080p"]), "203")
        case "E": return ("EN| \(t) (\(y)) [Multi-Sub] FHD", "201")
        case "D": return ("DE| \(t) (\(y)) [Deutsch] FHD", "205")
        default: return (rng.pick(["\(p)\(t) (\(y)) FHD", "\(p)\(t) [1080p]", "\(p)\(t) (\(y)) 1080p"]), base)
        }
    }

    static func seriesItems(_ spec: DemoTitleSpec, now: Date) -> [RawItem] {
        var rng = DemoRNG("series-items/\(spec.seed)")
        let credits = DemoPeople.credits(for: spec)
        let castLine = credits.cast.prefix(4).map { DemoPeople.all[$0.personIndex].name }.joined(separator: ", ")
        let shape = DemoSeriesInfoBuilder.shape(spec)
        return spec.codes.enumerated().map { offset, code in
            let record = seriesRecordName(spec, code: code, rng: &rng)
            return RawItem(
                ref: StreamRef(providerID: DemoContent.providerID, kind: .series, streamID: seriesStreamID(spec.index, record: offset)),
                name: record.name, categoryID: record.category, categoryName: categoryNames[record.category],
                iconURL: "demo://poster/\(spec.seed)", addedAt: addedAt(now: now, spec: spec, rng: &rng),
                providerRating: providerRating(spec, rng: &rng), tmdbID: spec.tmdbID, year: spec.year,
                plot: spec.overview, cast: castLine, director: DemoPeople.all[credits.director].name,
                genre: spec.genres.joined(separator: " / "), releaseDate: DemoCalendar.string(days: shape.firstAirDay),
                backdropURLs: ["demo://backdrop/\(spec.seed)"], episodeRunTimeMinutes: spec.runtime)
        }
    }
}
