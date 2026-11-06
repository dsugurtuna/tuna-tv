import Foundation

// Rail rules: each returns the full ordered list (showcase only, never adult).
extension RailEngine {
    func continueWatching(_ kind: TitleKind?) -> [(title: Title, progress: WatchProgress)] {
        let items = context.userState.continueWatching.sorted { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            if a.titleID != b.titleID { return a.titleID < b.titleID }
            return (a.episodeRef?.id ?? "") < (b.episodeRef?.id ?? "")
        }
        var seen = Set<String>()
        var out: [(title: Title, progress: WatchProgress)] = []
        for progress in items {
            guard let title = library.title(progress.titleID), title.isLibraryShowcase,
                  kind == nil || title.kind == kind, seen.insert(title.id).inserted else { continue }
            out.append((title, progress))
        }
        return out
    }

    /// Favourite channels, then live events from the guide, then recent channels (showcase only, deduplicated).
    func liveNowItems() -> [RailItem] {
        var seen = Set<String>()
        var items: [RailItem] = []
        let guide = context.guide
        func current(_ channel: Channel) -> Program? {
            guard let guide else { return nil }
            for key in [channel.epgChannelID, channel.iptvOrgID] {
                if let key = key?.nonEmpty, let program = guide.now(key, at: context.now) { return program }
            }
            return nil
        }
        func add(_ channel: Channel, _ program: Program?) {
            guard channel.isLibraryShowcase, items.count < RailEngine.railMaximum, seen.insert(channel.id).inserted else { return }
            items.append(.live(channel, program))
        }
        for id in context.userState.favoriteChannels { if let channel = library.channel(id) { add(channel, current(channel)) } }
        if let guide {
            for event in guide.liveEvents(at: context.now, channels: library.liveShowcase) { add(event.channel, event.program) }
        }
        for id in context.userState.recentChannels { if let channel = library.channel(id) { add(channel, current(channel)) } }
        return items
    }

    func trending(_ kind: TitleKind?) -> [Title] {
        func list(_ ids: [Int], _ kind: TitleKind) -> [Title] {
            library.titles(tmdbIDs: ids, kind: kind, metadata: context.metadata).filter { $0.isLibraryShowcase }
        }
        switch kind {
        case .movie?: return list(context.trendingMovieIDs, .movie)
        case .series?: return list(context.trendingSeriesIDs, .series)
        case nil:
            let movieList = list(context.trendingMovieIDs, .movie), seriesList = list(context.trendingSeriesIDs, .series)
            var out: [Title] = []
            for index in 0..<max(movieList.count, seriesList.count) {
                if index < movieList.count { out.append(movieList[index]) }
                if index < seriesList.count { out.append(seriesList[index]) }
            }
            return out
        }
    }

    func newArrivals(_ kind: TitleKind?) -> [Title] {
        pool(kind).filter { $0.title.addedAt != nil }.sorted { a, b in
            let x = a.title.addedAt ?? .distantPast, y = b.title.addedAt ?? .distantPast
            return x != y ? x > y : RailEngine.byScore(a, b)
        }.map(\.title)
    }

    func ultraHD(_ kind: TitleKind?) -> [Title] {
        pool(kind).filter { $0.title.bestQuality == .uhd || $0.title.hdr != nil }.map(\.title)
    }

    func acclaimed(_ kind: TitleKind?) -> [Title] {
        byRating(pool(kind).filter { ($0.rating ?? 0) >= 7.8 && $0.votes >= 1000 })
    }

    func hiddenGems(_ kind: TitleKind?) -> [Title] {
        byRating(pool(kind).filter { ($0.rating ?? 0) >= 7.2 && $0.votes >= 50 && $0.votes <= 2000 })
    }

    private func byRating(_ entries: [Entry]) -> [Title] {
        entries.sorted { a, b in
            let x = a.rating ?? 0, y = b.rating ?? 0
            return x != y ? x > y : RailEngine.byScore(a, b)
        }.map(\.title)
    }

