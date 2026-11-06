import Foundation

/// The implementation behind `Curator.curate`. Follows the contract rules in `CurationContracts.swift`; decisions
/// the contract leaves open:
/// - a record without a year joins the single same-key group that has one ("The Matrix 4K" + "The Matrix (1999)");
///   with two candidate years (remakes) it stays on its own. Live feeds without a country join the single
///   same-key channel that has one ("BBC One (Backup)" + "UK: BBC One FHD").
/// - the provider's `year` field, M3U `tvg-language` / `tvg-country` and the category fill gaps in the name.
/// - region-only tags ("NORDIC | ...") match when the region contains a world country.
/// - separator rows and junk names ("##### UK SPORTS #####") go to the Unsorted shelf, each on its own.
/// - `showLowQuality == false` drops CAM/TS/SCR versions entirely.
/// - auto-relax lowers the floor one tier only when that actually adds showcase titles.
/// - a series id gets ":<year>" only when two series groups share a key (the largest keeps the plain id).
/// - outputs keep the providers' order (first appearance); every choice has a deterministic tie-break.
struct CurationRun {
    /// Score bonus for a playback-verified quality at least as good as the name claimed.
    static let verifiedBonus = 10

    let preferences: ContentPreferences
    let verifiedQualities: [String: Int]
    let failingVariants: [String: Int]
    private let worldLanguages: [String]
    private let worldCountries: Set<String>

    init(preferences: ContentPreferences, verifiedQualities: [String: Int], failingVariants: [String: Int]) {
        self.preferences = preferences
        self.verifiedQualities = verifiedQualities
        self.failingVariants = failingVariants
        worldLanguages = preferences.worlds.languages.map { $0.lowercased() }
        worldCountries = Set(preferences.worlds.countries.map { $0.uppercased() })
    }

    private struct Item {
        let order: Int
        let raw: RawItem
        var parsed: ParsedName
        let hints: CategoryHints?
        let junk: Bool
    }

    private struct Group {
        var key: String
        var year: Int?
        var country: String?
        var items: [Item]
        var firstOrder: Int
        var merged = false
    }

    private struct Draft {
        let group: Group
        /// Best first; `items[i]` belongs to `variants[i]`.
        let variants: [Variant]
        let items: [Item]
        let isAdult: Bool
        let isJunk: Bool
        /// Best quality among world-matching versions without a CAM/TS/SCR source.
        let showcaseQuality: Quality?
    }

    // MARK: Run

    func run(_ catalogs: [ProviderCatalog]) -> CuratedCatalog {
        var rawCounts: [String: Int] = ["live": 0, "movie": 0, "series": 0]
        var movies: [Item] = []
        var series: [Item] = []
        var live: [Item] = []
        var hintCache: [String: CategoryHints] = [:]
        // Pass 1 (sequential): resolve categories and parse each distinct one once.
        var pending: [(raw: RawItem, hints: CategoryHints?)] = []
        for catalog in catalogs {
            var categoryNames: [String: String] = [:]
            for category in catalog.categories { categoryNames[category.kind.rawValue + "|" + category.id] = category.name }
            for raw in catalog.items {
                let kind = raw.ref.kind
                rawCounts[kind.rawValue, default: 0] += 1
                guard kind != .episode else { continue }
                var categoryName = raw.categoryName?.nonEmpty
                if categoryName == nil, let id = raw.categoryID { categoryName = categoryNames[kind.rawValue + "|" + id] }
                var hints: CategoryHints?
                if let name = categoryName {
                    let cacheKey = kind.rawValue + "|" + name
                    if let cached = hintCache[cacheKey] {
                        hints = cached
                    } else {
                        let parsedHints = CategoryParser.parse(name, kind: kind)
                        hintCache[cacheKey] = parsedHints
                        hints = parsedHints
                    }
                }
                pending.append((raw, hints))
            }
        }
        // Pass 2 (parallel, order-preserving): parse every name.
        let parsedNames = ParallelMap.map(count: pending.count) { index -> ParsedName in
            let entry = pending[index]
            return NameParser.parse(entry.raw.name, kind: entry.raw.ref.kind, category: CurationRun.mergeTVG(entry.hints, entry.raw))
        }
        // Pass 3 (sequential): gap filling, filters, bucketing in input order.
        var order = 0
        for (index, entry) in pending.enumerated() {
            let raw = entry.raw
            let kind = raw.ref.kind
            var parsed = parsedNames[index]
            if parsed.year == nil, kind != .live, let year = raw.year, year >= Lexicon.minYear, year <= Lexicon.maxYear {
                parsed.year = year
            }
            if !preferences.showLowQuality && kind != .live && parsed.source?.isLowGrade == true { continue }
            let item = Item(order: order, raw: raw, parsed: parsed, hints: entry.hints, junk: CurationRun.isJunkName(raw.name))
            order += 1
            switch kind {
            case .movie: movies.append(item)
            case .series: series.append(item)
            default: live.append(item)
            }
        }

        let movieDrafts = group(movies, live: false).map { draft($0) }
        let seriesDrafts = group(series, live: false).map { draft($0) }
        let channelDrafts = group(live, live: true).map { draft($0) }
        let (movieMinimum, moviesRelaxed) = chooseMinimum(movieDrafts)
        let (seriesMinimum, seriesRelaxed) = chooseMinimum(seriesDrafts)

        let movieTitles = movieDrafts.map { d in
            makeTitle(d, kind: .movie, id: "movie:\(d.group.key):\(d.group.year ?? 0)", placement: placement(d, minimum: movieMinimum))
        }
        let seriesIDs = seriesIdentifiers(seriesDrafts)
        var seriesTitles: [Title] = []
        for (index, d) in seriesDrafts.enumerated() {
            seriesTitles.append(makeTitle(d, kind: .series, id: seriesIDs[index], placement: placement(d, minimum: seriesMinimum)))
        }
        let channels = channelDrafts.map { makeChannel($0) }

        let stats = makeStats(rawCounts: rawCounts, movies: movieTitles, series: seriesTitles, channels: channels,
                              relaxed: moviesRelaxed || seriesRelaxed)
        return CuratedCatalog(movies: movieTitles, series: seriesTitles, channels: channels, stats: stats)
    }

