import XCTest
@testable import TunaCore

final class DemoContentTests: XCTestCase {
    /// 2026-11-06T14:23:00Z
    let now = Date(timeIntervalSince1970: 1_793_974_980)

    // MARK: Helpers

    /// A hand-made curated catalog (no Curator needed): variants grouped by TMDB id / name, channels by EPG id.
    func handCurated(_ catalog: ProviderCatalog) -> CuratedCatalog {
        func parsed(_ item: RawItem) -> ParsedName { ParsedName(original: item.name, title: item.name, key: item.name.lowercased()) }
        func titles(_ kind: StreamKind) -> [Title] {
            var groups: [String: [RawItem]] = [:]
            var order: [String] = []
            for item in catalog.items(of: kind) {
                let key = item.tmdbID.map(String.init) ?? DemoText.slug(item.name)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(item)
            }
            return order.map { key in
                let items = groups[key] ?? []
                let spec = DemoSpecs.byTMDBID[Int(key) ?? -1]
                let name = spec?.title ?? items[0].name
                let titleKind: TitleKind = kind == .movie ? .movie : .series
                let id = kind == .movie ? "movie:\(DemoText.slug(name)):\(spec?.year ?? 0)" : "series:\(DemoText.slug(name))"
                let variants = items.map { Variant(raw: $0, parsed: parsed($0), matchesWorld: true, score: 0) }
                return Title(id: id, kind: titleKind, name: name, year: spec?.year, variants: variants,
                             placement: items[0].categoryName == "XXX | Adult" ? .vault(.adult) : .showcase,
                             bestQuality: .fhd, isAdult: items[0].categoryName == "XXX | Adult")
            }
        }
        var channels: [String: [RawItem]] = [:]
        for item in catalog.items(of: .live) { channels[item.epgChannelID ?? item.name, default: []].append(item) }
        let channelList = channels.keys.sorted().map { key in
            Channel(id: "live:\(key)", name: key,
                    variants: (channels[key] ?? []).map { Variant(raw: $0, parsed: parsed($0), matchesWorld: true, score: 0) },
                    epgChannelID: key, placement: .showcase, bestQuality: .fhd)
        }
        return CuratedCatalog(movies: titles(.movie), series: titles(.series), channels: channelList)
    }

    // MARK: Catalog

