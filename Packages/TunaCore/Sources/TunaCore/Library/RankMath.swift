import Foundation

/// The pieces of `Ranker.score` (owner: Library).
///
/// With metadata (vote average or popularity known):
///   0.55·(WR/10) + 0.20·popularity + 0.10·recency + 0.10·quality + 0.05·(providerRating/10)
/// Without: the provider rating, shrunk toward C as if it had 150 votes, stands in for WR and popularity scores 0:
///   0.55·(WR(provider)/10) + 0.10·recency + 0.10·quality + 0.05·(providerRating/10)
enum RankMath {
    static let defaultMean = 6.8
    static let releaseHalfLife: TimeInterval = 2 * 365.25 * 86_400
    static let addedHalfLife: TimeInterval = 30 * 86_400
    /// Assumed vote count for a provider rating or a metadata average without a vote count (TVMaze).
    static let assumedVotes = 150

    static func score(_ title: Title, metadata: MediaMetadata?, now: Date) -> Double {
        let quality = qualityBonus(title.bestQuality)
        let provider = clamp((title.providerRating ?? 0) / 10)
        let recent = recency(title, metadata: metadata, now: now)
        if let md = metadata, md.voteAverage != nil || md.popularity != nil {
            let wr = weightedRating(md, fallback: title.providerRating)
            return 0.55 * clamp(wr / 10) + 0.20 * popularity(md.popularity ?? 0) + 0.10 * recent + 0.10 * quality + 0.05 * provider
        }
        let rating = title.providerRating.map { Ranker.weightedRating(average: $0, votes: assumedVotes) } ?? defaultMean
        return 0.55 * clamp(rating / 10) + 0.10 * recent + 0.10 * quality + 0.05 * provider
    }

    /// Bayesian weighted rating from metadata (vote average + count), nil-safe.
    static func weightedRating(_ md: MediaMetadata, fallback: Double?) -> Double {
        let average = md.voteAverage ?? fallback ?? defaultMean
        let votes = md.voteCount ?? (md.voteAverage != nil ? assumedVotes : 0)
        return Ranker.weightedRating(average: average, votes: votes)
    }

    /// uhd 1, fhd 0.6, hd 0.3, else 0.
    static func qualityBonus(_ quality: Quality) -> Double {
        switch quality {
        case .uhd: return 1
        case .fhd: return 0.6
        case .hd: return 0.3
        case .sd, .unknown: return 0
        }
    }

    /// log10(1 + popularity) / log10(1001), clamped to 0...1 (TMDB popularity 1000 ≈ the very top).
    static func popularity(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        return clamp(log10(1 + value) / log10(1001))
    }

    /// 0.75·release recency (half-life 2 years) + 0.25·added recency (half-life 30 days).
    static func recency(_ title: Title, metadata: MediaMetadata?, now: Date) -> Double {
        let release = releaseDate(title, metadata: metadata).map { decay(now.timeIntervalSince($0), halfLife: releaseHalfLife) } ?? 0
        let added = title.addedAt.map { decay(now.timeIntervalSince($0), halfLife: addedHalfLife) } ?? 0
        return 0.75 * release + 0.25 * added
    }

    /// Release date: metadata date (series: last air date, then first air date), else the year (July 1st).
    static func releaseDate(_ title: Title, metadata: MediaMetadata?) -> Date? {
        if let md = metadata {
            let candidates = title.kind == .series ? [md.lastAirDate, md.firstAirDate, md.releaseDate] : [md.releaseDate, md.firstAirDate]
            for text in candidates { if let date = CivilDate.parse(text) { return date } }
            if let year = md.year { return CivilDate.date(year: year, month: 7, day: 1) }
        }
        return title.year.map { CivilDate.date(year: $0, month: 7, day: 1) }
    }

    /// Release year: metadata year, metadata dates, then the provider year.
    static func year(_ title: Title, metadata: MediaMetadata?) -> Int? {
        if let md = metadata {
            if let year = md.year { return year }
            if let year = CivilDate.year(md.releaseDate) ?? CivilDate.year(md.firstAirDate) { return year }
        }
        return title.year
    }

    static func decay(_ age: TimeInterval, halfLife: TimeInterval) -> Double {
        guard age > 0 else { return 1 }
        return pow(0.5, age / halfLife)
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