    // MARK: Grouping

    private static func timeshiftSuffix(_ hours: Int?) -> String {
        guard let hours else { return "" }
        return hours > 0 ? " +\(hours)" : " \(hours)"
    }

    /// Movies/series: key + year. Live: key (+ timeshift) + country. Unqualified groups join a single qualified sibling.
    private func group(_ items: [Item], live: Bool) -> [Group] {
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for item in items {
            let key: String
            if item.junk || item.parsed.key.isEmpty {
                key = "#" + item.raw.ref.id
            } else {
                key = live ? item.parsed.key + CurationRun.timeshiftSuffix(item.parsed.timeshiftHours) : item.parsed.key
            }
            let year = live ? nil : item.parsed.year
            let country = live ? item.parsed.countries.first : nil
            let qualifier = live ? (country ?? "") : (year.map { String($0) } ?? "")
            let groupKey = key + "|" + qualifier
            if let existing = index[groupKey] {
                groups[existing].items.append(item)
            } else {
                index[groupKey] = groups.count
                groups.append(Group(key: key, year: year, country: country, items: [item], firstOrder: item.order))
            }
        }
        var byKey: [String: [Int]] = [:]
        for (i, g) in groups.enumerated() { byKey[g.key, default: []].append(i) }
        for i in groups.indices {
            let unqualified = live ? groups[i].country == nil : groups[i].year == nil
            guard unqualified, let siblings = byKey[groups[i].key], siblings.count > 1 else { continue }
            var values = Set<String>()
            var target: Int?
            for j in siblings where j != i {
                let value = live ? groups[j].country : groups[j].year.map { String($0) }
                if let value {
                    values.insert(value)
                    if target == nil { target = j }
                }
            }
            guard values.count == 1, let t = target else { continue }
            groups[t].items.append(contentsOf: groups[i].items)
            groups[t].firstOrder = min(groups[t].firstOrder, groups[i].firstOrder)
            groups[i].merged = true
        }
        return groups.filter { !$0.merged }.sorted { $0.firstOrder < $1.firstOrder }
    }

    // MARK: Variants

    private func verifiedQuality(_ id: String) -> Quality? {
        guard let value = verifiedQualities[id] else { return nil }
        if value >= 0 && value <= 4 {
            let quality = Quality(rawValue: value) ?? .unknown
            return quality == .unknown ? nil : quality
        }
        let quality = Quality.from(height: value)
        return quality == .unknown ? nil : quality
    }

