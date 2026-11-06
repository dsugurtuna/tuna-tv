import Foundation

enum DemoSeriesInfoBuilder {
    struct Shape: Sendable {
        let episodesPerSeason: [Int]
        let firstAirDay: Int
        var seasonCount: Int { episodesPerSeason.count }
        var episodeCount: Int { episodesPerSeason.reduce(0, +) }
        /// Day number of the first episode of `season` (1-based).
        func seasonStartDay(_ season: Int) -> Int { firstAirDay + (season - 1) * 364 }
        var lastAirDay: Int { seasonStartDay(seasonCount) + 7 * ((episodesPerSeason.last ?? 1) - 1) }
    }

    static func shape(_ spec: DemoTitleSpec) -> Shape {
        var rng = DemoRNG("shape/\(spec.seed)")
        let maxSeasons = max(2, min(5, 2027 - spec.year))
        let seasons = rng.int(2...maxSeasons)
        let counts = (0..<seasons).map { _ in rng.int(6...10) }
        let first = DemoCalendar.days(year: spec.year, month: rng.int(1...9), day: rng.int(1...28))
        return Shape(episodesPerSeason: counts, firstAirDay: first)
    }

    private static let adjectives = ["Long", "Quiet", "Broken", "Hidden", "Last", "Silver", "Burning", "Hollow", "Distant",
                                     "Crooked", "Bitter", "Gilded", "Restless", "Salt", "Northern", "Paper", "Iron", "Midnight"]
    private static let nouns = ["Tide", "Lantern", "Bridge", "Harvest", "Letter", "Crossing", "Storm", "Inheritance", "Signal",
                                "Orchard", "Ledger", "Lighthouse", "Reckoning", "Promise", "Winter", "Shore", "Witness",
                                "Door", "Map", "Bargain", "Season", "Echo", "Fire", "Homecoming"]
    private static let plots = [
        "%A finally confronts %B about the night everything changed, but the answer raises a bigger question.",
        "A stranger arrives with news that forces %A to choose between loyalty and the truth.",
        "%B makes a dangerous deal while %A follows a lead that points uncomfortably close to home.",
        "An old photograph resurfaces, and %A realises that %B has been lying from the start.",
        "As a storm cuts everyone off, %A and %B are forced to work together for the first time.",
        "%A discovers a hidden room, and with it a secret someone was willing to kill for.",
        "A celebration turns sour when %B makes a public accusation that nobody can take back.",
        "%A races against time to stop a decision that would tear the family apart.",
        "Old rivals become uneasy allies, and %B learns what %A sacrificed years ago.",
        "%A follows the money and finds a name nobody expected on the final page.",
        "A rescue goes wrong, leaving %B to pick up the pieces and %A with a terrible choice.",
        "Secrets spill out at a funeral, and %A finally sees who has been pulling the strings.",
    ]

    static func episodeTitle(_ spec: DemoTitleSpec, season: Int, episode: Int, isFinale: Bool) -> String {
        if spec.language == "tr" { return "\(episode). Bölüm" }
        if season == 1 && episode == 1 { return "Pilot" }
        var rng = DemoRNG("episode-title/\(spec.seed)/\(season)/\(episode)")
        let noun = rng.pick(nouns)
        let title: String
        switch rng.int(0...3) {
        case 0: title = "The \(noun)"
        case 1: title = "The \(rng.pick(adjectives)) \(noun)"
        case 2: title = "\(rng.pick(adjectives)) \(noun)"
        default: title = "A \(noun) for \(rng.pick(["Strangers", "the Dead", "Two", "Nobody", "the Living", "Sunday"]))"
        }
        return isFinale ? "\(title): Finale" : title
    }

    static func plot(_ spec: DemoTitleSpec, season: Int, episode: Int) -> String {
        var rng = DemoRNG("plot/\(spec.seed)/\(season)/\(episode)")
        let cast = DemoPeople.credits(for: spec).cast
        func character(_ i: Int) -> String {
            guard cast.indices.contains(i) else { return "the family" }
            return cast[i].character.replacingOccurrences(of: " (voice)", with: "")
        }
        let a = character(rng.int(0...min(2, cast.count - 1)))
        var b = character(rng.int(1...min(5, max(1, cast.count - 1))))
        if b == a { b = character(min(cast.count - 1, 3)) }
        return rng.pick(plots).replacingOccurrences(of: "%A", with: a).replacingOccurrences(of: "%B", with: b)
    }

    static func episodeStreamID(record: String, season: Int, episode: Int) -> String {
        String((Int(record) ?? 0) * 1_000 + season * 100 + episode)
    }

    static func info(for ref: StreamRef) -> RawSeriesInfo? {
        guard ref.providerID == DemoContent.providerID, ref.kind == .series,
              let spec = DemoCatalogBuilder.spec(forStreamID: ref.streamID), spec.kind == .series else { return nil }
        let shape = shape(spec)
        let stats = DemoStats.of(spec)
        let credits = DemoPeople.credits(for: spec)
        var seasons: [RawSeason] = []
        var episodes: [RawEpisode] = []
        for season in 1...shape.seasonCount {
            let count = shape.episodesPerSeason[season - 1]
            let start = shape.seasonStartDay(season)
            seasons.append(RawSeason(number: season, name: spec.language == "tr" ? "\(season). Sezon" : "Season \(season)",
                                     overview: season == 1 ? spec.overview : nil, airDate: DemoCalendar.string(days: start),
                                     coverURL: "demo://poster/\(spec.seed)-s\(season)", episodeCount: count))
            for episode in 1...count {
                var rng = DemoRNG("episode/\(spec.seed)/\(season)/\(episode)")
                let minutes = max(18, spec.runtime + rng.int(-4...4))
                episodes.append(RawEpisode(
                    ref: StreamRef(providerID: DemoContent.providerID, kind: .episode,
                                   streamID: episodeStreamID(record: ref.streamID, season: season, episode: episode)),
                    season: season, episode: episode,
                    title: episodeTitle(spec, season: season, episode: episode, isFinale: episode == count),
                    containerExtension: "mkv", plot: plot(spec, season: season, episode: episode),
                    durationSeconds: minutes * 60 + rng.int(0...59), airDate: DemoCalendar.string(days: start + 7 * (episode - 1)),
                    stillURL: "demo://still/\(spec.seed)-s\(season)e\(episode)",
                    rating: (min(9.8, max(5, stats.voteAverage + rng.double(-0.7, 0.8))) * 10).rounded() / 10,
                    tech: StreamTechInfo(videoCodec: "hevc", width: 1920, height: 1080, audioCodec: "eac3", audioChannels: 6)))
            }
        }
        let info = RawItemInfo(
            tmdbID: spec.tmdbID, name: spec.title, originalName: spec.title, plot: spec.overview,
            cast: credits.cast.prefix(6).map { DemoPeople.all[$0.personIndex].name }.joined(separator: ", "),
            director: DemoPeople.all[credits.director].name, genre: spec.genres.joined(separator: " / "),
            country: spec.countries.first, releaseDate: DemoCalendar.string(days: shape.firstAirDay),
            rating: stats.voteAverage, durationSeconds: spec.runtime * 60, posterURL: "demo://poster/\(spec.seed)",
            backdropURLs: ["demo://backdrop/\(spec.seed)", "demo://backdrop/\(spec.seed)-2"])
        return RawSeriesInfo(seriesRef: ref, info: info, seasons: seasons, episodes: episodes, fetchedAt: DemoClock.reference)
    }
}