    func testCatalogIsDeterministic() throws {
        let a = DemoContent.catalog(now: now)
        let b = DemoContent.catalog(now: now)
        XCTAssertEqual(a.items, b.items)
        XCTAssertEqual(a.categories, b.categories)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b))
    }

    func testCatalogCounts() {
        let catalog = DemoContent.catalog(now: now)
        XCTAssertEqual(catalog.providerID, DemoContent.providerID)
        XCTAssertTrue((380...470).contains(catalog.items.count), "items: \(catalog.items.count)")
        let movies = catalog.items(of: .movie)
        let movieIDs = Set(movies.compactMap(\.tmdbID))
        XCTAssertTrue((100...120).contains(DemoSpecs.movies.count))
        XCTAssertTrue((95...120).contains(movieIDs.count), "distinct movie tmdb ids: \(movieIDs.count)")
        XCTAssertTrue((36...50).contains(catalog.items(of: .series).count))
        XCTAssertTrue((30...40).contains(DemoSpecs.series.count))
        let liveKeys = Set(catalog.items(of: .live).compactMap(\.epgChannelID))
        XCTAssertTrue((60...80).contains(liveKeys.count), "channels: \(liveKeys.count)")
        let fourK = DemoSpecs.movies.filter { $0.codes.contains("U") || $0.codes.contains("R") }.count
        XCTAssertTrue(Double(fourK) / Double(DemoSpecs.movies.count) > 0.28)
        for spec in DemoSpecs.movies { XCTAssertTrue((1...4).contains(spec.codes.count), spec.title) }
        // Ids are unique; categories referenced exist.
        XCTAssertEqual(Set(catalog.items.map(\.id)).count, catalog.items.count)
        let categoryIDs = Set(catalog.categories.map(\.id))
        for item in catalog.items { XCTAssertTrue(categoryIDs.contains(item.categoryID ?? ""), item.name) }
    }

    func testTagVariety() {
        let names = DemoContent.catalog(now: now).items.map(\.name)
        func has(_ fragment: String) -> Bool { names.contains { $0.contains(fragment) } }
        for fragment in ["4K", "FHD", "BluRay", "CAM", "|TR|", "TR: ", "Türkçe Dublaj", "(Backup)", "+1", "UK: ", "US: ", "DE",
                         "AR", "EN| ", "EN - ", "HDR", "SD", "Kuzey Işığı", "Bozkır Rüzgârı"] {
            XCTAssertTrue(has(fragment), "missing \(fragment)")
        }
        XCTAssertTrue(names.contains("EN| Neon Harbor (2024) 4K HDR") || has("Neon Harbor (2024)"))
        XCTAssertTrue(names.contains("TR: Bozkır Rüzgârı"))
        XCTAssertTrue(names.contains { DemoText.hasArabicScript($0) })
        let adult = DemoContent.catalog(now: now).items.filter { $0.categoryName == "XXX | Adult" }
        XCTAssertEqual(adult.count, 3)
    }

    func testEveryItemHasSeedURLAndSensibleFields() {
        let catalog = DemoContent.catalog(now: now)
        let earliest = now.addingTimeInterval(-121 * 86_400)
        for item in catalog.items {
            let icon = item.iconURL ?? ""
            let expected = item.ref.kind == .live ? "demo://channel/" : "demo://poster/"
            XCTAssertTrue(icon.hasPrefix(expected), item.name)
            XCTAssertFalse(icon.dropFirst(expected.count).isEmpty, item.name)
            if item.ref.kind == .live {
                XCTAssertNotNil(item.epgChannelID, item.name)
            } else {
                let added = item.addedAt ?? .distantPast
                XCTAssertTrue(added >= earliest && added <= now, item.name)
            }
        }
        // Variants of one movie share tmdb id and seed.
        let neon = catalog.items(of: .movie).filter { DemoCatalogBuilder.spec(forStreamID: $0.ref.streamID)?.seed == "neon-harbor" }
        XCTAssertEqual(neon.count, 4)
        XCTAssertEqual(Set(neon.map(\.iconURL)).count, 1)
        XCTAssertTrue(catalog.items(of: .live).contains { ($0.catchupDays ?? 0) > 0 })
        let seeds = DemoSpecs.all.map { "\($0.kind.rawValue):\($0.seed)" }
        XCTAssertEqual(Set(seeds).count, seeds.count)
        XCTAssertTrue(DemoSpecs.all.allSatisfy { !$0.seed.isEmpty && $0.year >= 1985 && $0.year <= 2026 })
    }

    // MARK: Series

    func testSeriesInfoEpisodesOrdered() throws {
        let catalog = DemoContent.catalog(now: now)
        for item in catalog.items(of: .series) {
            let info = try XCTUnwrap(DemoContent.seriesInfo(for: item.ref), item.name)
            XCTAssertTrue((2...5).contains(info.seasons.count), item.name)
            var previous = (0, 0)
            for episode in info.episodes {
                XCTAssertTrue((episode.season, episode.episode) > previous, item.name)
                previous = (episode.season, episode.episode)
                XCTAssertEqual(episode.ref.kind, .episode)
                XCTAssertEqual(episode.ref.providerID, DemoContent.providerID)
                XCTAssertEqual(episode.containerExtension, "mkv")
                XCTAssertTrue(episode.stillURL?.hasPrefix("demo://still/") == true)
                XCTAssertTrue(episode.stillURL?.hasSuffix("-s\(episode.season)e\(episode.episode)") == true)
            }
            for season in info.episodesBySeason { XCTAssertTrue((6...10).contains(season.episodes.count)) }
            XCTAssertEqual(Set(info.episodes.map(\.ref.id)).count, info.episodes.count)
            XCTAssertEqual(info, DemoContent.seriesInfo(for: item.ref))
        }
        XCTAssertNil(DemoContent.seriesInfo(for: StreamRef(providerID: "other", kind: .series, streamID: "200000")))
        XCTAssertNil(DemoContent.seriesInfo(for: catalog.items(of: .movie)[0].ref))
    }

    // MARK: Guide

    func testGuideCoversWindow() {
        let programs = DemoGuideBuilder.programs(now: now)
        XCTAssertEqual(programs, DemoGuideBuilder.programs(now: now))
        let window = DemoGuideBuilder.window(now: now)
        let byKey = Dictionary(grouping: programs, by: \.channelKey)
        let epgIDs = Set(DemoContent.catalog(now: now).items(of: .live).compactMap(\.epgChannelID))
        XCTAssertEqual(Set(byKey.keys), epgIDs)
        for (key, list) in byKey {
            let sorted = list.sorted { $0.start < $1.start }
            XCTAssertLessThanOrEqual(sorted.first!.start, window.start, key)
            XCTAssertGreaterThanOrEqual(sorted.last!.end, window.end, key)
            for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(a.end, b.start, "gap/overlap on \(key)") }
            XCTAssertTrue(sorted.allSatisfy { $0.end > $0.start && !$0.title.isEmpty })
        }
        let liveNow = programs.filter { $0.contains(now) && $0.isLive && $0.categories.contains("Sports") }
        XCTAssertTrue(liveNow.contains { $0.title == "Harbor City FC vs Northbridge United" })
        XCTAssertTrue(liveNow.contains { $0.title == "Grand Prix of Solenne" })
        XCTAssertTrue(programs.contains { $0.hasArchive && $0.end <= now })
        XCTAssertFalse(programs.contains { $0.hasArchive && $0.end > now })
    }

    // MARK: Metadata, user state, people

    func testMetadataForEveryTitle() throws {
        let library = Library(catalog: handCurated(DemoContent.catalog(now: now)), generatedAt: now)
        let metadata = DemoContent.metadata(for: library)
        XCTAssertEqual(metadata, DemoContent.metadata(for: library))
        for title in library.movies + library.series {
            let m = try XCTUnwrap(metadata[title.id], title.name)
            XCTAssertEqual(m.source, .demo)
            XCTAssertNotNil(m.tmdbID)
            if title.isAdult { continue }
            XCTAssertTrue((8...12).contains(m.cast.count), title.name)
            XCTAssertTrue((5.8...8.9).contains(m.voteAverage ?? 0), title.name)
            XCTAssertTrue((300...40_000).contains(m.voteCount ?? 0), title.name)
            XCTAssertTrue((1...3).contains(m.studios.count), title.name)
            XCTAssertEqual(Set(m.crew.map(\.job)), ["Director", "Screenplay", "Original Music Composer", "Director of Photography"])
            XCTAssertTrue(m.posterURL?.hasPrefix("demo://poster/") == true)
            XCTAssertTrue(m.logoURL?.hasPrefix("demo://logo/") == true)
            XCTAssertTrue(m.trailers.first?.youtubeKey.hasPrefix("demo-") == true)
            XCTAssertFalse(m.recommendationIDs.isEmpty)
            XCTAssertNotNil(m.overview)
            XCTAssertNotNil(m.tagline)
            if title.kind == .series {
                let info = try XCTUnwrap(DemoContent.seriesInfo(for: title.variants[0].ref))
                XCTAssertEqual(m.seasonCount, info.seasons.count)
                XCTAssertEqual(m.episodeCount, info.episodes.count)
                XCTAssertNotNil(m.firstAirDate)
            } else {
                XCTAssertNotNil(m.runtimeMinutes)
            }
        }
        let all = Array(metadata.values)
        XCTAssertTrue(all.contains { ($0.voteAverage ?? 0) >= 7.8 && ($0.voteCount ?? .max) < 1_500 }, "hidden gems")
        let collections = Dictionary(grouping: all.compactMap(\.collection), by: \.id)
        XCTAssertGreaterThanOrEqual(collections.count, 3)
        XCTAssertTrue(collections.values.allSatisfy { (2...4).contains($0.count) })
        let ids = Set(all.compactMap(\.tmdbID))
        XCTAssertTrue(all.flatMap(\.recommendationIDs).allSatisfy { ids.contains($0) })
    }

    func testPersonDetails() throws {
        let metadata = DemoMetadataBuilder.metadata(DemoSpecs.movies[0])
        let lead = try XCTUnwrap(metadata.cast.first)
        XCTAssertTrue((800_001...809_999).contains(lead.personID))
        XCTAssertEqual(lead.character, "Ines Calloway")
        let person = try XCTUnwrap(DemoContent.person(id: lead.personID))
        XCTAssertEqual(person.name, lead.name)
        XCTAssertTrue(person.movieCredits.contains(metadata.tmdbID ?? -1))
        XCTAssertNotNil(person.biography)
        XCTAssertNotNil(person.birthday)
        XCTAssertTrue(person.profileURL?.hasPrefix("demo://person/") == true)
        XCTAssertEqual(person, DemoContent.person(id: lead.personID))
        XCTAssertNil(DemoContent.person(id: 42))
        XCTAssertEqual(Set(DemoPeople.all.map(\.name)).count, DemoPeople.all.count)
        // Sequels share their lead.
        let sequel = DemoMetadataBuilder.metadata(DemoSpecs.movies[1])
        XCTAssertEqual(sequel.cast.first?.personID, lead.personID)
        XCTAssertEqual(sequel.collection?.id, metadata.collection?.id)
    }

    func testUserStateAndAccount() {
        let library = Library(catalog: handCurated(DemoContent.catalog(now: now)), generatedAt: now)
        let state = DemoContent.userState(for: library, now: now)
        XCTAssertEqual(state, DemoContent.userState(for: library, now: now))
        let continuing = state.continueWatching
        XCTAssertEqual(continuing.count, 5)
        XCTAssertEqual(continuing.filter { $0.episodeRef != nil }.count, 2)
        XCTAssertTrue(continuing.allSatisfy { $0.updatedAt < now && $0.updatedAt > now.addingTimeInterval(-3 * 86_400) })
        XCTAssertEqual(state.myList.count, 8)
        XCTAssertTrue(state.myList.allSatisfy { library.movies.map(\.id).contains($0) || library.series.map(\.id).contains($0) })
        XCTAssertFalse(state.history.isEmpty)
        XCTAssertFalse(state.favoriteChannels.isEmpty)
        XCTAssertFalse(state.recentChannels.isEmpty)
        XCTAssertGreaterThanOrEqual(state.ratings.count, 2)

        let account = DemoContent.account(now: now)
        XCTAssertTrue(account.isAuthorized)
        XCTAssertEqual(account.status, "Active")
        XCTAssertEqual(account.expiresAt, now.addingTimeInterval(180 * 86_400))
        XCTAssertEqual(account.createdAt, now.addingTimeInterval(-400 * 86_400))
        XCTAssertEqual(account.maxConnections, 1)
        XCTAssertEqual(account.activeConnections, 0)
        XCTAssertEqual(account.allowedOutputFormats, ["m3u8", "ts"])

        let config = DemoContent.providerConfig()
        XCTAssertEqual(config.id, DemoContent.providerID)
        XCTAssertEqual(config.name, "Tuna Demo")
        XCTAssertEqual(config.serverURL, "demo://tuna")
        XCTAssertEqual(config.username, "demo")
        XCTAssertEqual(config.kind, .xtream)
        XCTAssertEqual(config, DemoContent.providerConfig())
    }

    func testSlugs() {
        XCTAssertEqual(DemoText.slug("Kuzey Işığı"), "kuzey-isigi")
        XCTAssertEqual(DemoText.slug("Neon Harbor: Undertow"), "neon-harbor-undertow")
        XCTAssertEqual(DemoText.slug("Albion One +1"), "albion-one-plus-1")
        XCTAssertEqual(DemoText.slug("Moss & Marigold"), "moss-and-marigold")
        XCTAssertEqual(DemoCalendar.string(days: DemoCalendar.days(year: 2024, month: 2, day: 29)), "2024-02-29")
        XCTAssertEqual(DemoClock.reference.timeIntervalSince1970, Double(DemoCalendar.days(year: 2026, month: 10, day: 1) * 86_400))
    }
}