    /// Most recently watched distinct titles (history + progress), newest first.
    func recentSeeds(_ kind: TitleKind?) -> [Title] {
        var events: [(id: String, at: Date)] = []
        for entry in context.userState.history where entry.kind == .title { events.append((entry.itemID, entry.watchedAt)) }
        for progress in context.userState.progress.values { events.append((progress.titleID, progress.updatedAt)) }
        events.sort { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        var seen = Set<String>()
        var seeds: [Title] = []
        for event in events where seen.insert(event.id).inserted {
            guard let title = library.title(event.id), !title.isAdult, kind == nil || title.kind == kind else { continue }
            seeds.append(title)
            if seeds.count == 8 { break }
        }
        return seeds
    }

    /// TMDB recommendations + similar ∩ catalog (in TMDB order), then titles sharing the most genres.
    func becauseList(_ seed: Title) -> [Title] {
        var out: [Title] = []
        var seen: Set<String> = [seed.id]
        if let md = metadata(seed) {
            for title in library.titles(tmdbIDs: md.recommendationIDs + md.similarIDs, kind: seed.kind, metadata: context.metadata)
            where title.isLibraryShowcase && seen.insert(title.id).inserted {
                out.append(title)
            }
        }
        let seedGenres = Set(genres(seed))
        guard !seedGenres.isEmpty else { return out }
        var overlaps: [(entry: Entry, overlap: Int)] = []
        for entry in pool(seed.kind) where !seen.contains(entry.title.id) {
            let overlap = genres(entry.title).filter { seedGenres.contains($0) }.count
            if overlap > 0 { overlaps.append((entry, overlap)) }
        }
        overlaps.sort { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : RailEngine.byScore($0.entry, $1.entry) }
        return out + overlaps.map(\.entry.title)
    }

    // MARK: Worlds

    func makeWorlds() -> [World] {
        let selection = context.preferences.worlds
        var out: [World] = []
        var covered = Set<String>()
        for country in selection.countries where !WorldNames.englishCountries.contains(country) {
            let language = WorldNames.primaryLanguage(ofCountry: country)
            if language == "en" { continue }
            out.append(World(key: country, country: country, language: language,
                             title: "From \(WorldNames.countryName(country) ?? country)"))
            if let language { covered.insert(language) }
        }
        for language in selection.languages where language != "en" && !covered.contains(language) {
            covered.insert(language)
            out.append(World(key: "lang:\(language)", country: nil, language: language,
                             title: "In \(WorldNames.languageName(language) ?? language.uppercased())"))
        }
        return out
    }

    func world(forKey key: String) -> World? {
        if let known = worlds.first(where: { $0.key == key }) { return known }
        if key.hasPrefix("lang:") {
            let language = String(key.dropFirst(5)).lowercased()
            guard !language.isEmpty else { return nil }
            return World(key: key, country: nil, language: language, title: "In \(WorldNames.languageName(language) ?? language)")
        }
        guard key.count == 2 || key.count == 3 else { return nil }
        if key == key.uppercased() {
            return World(key: key, country: key, language: WorldNames.primaryLanguage(ofCountry: key),
                         title: "From \(WorldNames.countryName(key) ?? key)")
        }
        let language = key.lowercased()
        return World(key: "lang:\(language)", country: nil, language: language, title: "In \(WorldNames.languageName(language) ?? language)")
    }

    /// Metadata origin (countries, original language) when known, else the provider's country/language tags.
    func matchesWorld(_ title: Title, _ world: World) -> Bool {
        if let md = metadata(title), !(md.originCountries.isEmpty && md.productionCountries.isEmpty && md.originalLanguage == nil) {
            if let country = world.country {
                let origins = md.originCountries.isEmpty ? md.productionCountries : md.originCountries
                if origins.contains(where: { $0.uppercased() == country }) { return true }
            }
            if let language = world.language, md.originalLanguage?.lowercased() == language { return true }
            return false
        }
        if let country = world.country {
            if title.countries.contains(where: { $0.uppercased() == country }) { return true }
            if title.variants.contains(where: { $0.parsed.countries.contains { $0.uppercased() == country } }) { return true }
        }
        if let language = world.language, title.languages.contains(where: { $0.lowercased() == language }) { return true }
        return false
    }

    func worldList(_ world: World, _ kind: TitleKind?) -> [Title] {
        pool(kind).filter { matchesWorld($0.title, world) }.map(\.title)
    }

    // MARK: Genres, decades, collections

    func topGenres(_ kind: TitleKind?) -> [(genre: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in pool(kind) { for genre in genres(entry.title) { counts[genre, default: 0] += 1 } }
        return counts.map { (genre: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.genre < $1.genre }
    }

    /// Titles carrying every canonical piece of `genre` ("Action & Adventure" needs both).
    func hasGenre(_ title: Title, _ genre: String) -> Bool {
        let wanted = GenreNames.expand(genre).map(genreKey)
        guard !wanted.isEmpty else { return false }
        let have = Set(genres(title).map(genreKey))
        return wanted.allSatisfy { have.contains($0) }
    }

    func genreList(_ genre: String, _ kind: TitleKind?) -> [Title] {
        pool(kind).filter { hasGenre($0.title, genre) }.map(\.title)
    }

    func decadeList(_ decade: Int, _ kind: TitleKind?) -> [Title] {
        pool(kind).filter { entry in
            guard let year = RankMath.year(entry.title, metadata: metadata(entry.title)) else { return false }
            return year >= decade && year < decade + 10
        }.map(\.title)
    }

    /// Collections with at least two showcase members, best member score first; members by year.
    func collections(_ kind: TitleKind?) -> [(ref: CollectionRef, titles: [Title])] {
        var groups: [Int: (ref: CollectionRef, entries: [Entry])] = [:]
        for entry in pool(kind) {
            guard let ref = metadata(entry.title)?.collection else { continue }
            groups[ref.id, default: (ref, [])].entries.append(entry)
        }
        typealias Group = (ref: CollectionRef, best: Double, titles: [Title])
        var built: [Group] = []
        for group in groups.values where group.entries.count >= 2 {
            let best = group.entries.map(\.score).max() ?? 0
            built.append((ref: group.ref, best: best, titles: byYear(group.entries.map(\.title))))
        }
        built.sort { (a: Group, b: Group) -> Bool in a.best != b.best ? a.best > b.best : a.ref.id < b.ref.id }
        return built.map { (ref: $0.ref, titles: $0.titles) }
    }

    func collectionMembers(_ id: Int, _ kind: TitleKind?) -> [Title] {
        byYear(pool(kind).filter { metadata($0.title)?.collection?.id == id }.map(\.title))
    }

    private func byYear(_ titles: [Title]) -> [Title] {
        titles.sorted { a, b in
            let x = RankMath.year(a, metadata: metadata(a)) ?? Int.max, y = RankMath.year(b, metadata: metadata(b)) ?? Int.max
            return x != y ? x < y : a.id < b.id
        }
    }

    // MARK: Hero

    /// Up to 6 featured titles: metadata + backdrop first, by score boosted for trending and fresh additions;
    /// at least two of each kind (home), and one title from each non-English world when available.
    func heroTitles(_ kind: TitleKind?, excluding: Set<String>) -> [Title] {
        let candidates = pool(kind).filter { !excluding.contains($0.title.id) }
        guard !candidates.isEmpty else { return [] }
        func hasBackdrop(_ title: Title) -> Bool {
            let md = metadata(title)
            return md?.backdropURL != nil || md?.backdrops.isEmpty == false || title.backdropURL != nil
        }
        func featuredScore(_ entry: Entry) -> Double {
            var score = entry.score
            let md = metadata(entry.title)
            if let tmdb = md?.tmdbID ?? entry.title.providerTMDBID, let rank = trendingRanks[entry.title.kind]?[tmdb] {
                score += 0.08 * (1 - Double(rank) / 40)
            }
            if let added = entry.title.addedAt { score += 0.04 * RankMath.decay(context.now.timeIntervalSince(added), halfLife: RankMath.addedHalfLife) }
            return score
        }
        let tiers: [[Entry]] = [
            candidates.filter { metadata($0.title) != nil && hasBackdrop($0.title) },
            candidates.filter { metadata($0.title) == nil && hasBackdrop($0.title) },
            candidates.filter { !hasBackdrop($0.title) },
        ]
        var ordered: [Entry] = []
        for tier in tiers {
            let scored = tier.map { ($0, featuredScore($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.id < $1.0.title.id }
            ordered.append(contentsOf: scored.map(\.0))
            if ordered.count >= RailEngine.heroCount * 3 { break }
        }
        var picks = Array(ordered.prefix(RailEngine.heroCount))
        func picked(_ entry: Entry) -> Bool { picks.contains { $0.title.id == entry.title.id } }
        if kind == nil {
            for needed in [TitleKind.movie, .series] {
                var missing = 2 - picks.filter { $0.title.kind == needed }.count
                for extra in ordered where missing > 0 && extra.title.kind == needed && !picked(extra) {
                    let otherCount = picks.filter { $0.title.kind != needed }.count
                    guard otherCount > 2, let index = picks.lastIndex(where: { $0.title.kind != needed }) else { break }
                    picks[index] = extra
                    missing -= 1
                }
            }
        }
        var protected = Set<String>()
        for world in worlds.prefix(2) {
            if let existing = picks.first(where: { matchesWorld($0.title, world) }) { protected.insert(existing.title.id); continue }
            guard let extra = ordered.first(where: { matchesWorld($0.title, world) && !picked($0) }) else { continue }
            if picks.count < RailEngine.heroCount {
                picks.append(extra)
            } else if let index = picks.lastIndex(where: { candidate in
                !protected.contains(candidate.title.id) && picks.filter({ $0.title.kind == candidate.title.kind }).count > (kind == nil ? 2 : 0)
            }) {
                picks[index] = extra
            }
            protected.insert(extra.title.id)
        }
        let position = Dictionary(ordered.enumerated().map { ($1.title.id, $0) }, uniquingKeysWith: { a, _ in a })
        return picks.sorted { (position[$0.title.id] ?? 0) < (position[$1.title.id] ?? 0) }.map(\.title)
    }
}
