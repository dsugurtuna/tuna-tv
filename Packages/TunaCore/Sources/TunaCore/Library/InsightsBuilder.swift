import Foundation

/// Builds `InsightsReport` (owner: Library). Breakdowns cover every non-adult title (showcase + Vault), biggest first
/// (decades chronologically); the Vault breakdown uses `Library.vaultCounts` (titles + channels).
enum InsightsBuilder {
    static func build(library: Library, metadata: [String: MediaMetadata], userState: UserState) -> InsightsReport {
        let all = library.movies + library.series
        let titles = all.filter { !$0.isAdult }
        let raw = library.stats.rawCounts
        let totalRaw = raw["total"] ?? raw.values.reduce(0, +)
        let showcase = all.filter { $0.isLibraryShowcase }.count

        var quality: [Quality: Int] = [:]
        var languages: [String: Int] = [:]
        var countries: [String: Int] = [:]
        var genres: [String: Int] = [:]
        var decades: [Int: Int] = [:]
        var covered = 0
        for title in titles {
            let md = metadata[title.id]
            if md != nil { covered += 1 }
            quality[title.bestQuality, default: 0] += 1
            if let language = (md?.originalLanguage ?? title.languages.first)?.nonEmpty { languages[language.lowercased(), default: 0] += 1 }
            let country = md?.originCountries.first ?? md?.productionCountries.first ?? title.countries.first
            if let country = country?.nonEmpty { countries[country.uppercased(), default: 0] += 1 }
            for genre in GenreNames.genres(of: title, metadata: md) { genres[genre, default: 0] += 1 }
            if let year = RankMath.year(title, metadata: md) { decades[year / 10 * 10, default: 0] += 1 }
        }

        func ranked<K: Comparable>(_ counts: [K: Int]) -> [(K, Int)] {
            counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        }
        let qualityOrder: [Quality] = [.uhd, .fhd, .hd, .sd, .unknown]
        let qualityBreakdown = qualityOrder.compactMap { tier -> (label: String, count: Int)? in
            guard let count = quality[tier], count > 0 else { return nil }
            return (tier == .unknown ? "Unknown" : tier.label, count)
        }
        let vault = VaultShelf.allCases.compactMap { shelf -> (shelf: VaultShelf, count: Int)? in
            guard let count = library.vaultCounts[shelf], count > 0 else { return nil }
            return (shelf, count)
        }
        let historySeconds = userState.history.reduce(0) { $0 + max(0, $1.secondsWatched) }
        let progressSeconds = userState.progress.values.reduce(0) { $0 + max(0, $1.position) }

        return InsightsReport(
            totalRaw: totalRaw,
            totalTitles: all.count,
            duplicatesMerged: library.stats.duplicatesMerged,
            showcaseShare: all.isEmpty ? 0 : Double(showcase) / Double(all.count),
            qualityBreakdown: qualityBreakdown,
            languageBreakdown: ranked(languages).map { (code: $0.0, count: $0.1) },
            countryBreakdown: ranked(countries).map { (code: $0.0, count: $0.1) },
            genreBreakdown: ranked(genres).map { (name: $0.0, count: $0.1) },
            decadeBreakdown: decades.keys.sorted().map { (decade: $0, count: decades[$0] ?? 0) },
            vaultBreakdown: vault,
            metadataCoverage: titles.isEmpty ? 0 : Double(covered) / Double(titles.count),
            hoursWatched: (historySeconds > 0 ? historySeconds : progressSeconds) / 3600
        )
    }
}
