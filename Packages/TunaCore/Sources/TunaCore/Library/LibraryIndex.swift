import Foundation

/// Internal index behind `Library` (owner: Library). Built once per catalog and immutable afterwards, except for one
/// lazily built, lock-protected reverse map of metadata TMDB ids.
final class LibraryIndex: @unchecked Sendable {
    private enum VariantSlot {
        case movie(Int, Int)
        case series(Int, Int)
        case channel(Int, Int)
    }

    struct TitleSlot {
        let kind: TitleKind
        let index: Int
        /// Showcase first, then catalog order (movies before series).
        let order: Int
    }

    private let movies: [Title]
    private let series: [Title]
    private let allChannels: [Channel]
    private let titleSlots: [String: TitleSlot]
    private let channelSlots: [String: Int]
    private let variantSlots: [String: VariantSlot]
    private let providerTMDB: [Int: [TitleSlot]]
    private let showcaseMovies: [Title]
    private let showcaseSeries: [Title]
    let liveShowcase: [Channel]
    private let vaultMovies: [VaultShelf: [Title]]
    private let vaultSeries: [VaultShelf: [Title]]
    private let vaultChannelLists: [VaultShelf: [Channel]]
    let vaultCounts: [VaultShelf: Int]
    private let otherLanguageMovies: [(language: String, titles: [Title])]
    private let otherLanguageSeries: [(language: String, titles: [Title])]
    private let otherLanguageAll: [(language: String, titles: [Title])]
    private let categoryLists: [ChannelCategory: [Channel]]
    let channelCategories: [(category: ChannelCategory, count: Int)]
    let channelGroups: [(name: String, channels: [Channel])]

    private let lock = NSLock()
    private var metadataMapCount = -1
    private var metadataMapSample: [(titleID: String, tmdbID: Int?)] = []
    private var metadataMap: [Int: [TitleSlot]] = [:]

