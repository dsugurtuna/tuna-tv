import Foundation

/// One invented movie or series, parsed from the string tables.
struct DemoTitleSpec: Sendable {
    let kind: TitleKind
    /// Position inside its kind's table (stable).
    let index: Int
    /// Catalog / original title.
    let title: String
    /// Display title in English (same as `title` for English originals).
    let englishTitle: String
    let year: Int
    let genres: [String]
    let language: String
    let countries: [String]
    let certification: String
    /// Movies: runtime. Series: episode runtime.
    let runtime: Int
    let codes: [Character]
    let status: String
    let tagline: String
    let overview: String
    let keywords: [String]
    let seed: String

    var tmdbID: Int { kind == .movie ? 900_001 + index : 900_501 + index }

    /// Language the provider lists it under (non-English originals keep their prefix).
    var listingLanguage: String {
        ["tr", "de", "fr", "es", "ar"].contains(language) && title != englishTitle ? language : "en"
    }

    var culture: String {
        switch language {
        case "tr": return "tr"
        case "de": return "de"
        case "fr": return "fr"
        case "es": return "es"
        case "ar": return "ar"
        case "ja": return "ja"
        case "ko": return "ko"
        case "zh": return "zh"
        case "hi": return "sasia"
        case "it": return "it"
        case "pt": return "pt"
        case "no", "da", "sv": return "nordic"
        default: return "anglo"
        }
    }

    var isAnimation: Bool { genres.contains("Animation") }
}

struct DemoChannelSpec: Sendable {
    let index: Int
    let name: String
    /// "UK", "US", "TR", "DE", "AR", "FR" or "" (untagged).
    let prefix: String
    let group: String
    let epgID: String
    let codes: [Character]
    let catchupDays: Int
    let categoryID: String
    let seed: String
    /// Fixed UTC offset used to build a believable local schedule.
    var utcOffsetHours: Int {
        switch prefix {
        case "US": return -5
        case "TR": return 3
        case "DE", "FR": return 1
        case "AR": return 4
        default: return 0
        }
    }
    var language: String {
        switch prefix {
        case "TR": return "tr"
        case "DE": return "de"
        case "AR": return "ar"
        case "FR": return "fr"
        default: return "en"
        }
    }
    var timeshiftEPGID: String {
        guard let dot = epgID.firstIndex(of: ".") else { return epgID + "Plus1" }
        return String(epgID[..<dot]) + "Plus1" + String(epgID[dot...])
    }
}

enum DemoSpecs {
    static let movies: [DemoTitleSpec] = parseTitles(DemoTables.moviesA + DemoTables.moviesB + DemoTables.moviesC, kind: .movie)
    static let series: [DemoTitleSpec] = parseTitles(DemoTables.series, kind: .series)
    static let all: [DemoTitleSpec] = movies + series
    static let channels: [DemoChannelSpec] = parseChannels(DemoTables.channels)

    static let byTMDBID: [Int: DemoTitleSpec] = {
        var map: [Int: DemoTitleSpec] = [:]
        for spec in all { map[spec.tmdbID] = spec }
        return map
    }()

    static let bySeed: [String: DemoTitleSpec] = {
        var map: [String: DemoTitleSpec] = [:]
        for spec in all { map["\(spec.kind.rawValue):\(spec.seed)"] = spec }
        return map
    }()

    /// Folded-name lookup used as the last resort when a curated title carries no id we know.
    static let byFoldedName: [String: DemoTitleSpec] = {
        var map: [String: DemoTitleSpec] = [:]
        for spec in all {
            for name in [spec.title, spec.englishTitle] {
                let key = "\(spec.kind.rawValue):\(DemoText.slug(name))"
                if map[key] == nil { map[key] = spec }
            }
        }
        return map
    }()

    private static func parseTitles(_ lines: [String], kind: TitleKind) -> [DemoTitleSpec] {
        let expected = kind == .movie ? 12 : 13
        var out: [DemoTitleSpec] = []
        for line in lines {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == expected, let year = Int(f[2]), let runtime = Int(f[7]) else { continue }
            let english = f[1].isEmpty ? f[0] : f[1]
            let latinSlug = DemoText.slug(f[0])
            let seed = DemoText.hasArabicScript(f[0]) || latinSlug.isEmpty ? DemoText.slug(english) : latinSlug
            let offset = kind == .movie ? 0 : 1
            let codes = Array(f[8].isEmpty ? "F" : f[8])
            out.append(DemoTitleSpec(
                kind: kind, index: out.count, title: f[0], englishTitle: english, year: year,
                genres: DemoText.list(f[3]), language: f[4], countries: DemoText.list(f[5]), certification: f[6],
                runtime: runtime, codes: codes, status: kind == .movie ? "Released" : f[9],
                tagline: f[9 + offset], overview: f[10 + offset], keywords: DemoText.list(f[11 + offset]), seed: seed))
        }
        return out
    }

    private static func parseChannels(_ lines: [String]) -> [DemoChannelSpec] {
        var out: [DemoChannelSpec] = []
        for line in lines {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7 else { continue }
            let slug = DemoText.slug(f[0])
            let seed = DemoText.hasArabicScript(f[0]) || slug.isEmpty
                ? DemoText.slug(String(f[3].split(separator: ".").first ?? "channel")) : slug
            out.append(DemoChannelSpec(index: out.count, name: f[0], prefix: f[1] == "-" ? "" : f[1], group: f[2],
                                       epgID: f[3], codes: Array(f[4]), catchupDays: Int(f[5]) ?? 0,
                                       categoryID: f[6], seed: seed))
        }
        return out
    }

    /// Collections: CollectionRef id -> member seeds (movies, release order).
    static let collections: [(id: Int, name: String, seeds: [String])] = [
        (870_001, "Glasswing Collection", ["glasswing", "glasswing-ascendant", "glasswing-requiem"]),
        (870_002, "Neon Harbor Collection", ["neon-harbor", "neon-harbor-undertow"]),
        (870_003, "Pip and the Paper Moon Collection", ["pip-and-the-paper-moon", "pip-and-the-paper-moon-2"]),
        (870_004, "The Ninth Precinct Collection", ["the-ninth-precinct", "the-ninth-precinct-ii"]),
        (870_005, "The Marlowe Collection", ["midnight-at-the-marlowe", "return-to-the-marlowe"]),
    ]

    static func collection(for seed: String) -> (id: Int, name: String, seeds: [String])? {
        collections.first { $0.seeds.contains(seed) }
    }
}
