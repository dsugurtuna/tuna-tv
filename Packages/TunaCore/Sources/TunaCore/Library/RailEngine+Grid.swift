import Foundation

// "More like this", person credits and the See-all / browse grid.
extension RailEngine {
    func similar(to title: Title, limit: Int) -> [Title] {
        guard limit > 0 else { return [] }
        var out: [Title] = []
        var seen: Set<String> = [title.id]
        let md = metadata(title)
        if let md {
            for other in library.titles(tmdbIDs: md.recommendationIDs + md.similarIDs, kind: title.kind, metadata: context.metadata)
            where other.isLibraryShowcase && seen.insert(other.id).inserted {
                out.append(other)
                if out.count == limit { return out }
            }
        }
        let seedGenres = Set(genres(title))
        let seedKeywords = Set((md?.keywords ?? []).map { $0.lowercased() })
        let seedCollection = md?.collection?.id
        var scored: [(entry: Entry, similarity: Double)] = []
        for entry in pool(title.kind) where !seen.contains(entry.title.id) {
            let other = metadata(entry.title)
            var similarity = 2 * Double(genres(entry.title).filter { seedGenres.contains($0) }.count)
            if !seedKeywords.isEmpty, let keywords = other?.keywords {
                similarity += Double(keywords.filter { seedKeywords.contains($0.lowercased()) }.count)
            }
            if let seedCollection, other?.collection?.id == seedCollection { similarity += 3 }
            if seedGenres.isEmpty && seedKeywords.isEmpty,
               !Set(title.categories).isDisjoint(with: entry.title.categories) { similarity += 1 }
            if similarity > 0 { scored.append((entry, similarity)) }
        }
        scored.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : RailEngine.byScore($0.entry, $1.entry) }
        for item in scored {
            out.append(item.entry.title)
            if out.count == limit { break }
        }
        return out
    }

    /// Credits (person.movieCredits / tvCredits ∩ TMDB ids) plus cast/crew matches in metadata; showcase first.
    func titles(for person: PersonDetails) -> [Title] {
        var found: [Title] = []
        var seen = Set<String>()
        func add(_ title: Title) { if !title.isAdult && seen.insert(title.id).inserted { found.append(title) } }
        library.titles(tmdbIDs: person.movieCredits, kind: .movie, metadata: context.metadata).forEach(add)
        library.titles(tmdbIDs: person.tvCredits, kind: .series, metadata: context.metadata).forEach(add)
        if person.id != 0 {
            for id in context.metadata.keys.sorted() {
                guard let md = context.metadata[id],
                      md.cast.contains(where: { $0.personID == person.id }) || md.crew.contains(where: { $0.personID == person.id }),
                      let title = library.title(id) else { continue }
                add(title)
            }
        }
        let scored = found.map { (title: $0, score: entry(for: $0).score) }
        return scored.sorted { a, b in
            if a.title.isLibraryShowcase != b.title.isLibraryShowcase { return a.title.isLibraryShowcase }
            return a.score != b.score ? a.score > b.score : a.title.id < b.title.id
        }.map(\.title)
    }

    // MARK: Grid

    func grid(_ kind: TitleKind?, filter: BrowseFilter) -> [Title] {
        var titles: [Title]
        var keyed = false
        if let key = filter.seeAllKey?.nonEmpty, let list = resolve(key: key, kind: kind) {
            titles = list
            keyed = true
        } else {
            titles = pool(kind).map(\.title)
        }
        titles = titles.filter { passes($0, filter) }
        return sorted(titles, by: filter.sort, keepOrder: keyed)
    }

    /// The full list behind a rail's `seeAllKey`. An explicit kind in the key ("top:movie") wins over `kind`.
    func resolve(key: String, kind: TitleKind?) -> [Title]? {
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let head = parts[0].lowercased()
        let rest = parts.count > 1 ? parts[1] : ""
        func kindFrom(_ text: String) -> TitleKind? {
            switch text.lowercased() {
            case "movie", "movies": return .movie
            case "series", "tv", "show", "shows": return .series
            default: return kind
            }
        }
        func byKind(_ list: [Title]) -> [Title] {
            guard let kind else { return list }
            return list.filter { $0.kind == kind }
        }
        switch head {
        case "top": return pool(kindFrom(rest)).map(\.title)
        case "trending": return trending(kindFrom(rest))
        case "new": return newArrivals(kindFrom(rest))
        case "uhd": return ultraHD(kindFrom(rest))
        case "acclaimed": return acclaimed(kindFrom(rest))
        case "gems": return hiddenGems(kindFrom(rest))
        case "genre": return genreList(rest, kind)
        case "world":
            guard let world = world(forKey: rest) else { return [] }
            return worldList(world, kind)
        case "decade":
            guard let decade = Int(rest) else { return [] }
            return decadeList(decade, kind)
        case "because":
            guard let seed = library.title(rest) else { return [] }
            return byKind(becauseList(seed))
        case "collection":
            guard let id = Int(rest) else { return [] }
            return collectionMembers(id, kind)
        case "similar":
            guard let title = library.title(rest) else { return [] }
            return byKind(similar(to: title, limit: 500))
        case "continue": return continueWatching(kindFrom(rest)).map(\.title)
        case "mylist": return byKind(context.userState.myList.compactMap { library.title($0) }.filter { !$0.isAdult })
        default: return nil
        }
    }

    func passes(_ title: Title, _ filter: BrowseFilter) -> Bool {
        let md = metadata(title)
        if let genre = filter.genre?.nonEmpty, !hasGenre(title, genre) { return false }
        if let decade = filter.decade {
            guard let year = RankMath.year(title, metadata: md), year >= decade, year < decade + 10 else { return false }
        }
        if let minimum = filter.minRating {
            guard let rating = md?.voteAverage ?? title.providerRating, rating >= minimum else { return false }
        }
        if let country = filter.country?.nonEmpty?.uppercased() {
            let countries = (md?.originCountries ?? []) + (md?.productionCountries ?? []) + title.countries
            guard countries.contains(where: { $0.uppercased() == country }) else { return false }
        }
        if let language = filter.language?.nonEmpty?.lowercased() {
            let languages = [md?.originalLanguage].compactMap { $0 } + (md?.spokenLanguages ?? []) + title.languages
            guard languages.contains(where: { $0.lowercased() == language }) else { return false }
        }
        if let quality = filter.minQuality, title.bestQuality < quality { return false }
        return true
    }

    func sorted(_ titles: [Title], by sort: BrowseFilter.Sort, keepOrder: Bool) -> [Title] {
        if sort == .recommended {
            if keepOrder { return titles }
            return titles.map { entry(for: $0) }.sorted(by: RailEngine.byScore).map(\.title)
        }
        let entries = titles.map { entry(for: $0) }
        func tie(_ a: Entry, _ b: Entry) -> Bool { RailEngine.byScore(a, b) }
        let result: [Entry]
        switch sort {
        case .recommended:
            result = entries
        case .topRated:
            func value(_ e: Entry) -> Double {
                e.rating ?? e.title.providerRating.map { Ranker.weightedRating(average: $0, votes: RankMath.assumedVotes) } ?? 0
            }
            result = entries.sorted { value($0) != value($1) ? value($0) > value($1) : ($0.votes != $1.votes ? $0.votes > $1.votes : tie($0, $1)) }
        case .newest:
            func value(_ e: Entry) -> Date { RankMath.releaseDate(e.title, metadata: metadata(e.title)) ?? .distantPast }
            result = entries.sorted { value($0) != value($1) ? value($0) > value($1) : tie($0, $1) }
        case .recentlyAdded:
            func value(_ e: Entry) -> Date { e.title.addedAt ?? .distantPast }
            result = entries.sorted { value($0) != value($1) ? value($0) > value($1) : tie($0, $1) }
        case .alphabetical:
            let keys = Dictionary(entries.map { ($0.title.id, TextTokens.sortKey($0.title.name)) }, uniquingKeysWith: { a, _ in a })
            result = entries.sorted { a, b in
                let x = keys[a.title.id] ?? "", y = keys[b.title.id] ?? ""
                if x != y { return x < y }
                let ya = a.title.year ?? 0, yb = b.title.year ?? 0
                return ya != yb ? ya < yb : a.title.id < b.title.id
            }
        case .popularity:
            func value(_ e: Entry) -> Double { metadata(e.title)?.popularity ?? -1 }
            result = entries.sorted { value($0) != value($1) ? value($0) > value($1) : tie($0, $1) }
        }
        return result.map(\.title)
    }
}