    init(catalog: CuratedCatalog) {
        movies = catalog.movies
        series = catalog.series
        allChannels = catalog.channels

        var titleSlots: [String: TitleSlot] = [:]
        var variantSlots: [String: VariantSlot] = [:]
        var providerTMDB: [Int: [TitleSlot]] = [:]
        var showcaseMovies: [Title] = [], showcaseSeries: [Title] = []
        var vaultMovies: [VaultShelf: [Title]] = [:], vaultSeries: [VaultShelf: [Title]] = [:]
        var counts: [VaultShelf: Int] = [:]
        for shelf in VaultShelf.allCases { counts[shelf] = 0 }
        titleSlots.reserveCapacity(catalog.movies.count + catalog.series.count)

        let showcaseBase = 0, vaultBase = (catalog.movies.count + catalog.series.count + 1)
        for (kind, list) in [(TitleKind.movie, catalog.movies), (TitleKind.series, catalog.series)] {
            let offset = kind == .movie ? 0 : catalog.movies.count
            for (index, title) in list.enumerated() {
                let placement = title.libraryPlacement
                let slot = TitleSlot(kind: kind, index: index,
                                     order: (placement.isShowcase ? showcaseBase : vaultBase) + offset + index)
                if titleSlots[title.id] == nil { titleSlots[title.id] = slot }
                for (variantIndex, variant) in title.variants.enumerated() where variantSlots[variant.id] == nil {
                    variantSlots[variant.id] = kind == .movie ? .movie(index, variantIndex) : .series(index, variantIndex)
                }
                if let tmdb = title.providerTMDBID { providerTMDB[tmdb, default: []].append(slot) }
                switch placement {
                case .showcase:
                    if kind == .movie { showcaseMovies.append(title) } else { showcaseSeries.append(title) }
                case .vault(let shelf):
                    if kind == .movie { vaultMovies[shelf, default: []].append(title) } else { vaultSeries[shelf, default: []].append(title) }
                    counts[shelf, default: 0] += 1
                }
            }
        }
        for key in Array(providerTMDB.keys) { providerTMDB[key]?.sort { $0.order < $1.order } }

        var channelSlots: [String: Int] = [:]
        var liveShowcase: [Channel] = []
        var vaultChannelLists: [VaultShelf: [Channel]] = [:]
        var categoryLists: [ChannelCategory: [Channel]] = [:]
        var groupLists: [String: [Channel]] = [:]
        for (index, channel) in catalog.channels.enumerated() {
            if channelSlots[channel.id] == nil { channelSlots[channel.id] = index }
            for (variantIndex, variant) in channel.variants.enumerated() where variantSlots[variant.id] == nil {
                variantSlots[variant.id] = .channel(index, variantIndex)
            }
            switch channel.libraryPlacement {
            case .showcase:
                liveShowcase.append(channel)
                let categories = channel.categories.isEmpty ? [ChannelCategory.other] : channel.categories
                var seen = Set<ChannelCategory>()
                for category in categories where seen.insert(category).inserted { categoryLists[category, default: []].append(channel) }
                let group = channel.groupName?.nonEmpty ?? "Other"
                groupLists[group, default: []].append(channel)
            case .vault(let shelf):
                vaultChannelLists[shelf, default: []].append(channel)
                counts[shelf, default: 0] += 1
            }
        }

        self.titleSlots = titleSlots
        self.variantSlots = variantSlots
        self.providerTMDB = providerTMDB
        self.showcaseMovies = showcaseMovies
        self.showcaseSeries = showcaseSeries
        self.vaultMovies = vaultMovies
        self.vaultSeries = vaultSeries
        self.vaultCounts = counts
        self.channelSlots = channelSlots
        self.liveShowcase = liveShowcase
        self.vaultChannelLists = vaultChannelLists
        self.categoryLists = categoryLists

        let categoryOrder = Dictionary(uniqueKeysWithValues: ChannelCategory.allCases.enumerated().map { ($1, $0) })
        self.channelCategories = categoryLists.map { (category: $0.key, count: $0.value.count) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : (categoryOrder[$0.category] ?? 0) < (categoryOrder[$1.category] ?? 0)
        }
        self.channelGroups = groupLists.map { (name: $0.key, channels: $0.value) }.sorted {
            $0.channels.count != $1.channels.count ? $0.channels.count > $1.channels.count
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        let otherMovies = vaultMovies[.otherLanguages] ?? []
        let otherSeries = vaultSeries[.otherLanguages] ?? []
        self.otherLanguageMovies = LibraryIndex.groupByLanguage(otherMovies)
        self.otherLanguageSeries = LibraryIndex.groupByLanguage(otherSeries)
        self.otherLanguageAll = LibraryIndex.groupByLanguage(otherMovies + otherSeries)
    }

    // MARK: Lookups

    func title(_ id: String) -> Title? {
        guard let slot = titleSlots[id] else { return nil }
        return title(at: slot)
    }

    func channel(_ id: String) -> Channel? {
        guard let index = channelSlots[id] else { return nil }
        return allChannels[index]
    }

    func variant(_ id: String) -> (title: Title?, channel: Channel?, variant: Variant)? {
        guard let slot = variantSlots[id] else { return nil }
        switch slot {
        case .movie(let t, let v): return (movies[t], nil, movies[t].variants[v])
        case .series(let t, let v): return (series[t], nil, series[t].variants[v])
        case .channel(let c, let v): return (nil, allChannels[c], allChannels[c].variants[v])
        }
    }

    func titles(tmdbIDs: [Int], kind: TitleKind?) -> [Title] {
        var seen = Set<String>()
        var out: [Title] = []
        for id in tmdbIDs {
            for slot in providerTMDB[id] ?? [] where kind == nil || slot.kind == kind {
                let title = title(at: slot)
                if seen.insert(title.id).inserted { out.append(title) }
            }
        }
        return out
    }

    /// Like `titles(tmdbIDs:kind:)`, also matching `MediaMetadata.tmdbID` (metadata kind must equal the title kind).
    func titles(tmdbIDs: [Int], kind: TitleKind?, metadata: [String: MediaMetadata]) -> [Title] {
        let fromMetadata = metadataSlots(metadata)
        var seen = Set<String>()
        var out: [Title] = []
        for id in tmdbIDs {
            let provider = providerTMDB[id] ?? []
            let meta = fromMetadata[id] ?? []
            let slots = meta.isEmpty ? provider : (provider + meta).sorted { $0.order < $1.order }
            for slot in slots where kind == nil || slot.kind == kind {
                let title = title(at: slot)
                if seen.insert(title.id).inserted { out.append(title) }
            }
        }
        return out
    }

    func showcase(_ kind: TitleKind) -> [Title] { kind == .movie ? showcaseMovies : showcaseSeries }

    func vault(_ shelf: VaultShelf, kind: TitleKind?) -> [Title] {
        switch kind {
        case .movie?: return vaultMovies[shelf] ?? []
        case .series?: return vaultSeries[shelf] ?? []
        case nil: return (vaultMovies[shelf] ?? []) + (vaultSeries[shelf] ?? [])
        }
    }

    func vaultChannels(_ shelf: VaultShelf) -> [Channel] { vaultChannelLists[shelf] ?? [] }

    func otherLanguageGroups(kind: TitleKind?) -> [(language: String, titles: [Title])] {
        switch kind {
        case .movie?: return otherLanguageMovies
        case .series?: return otherLanguageSeries
        case nil: return otherLanguageAll
        }
    }

    func channels(in category: ChannelCategory) -> [Channel] { categoryLists[category] ?? [] }

    func genres(_ kind: TitleKind, metadata: [String: MediaMetadata]) -> [(genre: String, count: Int)] {
        var counts: [String: Int] = [:]
        for title in showcase(kind) {
            for genre in GenreNames.genres(of: title, metadata: metadata[title.id]) { counts[genre, default: 0] += 1 }
        }
        return counts.map { (genre: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.genre < $1.genre
        }
    }

    // MARK: Helpers

    private func title(at slot: TitleSlot) -> Title { slot.kind == .movie ? movies[slot.index] : series[slot.index] }

    /// Reverse map TMDB id -> titles from metadata, rebuilt when the metadata count (or a sampled entry) changes.
    private func metadataSlots(_ metadata: [String: MediaMetadata]) -> [Int: [TitleSlot]] {
        lock.lock()
        defer { lock.unlock() }
        if metadataMapCount == metadata.count,
           metadataMapSample.allSatisfy({ metadata[$0.titleID]?.tmdbID == $0.tmdbID && metadata[$0.titleID] != nil }) {
            return metadataMap
        }
        var map: [Int: [TitleSlot]] = [:]
        var sample: [(titleID: String, tmdbID: Int?)] = []
        for (titleID, md) in metadata {
            if sample.count < 16 { sample.append((titleID, md.tmdbID)) }
            guard let tmdb = md.tmdbID, let slot = titleSlots[titleID], slot.kind == md.kind else { continue }
            map[tmdb, default: []].append(slot)
        }
        for key in Array(map.keys) { map[key]?.sort { $0.order < $1.order } }
        metadataMap = map
        metadataMapCount = metadata.count
        metadataMapSample = sample
        return map
    }

    /// Groups Vault "Other Languages" titles by their first language, biggest group first ("und" last).
    static func groupByLanguage(_ titles: [Title]) -> [(language: String, titles: [Title])] {
        var groups: [String: [Title]] = [:]
        for title in titles { groups[groupLanguage(title), default: []].append(title) }
        return groups.map { (language: $0.key, titles: $0.value) }.sorted { lhs, rhs in
            if (lhs.language == "und") != (rhs.language == "und") { return rhs.language == "und" }
            return lhs.titles.count != rhs.titles.count ? lhs.titles.count > rhs.titles.count : lhs.language < rhs.language
        }
    }

    static func groupLanguage(_ title: Title) -> String {
        if let language = title.languages.first?.nonEmpty { return language.lowercased() }
        for variant in title.variants { if let language = variant.parsed.languages.first?.nonEmpty { return language.lowercased() } }
        let countries = title.countries + title.variants.flatMap { $0.parsed.countries }
        for country in countries { if let language = WorldNames.primaryLanguage(ofCountry: country) { return language } }
        return "und"
    }
}
