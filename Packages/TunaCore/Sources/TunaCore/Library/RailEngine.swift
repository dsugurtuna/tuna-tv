import Foundation

/// Per-call engine behind `RailComposer` (owner: Library). Scores the showcase once into score-sorted pools, then
/// answers every rail rule from them. Each rule returns its FULL ordered list; a rail shows the first 24 items and
/// `grid(seeAllKey:)` returns the whole list, so a rail is always a prefix of its "See all" page.
final class RailEngine {
    struct Entry {
        let title: Title
        let score: Double
        /// Bayesian weighted rating, when metadata has a vote average and a vote count.
        let rating: Double?
        let votes: Int
    }

    /// A non-English world from the user's preferences ("From Türkiye").
    struct World {
        /// "TR" for a country, "lang:ar" for a language-only world.
        let key: String
        let country: String?
        let language: String?
        let title: String
    }

    static let railMaximum = 24
    static let railMinimum = 10
    static let heroCount = 6

    let context: RailContext
    var library: Library { context.library }

    private(set) lazy var movies: [Entry] = makePool(.movie)
    private(set) lazy var series: [Entry] = makePool(.series)
    private(set) lazy var everything: [Entry] = (movies + series).sorted(by: RailEngine.byScore)
    private lazy var entryByID: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in everything { map[entry.title.id] = entry }
        return map
    }()
    private(set) lazy var trendingRanks: [TitleKind: [Int: Int]] = {
        func ranks(_ ids: [Int]) -> [Int: Int] {
            var map: [Int: Int] = [:]
            for (index, id) in ids.enumerated() where map[id] == nil { map[id] = index }
            return map
        }
        return [.movie: ranks(context.trendingMovieIDs), .series: ranks(context.trendingSeriesIDs)]
    }()
    private(set) lazy var worlds: [World] = makeWorlds()
    private var genreCache: [String: [String]] = [:]
    private var genreKeyCache: [String: String] = [:]

    init(_ context: RailContext) { self.context = context }

    // MARK: Basics

    func metadata(_ title: Title) -> MediaMetadata? { context.metadata[title.id] }

    func pool(_ kind: TitleKind?) -> [Entry] {
        switch kind {
        case .movie?: return movies
        case .series?: return series
        case nil: return everything
        }
    }

    func entry(for title: Title) -> Entry { entryByID[title.id] ?? makeEntry(title) }

    private func makePool(_ kind: TitleKind) -> [Entry] {
        library.showcase(kind).filter { !$0.isAdult }.map(makeEntry).sorted(by: RailEngine.byScore)
    }

    private func makeEntry(_ title: Title) -> Entry {
        let md = metadata(title)
        var rating: Double?
        var votes = 0
        if let md, let average = md.voteAverage, let count = md.voteCount, count > 0 {
            rating = Ranker.weightedRating(average: average, votes: count)
            votes = count
        }
        return Entry(title: title, score: Ranker.score(title, metadata: md, now: context.now), rating: rating, votes: votes)
    }

    static func byScore(_ a: Entry, _ b: Entry) -> Bool { a.score != b.score ? a.score > b.score : a.title.id < b.title.id }

    /// Canonical genres (metadata preferred, provider hints otherwise), cached per title.
    func genres(_ title: Title) -> [String] {
        if let cached = genreCache[title.id] { return cached }
        let value = GenreNames.genres(of: title, metadata: metadata(title))
        genreCache[title.id] = value
        return value
    }

    func genreKey(_ name: String) -> String {
        if let cached = genreKeyCache[name] { return cached }
        let value = GenreNames.key(name)
        genreKeyCache[name] = value
        return value
    }

    // MARK: Pages

    func home() -> [Rail] {
        let continueItems = continueWatching(nil)
        var rails: [Rail] = []
        rails.append(contentsOf: [continueRail(continueItems, key: "continue:all"),
                                  top10Rail(.movie), top10Rail(.series), liveNowRail()].compactMap { $0 })
        rails.append(contentsOf: [
            titleRail(id: "trending", title: "Trending This Week", key: "trending:all", trending(nil)),
            titleRail(id: "new", title: "New Arrivals", key: "new:all", newArrivals(nil)),
            titleRail(id: "uhd", title: "Ultra HD Showcase", subtitle: "4K, HDR and Dolby Vision", key: "uhd:all",
                      ultraHD(nil), style: .landscape),
        ].compactMap { $0 })
        rails.append(contentsOf: becauseRails(nil))
        rails.append(contentsOf: [
            titleRail(id: "acclaimed", title: "Critically Acclaimed", key: "acclaimed:all", acclaimed(nil)),
            titleRail(id: "gems", title: "Hidden Gems", subtitle: "Loved by the few who found them", key: "gems:all", hiddenGems(nil)),
        ].compactMap { $0 })
        rails.append(contentsOf: worldRails(nil))
        rails.append(contentsOf: genreRails(nil, count: 6))
        rails.append(contentsOf: collectionRails(nil, count: 3))
        return withHero(rails, kind: nil, continueItems: continueItems)
    }

    func browse(_ kind: TitleKind) -> [Rail] {
        let k = kind.rawValue
        let continueItems = continueWatching(kind)
        var rails: [Rail] = []
        rails.append(contentsOf: [continueRail(continueItems, key: "continue:\(k)"), top10Rail(kind)].compactMap { $0 })
        rails.append(contentsOf: [
            titleRail(id: "trending", title: "Trending This Week", key: "trending:\(k)", trending(kind)),
            titleRail(id: "new", title: "New Arrivals", key: "new:\(k)", newArrivals(kind)),
            titleRail(id: "uhd", title: "Ultra HD Showcase", subtitle: "4K, HDR and Dolby Vision", key: "uhd:\(k)",
                      ultraHD(kind), style: .landscape),
        ].compactMap { $0 })
        rails.append(contentsOf: becauseRails(kind))
        rails.append(contentsOf: [
            titleRail(id: "acclaimed", title: "Critically Acclaimed", key: "acclaimed:\(k)", acclaimed(kind)),
            titleRail(id: "gems", title: "Hidden Gems", subtitle: "Loved by the few who found them", key: "gems:\(k)", hiddenGems(kind)),
        ].compactMap { $0 })
        rails.append(contentsOf: worldRails(kind))
        rails.append(contentsOf: genreRails(kind, count: 12))
        rails.append(contentsOf: decadeRails(kind, count: 6))
        rails.append(contentsOf: collectionRails(kind, count: 4))
        return withHero(rails, kind: kind, continueItems: continueItems)
    }

    /// Puts the hero in front; its titles never appear in Continue Watching or in the first two rails after it.
    private func withHero(_ rails: [Rail], kind: TitleKind?, continueItems: [(title: Title, progress: WatchProgress)]) -> [Rail] {
        var excluded = Set(continueItems.map { $0.title.id })
        for rail in rails.prefix(2) {
            for item in rail.items {
                switch item {
                case .title(let title), .progress(let title, _): excluded.insert(title.id)
                case .channel, .live, .person: break
                }
            }
        }
        let hero = heroTitles(kind, excluding: excluded)
        guard !hero.isEmpty else { return rails }
        return [Rail(id: "hero", title: "Featured", style: .hero, items: hero.map { .title($0) })] + rails
    }

    // MARK: Rail builders

    func titleRail(id: String, title: String, subtitle: String? = nil, key: String?, _ list: [Title],
                   minimum: Int = RailEngine.railMinimum, style: RailStyle = .poster) -> Rail? {
        guard !list.isEmpty, list.count >= minimum else { return nil }
        return Rail(id: id, title: title, subtitle: subtitle, style: style,
                    items: list.prefix(RailEngine.railMaximum).map { .title($0) }, seeAllKey: key)
    }

    private func continueRail(_ items: [(title: Title, progress: WatchProgress)], key: String) -> Rail? {
        guard !items.isEmpty else { return nil }
        return Rail(id: "continue", title: "Continue Watching", style: .continueWatching,
                    items: items.prefix(RailEngine.railMaximum).map { .progress($0.title, $0.progress) }, seeAllKey: key)
    }

    private func top10Rail(_ kind: TitleKind) -> Rail? {
        let list = pool(kind).prefix(10).map(\.title)
        guard !list.isEmpty else { return nil }
        return Rail(id: "top10:\(kind.rawValue)", title: kind == .movie ? "Top 10 Movies" : "Top 10 Series", style: .top10,
                    items: list.map { .title($0) }, seeAllKey: "top:\(kind.rawValue)")
    }

    private func liveNowRail() -> Rail? {
        let items = liveNowItems()
        guard !items.isEmpty else { return nil }
        return Rail(id: "live-now", title: "Live Now", style: .liveNow, items: items)
    }

    func becauseRails(_ kind: TitleKind?) -> [Rail] {
        var rails: [Rail] = []
        for seed in recentSeeds(kind) {
            guard let rail = titleRail(id: "because:\(seed.id)", title: "Because You Watched \(seed.name)",
                                       key: "because:\(seed.id)", becauseList(seed)) else { continue }
            rails.append(rail)
            if rails.count == 2 { break }
        }
        return rails
    }

    func worldRails(_ kind: TitleKind?) -> [Rail] {
        worlds.compactMap { world in
            let flag = world.country.map { Flags.emoji(for: $0) } ?? ""
            return titleRail(id: "world:\(world.key)", title: world.title, subtitle: flag.isEmpty ? nil : flag,
                             key: "world:\(world.key)", worldList(world, kind))
        }
    }

    func genreRails(_ kind: TitleKind?, count: Int) -> [Rail] {
        var rails: [Rail] = []
        for (genre, total) in topGenres(kind) {
            guard total >= RailEngine.railMinimum, rails.count < count else { break }
            if let rail = titleRail(id: "genre:\(genre)", title: genre, key: "genre:\(genre)", genreList(genre, kind)) {
                rails.append(rail)
            }
        }
        return rails
    }

    func decadeRails(_ kind: TitleKind?, count: Int) -> [Rail] {
        var buckets: [Int: Int] = [:]
        for entry in pool(kind) {
            if let year = RankMath.year(entry.title, metadata: metadata(entry.title)) { buckets[year / 10 * 10, default: 0] += 1 }
        }
        return buckets.filter { $0.value >= RailEngine.railMinimum }.keys.sorted(by: >).prefix(count).compactMap { decade in
            titleRail(id: "decade:\(decade)", title: "Best of the \(decade)s", key: "decade:\(decade)", decadeList(decade, kind))
        }
    }

    func collectionRails(_ kind: TitleKind?, count: Int) -> [Rail] {
        collections(kind).prefix(count).map { group in
            Rail(id: "collection:\(group.ref.id)", title: group.ref.name, style: .collections,
                 items: group.titles.prefix(RailEngine.railMaximum).map { .title($0) }, seeAllKey: "collection:\(group.ref.id)")
        }
    }
}