    private func matchesWorld(_ parsed: ParsedName) -> Bool {
        if !parsed.languages.isEmpty {
            for language in parsed.languages where worldLanguages.contains(language.lowercased()) { return true }
            return false
        }
        if !parsed.countries.isEmpty {
            for country in parsed.countries where worldCountries.contains(country.uppercased()) { return true }
            return false
        }
        if !parsed.regions.isEmpty {
            for region in parsed.regions {
                if let members = WorldData.regionCountries[region], !members.isDisjoint(with: worldCountries) { return true }
            }
            return false
        }
        if let hint = ScriptDetector.languageHint(for: parsed.title), !worldLanguages.contains(hint) { return false }
        return true
    }

    /// 0 = primary world language, 1 = untagged, 2+ = other world languages, max = outside the worlds.
    private func languageRank(_ parsed: ParsedName) -> Int {
        if parsed.languages.isEmpty { return 1 }
        var best = Int.max
        for language in parsed.languages {
            if let index = worldLanguages.firstIndex(of: language.lowercased()) {
                best = min(best, index == 0 ? 0 : index + 1)
            }
        }
        return best
    }

    private func draft(_ g: Group) -> Draft {
        var entries: [(variant: Variant, item: Item, rank: Int)] = []
        entries.reserveCapacity(g.items.count)
        for item in g.items {
            let id = item.raw.ref.id
            let verified = verifiedQuality(id)
            let matches = matchesWorld(item.parsed)
            let score = Curator.score(for: item.parsed, matchesWorld: matches, verifiedQuality: verified,
                                      failures: max(0, failingVariants[id] ?? 0))
            let variant = Variant(raw: item.raw, parsed: item.parsed, matchesWorld: matches, score: score, verifiedQuality: verified)
            entries.append((variant, item, languageRank(item.parsed)))
        }
        entries.sort { a, b in
            if a.variant.score != b.variant.score { return a.variant.score > b.variant.score }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.variant.effectiveQuality != b.variant.effectiveQuality { return a.variant.effectiveQuality > b.variant.effectiveQuality }
            if a.variant.parsed.isBackup != b.variant.parsed.isBackup { return !a.variant.parsed.isBackup }
            return a.item.order < b.item.order
        }
        var showcaseQuality: Quality?
        var adult = false
        var junk = true
        for entry in entries {
            let v = entry.variant
            if v.parsed.isAdult { adult = true }
            if !entry.item.junk { junk = false }
            if v.matchesWorld && v.parsed.source?.isLowGrade != true {
                if showcaseQuality == nil || v.effectiveQuality > showcaseQuality! { showcaseQuality = v.effectiveQuality }
            }
        }
        return Draft(group: g, variants: entries.map { $0.variant }, items: entries.map { $0.item }, isAdult: adult,
                     isJunk: junk, showcaseQuality: showcaseQuality)
    }

    // MARK: Placement

    private func eligible(_ d: Draft, _ minimum: Quality) -> Bool {
        guard !d.isAdult, !d.isJunk, let quality = d.showcaseQuality else { return false }
        return quality >= minimum
    }

    /// Showcase floor for one kind, relaxed one tier (uhd -> fhd, fhd -> hd) when the showcase would be too sparse.
    private func chooseMinimum(_ drafts: [Draft]) -> (Quality, Bool) {
        let base = preferences.showcaseQuality.minimum
        guard preferences.autoRelaxShowcase, base == .uhd || base == .fhd else { return (base, false) }
        var current = 0
        for d in drafts where eligible(d, base) { current += 1 }
        guard current < preferences.relaxThreshold else { return (base, false) }
        let lower: Quality = base == .uhd ? .fhd : .hd
        var relaxed = 0
        for d in drafts where eligible(d, lower) { relaxed += 1 }
        return relaxed > current ? (lower, true) : (base, false)
    }

    private func placement(_ d: Draft, minimum: Quality) -> Placement {
        if d.isAdult { return .vault(.adult) }
        if d.isJunk { return .vault(.unsorted) }
        guard let bestWorld = d.variants.first(where: { $0.matchesWorld }) else { return .vault(.otherLanguages) }
        if let quality = d.showcaseQuality, quality >= minimum { return .showcase }
        if bestWorld.parsed.source?.isLowGrade == true { return .vault(.lowQuality) }
        if bestWorld.parsed.source?.isDisc == true { return .vault(.disc) }
        switch bestWorld.effectiveQuality {
        case .uhd, .fhd, .hd: return .vault(.highDefinition)
        case .sd, .unknown: return .vault(.legacy)
        }
    }

    private func livePlacement(_ d: Draft) -> Placement {
        if d.isAdult { return .vault(.adult) }
        if d.isJunk { return .vault(.unsorted) }
        return d.variants.contains(where: { $0.matchesWorld }) ? .showcase : .vault(.otherLanguages)
    }

    // MARK: Titles and channels

    private func seriesIdentifiers(_ drafts: [Draft]) -> [String] {
        var byKey: [String: [Int]] = [:]
        for (i, d) in drafts.enumerated() { byKey[d.group.key, default: []].append(i) }
        var ids: [String] = []
        for (i, d) in drafts.enumerated() {
            let key = d.group.key
            guard let siblings = byKey[key], siblings.count > 1 else {
                ids.append("series:\(key)")
                continue
            }
            let primary = siblings.min { a, b in
                let da = drafts[a], db = drafts[b]
                if da.variants.count != db.variants.count { return da.variants.count > db.variants.count }
                if (da.group.year ?? 0) != (db.group.year ?? 0) { return (da.group.year ?? 0) > (db.group.year ?? 0) }
                return da.group.firstOrder < db.group.firstOrder
            }
            ids.append(primary == i ? "series:\(key)" : "series:\(key):\(d.group.year ?? 0)")
        }
        return ids
    }

    private static func hasLowercase(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where TextFold.isLowercase(scalar) { return true }
        return false
    }

    /// The default version's title, preferring a mixed-case spelling over an ALL-CAPS one.
    private static func displayName(_ variants: [Variant], preferred: Variant) -> String {
        if hasLowercase(preferred.parsed.title) { return preferred.parsed.title }
        for v in variants where hasLowercase(v.parsed.title) { return v.parsed.title }
        return preferred.parsed.title
    }

    private static func appendUnique(_ values: [String], to list: inout [String]) {
        for value in values where !list.contains(value) { list.append(value) }
    }

    private static func genreList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        for ch in raw {
            if ch == "," || ch == "/" || ch == "|" || ch == ";" || ch == "&" {
                if let value = current.nonEmpty { out.append(value) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if let value = current.nonEmpty { out.append(value) }
        return out
    }

    private func makeTitle(_ d: Draft, kind: TitleKind, id: String, placement: Placement) -> Title {
        let variants = d.variants
        let world = variants.filter { $0.matchesWorld }
        let pool = world.isEmpty ? variants : world
        let preferred = world.first ?? variants[0]
        var languages: [String] = []
        var countries: [String] = []
        var regions: [String] = []
        var categories: [String] = []
        var genres: [String] = []
        var platform: String?
        var tmdb: Int?
        var addedAt: Date?
        var rating: Double?
        var poster: String?
        var backdrop: String?
        var plot: String?
        for (index, v) in variants.enumerated() {
            let item = d.items[index]
            CurationRun.appendUnique(v.parsed.languages, to: &languages)
            CurationRun.appendUnique(v.parsed.countries, to: &countries)
            CurationRun.appendUnique(v.parsed.regions, to: &regions)
            if let clean = item.hints?.cleanName.nonEmpty { CurationRun.appendUnique([clean], to: &categories) }
            for genre in CurationRun.genreList(v.raw.genre) where !genres.contains(where: { $0.tunaFolded == genre.tunaFolded }) {
                genres.append(genre)
            }
            if let genre = item.hints?.genre, !genres.contains(where: { $0.tunaFolded == genre.tunaFolded }) { genres.append(genre) }
            if platform == nil { platform = v.parsed.platform }
            if tmdb == nil, let value = v.raw.tmdbID, value > 0 { tmdb = value }
            if let added = v.raw.addedAt, addedAt == nil || added > addedAt! { addedAt = added }
            if rating == nil { rating = v.raw.providerRating }
            if poster == nil { poster = v.raw.iconURL?.nonEmpty }
            if backdrop == nil { backdrop = v.raw.backdropURLs.first(where: { !$0.isEmpty }) }
            if plot == nil { plot = v.raw.plot?.nonEmpty }
        }
        var best = Quality.unknown
        var hdr: HDRFormat?
        for v in pool {
            if v.effectiveQuality > best { best = v.effectiveQuality }
            if let h = v.parsed.hdr, hdr == nil || NameParse.hdrRank(h) > NameParse.hdrRank(hdr!) { hdr = h }
        }
        return Title(id: id, kind: kind, name: CurationRun.displayName(variants, preferred: preferred), year: d.group.year,
                     variants: variants, placement: placement, bestQuality: best, hdr: hdr, languages: languages,
                     countries: countries, regions: regions, categories: categories, genres: genres, platform: platform,
                     providerTMDBID: tmdb, addedAt: addedAt, providerRating: rating, posterURL: poster,
                     backdropURL: backdrop, plot: plot, isAdult: d.isAdult)
    }

    private func makeChannel(_ d: Draft) -> Channel {
        let variants = d.variants
        let world = variants.filter { $0.matchesWorld }
        let pool = world.isEmpty ? variants : world
        let preferred = variants.first(where: { $0.matchesWorld && !$0.parsed.isBackup }) ?? variants[0]
        var name = CurationRun.displayName(variants, preferred: preferred)
        if let hours = preferred.parsed.timeshiftHours { name += CurationRun.timeshiftSuffix(hours) }
        var languages: [String] = []
        var countries: [String] = []
        var hints: [CategoryHints] = []
        var logo: String?
        var number: Int?
        var groupName: String?
        var epg: String?
        var catchup: Int?
        var isEvent = false
        var best = Quality.unknown
        for (index, v) in variants.enumerated() {
            let item = d.items[index]
            CurationRun.appendUnique(v.parsed.languages, to: &languages)
            CurationRun.appendUnique(v.parsed.countries, to: &countries)
            if let h = item.hints { hints.append(h) }
            if logo == nil { logo = v.raw.iconURL?.nonEmpty }
            if number == nil { number = v.raw.channelNumber }
            if groupName == nil { groupName = item.hints?.cleanName.nonEmpty }
            if epg == nil { epg = v.raw.epgChannelID?.nonEmpty }
            if let days = v.raw.catchupDays, days > 0, catchup == nil || days > catchup! { catchup = days }
            if v.parsed.isEvent { isEvent = true }
        }
        if let preferredNumber = preferred.raw.channelNumber { number = preferredNumber }
        for v in pool where v.effectiveQuality > best { best = v.effectiveQuality }
        let categories = ChannelClassifier.categories(channelName: name, hints: hints, groupNames: [], isAdult: d.isAdult,
                                                      isEvent: isEvent)
        let countryPart = d.group.country?.lowercased() ?? "xx"
        return Channel(id: "live:\(d.group.key):\(countryPart)", name: name, number: number, variants: variants, logoURL: logo,
                       groupName: groupName, categories: categories, languages: languages, countries: countries,
                       epgChannelID: epg, iptvOrgID: nil, catchupDays: catchup, placement: livePlacement(d),
                       bestQuality: best, isAdult: d.isAdult, isEvent: isEvent)
    }

    // MARK: Stats

    private static func qualityName(_ q: Quality) -> String {
        switch q {
        case .unknown: return "unknown"
        case .sd: return "sd"
        case .hd: return "hd"
        case .fhd: return "fhd"
        case .uhd: return "uhd"
        }
    }

    private func makeStats(rawCounts: [String: Int], movies: [Title], series: [Title], channels: [Channel],
                           relaxed: Bool) -> CurationStats {
        var stats = CurationStats()
        stats.rawCounts = rawCounts
        stats.titleCounts = ["movie": movies.count, "series": series.count, "live": channels.count]
        var showcase = ["movie": 0, "series": 0, "live": 0]
        var vault: [String: Int] = [:]
        for shelf in VaultShelf.allCases { vault[shelf.rawValue] = 0 }
        var qualities: [String: Int] = [:]
        var languages: [String: Int] = [:]
        var countries: [String: Int] = [:]
        var merged = 0
        var adult = 0
        func count(kind: String, placement: Placement, quality: Quality, langs: [String], ctys: [String], variants: Int,
                   isAdult: Bool) {
            merged += max(0, variants - 1)
            if isAdult { adult += 1 }
            switch placement {
            case .showcase: showcase[kind, default: 0] += 1
            case .vault(let shelf): vault[shelf.rawValue, default: 0] += 1
            }
            qualities[CurationRun.qualityName(quality), default: 0] += 1
            for language in langs { languages[language, default: 0] += 1 }
            for country in ctys { countries[country, default: 0] += 1 }
        }
        for t in movies {
            count(kind: "movie", placement: t.placement, quality: t.bestQuality, langs: t.languages, ctys: t.countries,
                  variants: t.variants.count, isAdult: t.isAdult)
        }
        for t in series {
            count(kind: "series", placement: t.placement, quality: t.bestQuality, langs: t.languages, ctys: t.countries,
                  variants: t.variants.count, isAdult: t.isAdult)
        }
        for c in channels {
            count(kind: "live", placement: c.placement, quality: c.bestQuality, langs: c.languages, ctys: c.countries,
                  variants: c.variants.count, isAdult: c.isAdult)
        }
        stats.duplicatesMerged = merged
        stats.showcaseCounts = showcase
        stats.vaultCounts = vault
        stats.qualityCounts = qualities
        stats.languageCounts = languages
        stats.countryCounts = countries
        stats.adultHidden = preferences.hideAdult ? adult : 0
        stats.showcaseRelaxed = relaxed
        return stats
    }

    // MARK: Helpers

    /// M3U `tvg-language` / `tvg-country` beat the category's locale (they describe the channel itself).
    private static func mergeTVG(_ hints: CategoryHints?, _ raw: RawItem) -> CategoryHints? {
        let languages = tvgLanguages(raw.tvgLanguage)
        let countries = tvgCountries(raw.tvgCountry)
        guard !languages.isEmpty || !countries.isEmpty else { return hints }
        var merged = hints ?? CategoryHints(cleanName: "")
        if !languages.isEmpty { merged.languages = languages }
        if !countries.isEmpty { merged.countries = countries }
        return merged
    }

    private static func listParts(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" || $0 == "/" }).compactMap { String($0).nonEmpty }
    }

    static func tvgLanguages(_ value: String?) -> [String] {
        var out: [String] = []
        for part in listParts(value) {
            if part.count == 2, let info = WorldDirectory.language(part) {
                if !out.contains(info.code) { out.append(info.code) }
                continue
            }
            let key = TextFold.upperKey(part)
            for tag in Lexicon.entries[key]?.tags ?? [] {
                if case .locale(let loc) = tag.value {
                    for language in loc.languages where !out.contains(language) { out.append(language) }
                }
            }
            if out.isEmpty, let info = WorldDirectory.languages.first(where: { $0.name.tunaFolded == part.tunaFolded }) {
                out.append(info.code)
            }
        }
        return out
    }

    static func tvgCountries(_ value: String?) -> [String] {
        var out: [String] = []
        for part in listParts(value) where part.count == 2 {
            if let info = WorldDirectory.country(part), !out.contains(info.code) { out.append(info.code) }
        }
        return out
    }

    /// Empty names, names without letters/digits and separator rows ("##### UK SPORTS #####", "== TURKISH ==").
    static func isJunkName(_ name: String) -> Bool {
        var scalars: [Unicode.Scalar] = []
        var alphanumeric = 0
        for scalar in name.unicodeScalars where !scalar.properties.isWhitespace {
            scalars.append(scalar)
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { alphanumeric += 1 }
        }
        if alphanumeric == 0 { return true }
        let n = scalars.count
        guard n >= 5 else { return false }
        return isDecoration(scalars[0]) && isDecoration(scalars[1]) && isDecoration(scalars[n - 1]) && isDecoration(scalars[n - 2])
    }

    private static func isDecoration(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isAlphabetic || s.properties.numericType != nil { return false }
        switch s {
        case "(", ")", "[", "]", "{", "}", "'", "\"", "!", "?", ".", "+", "&", ",", ":": return false
        default: return true
        }
    }
}

extension Curator {
    /// Variant score per the contract: quality*100 + HDR 20 + world match 300 + HEVC 5 - backup 50 - CAM/TS/SCR 400
    /// - failures*80, plus `CurationRun.verifiedBonus` when playback verified at least the claimed quality.
    /// `verifiedQuality` replaces the parsed quality.
    public static func score(for parsed: ParsedName, matchesWorld: Bool, verifiedQuality: Quality? = nil,
                             failures: Int = 0) -> Int {
        let quality = verifiedQuality ?? parsed.quality
        var score = quality.rawValue * 100
        if parsed.hdr != nil { score += 20 }
        if matchesWorld { score += 300 }
        if parsed.codec == .hevc { score += 5 }
        if parsed.isBackup { score -= 50 }
        if parsed.source?.isLowGrade == true { score -= 400 }
        score -= max(0, failures) * 80
        if let verified = verifiedQuality, verified >= parsed.quality { score += CurationRun.verifiedBonus }
        return score
    }

    /// The contract's world rule for one parsed version (languages, else countries, else regions; untagged versions
    /// match unless their script implies a language outside the worlds).
    public static func matchesWorld(_ parsed: ParsedName, worlds: WorldSelection) -> Bool {
        let run = CurationRun(preferences: ContentPreferences(worlds: worlds), verifiedQualities: [:], failingVariants: [:])
        return run.publicMatchesWorld(parsed)
    }
}

extension CurationRun {
    fileprivate func publicMatchesWorld(_ parsed: ParsedName) -> Bool { matchesWorld(parsed) }
}
