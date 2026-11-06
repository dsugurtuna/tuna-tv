import Foundation

enum DemoUserStateBuilder {
    static let continueMovies = ["neon-harbor", "the-atlas-directive", "the-clockwork-fox"]
    static let continueSeries: [(seed: String, season: Int, episode: Int)] = [("the-lantern-keepers", 2, 3), ("asterly", 1, 5)]
    static let myListSeeds = ["glasswing-requiem", "saltwater-saints", "kuzey-isigi", "the-ember-throne", "death-at-the-grand-solenne",
                              "bozkir-ruzgari", "moss-and-marigold", "kingdoms-of-moss", "echo-protocol", "a-house-made-of-rain"]
    static let favoriteEPG = ["KestrelSports1.uk", "HarborNews24.uk", "AlbionOne.uk", "KanalMavi.tr"]
    static let recentEPG = ["KestrelSportsRacing.uk", "KestrelSports1.uk", "LibertyWireNews.us", "WildAtlas.uk", "PulseHits.uk", "KiteKids.uk"]

    static func userState(movies: [Title], series: [Title], channels: [Channel], now: Date) -> UserState {
        var bySeed: [String: Title] = [:]
        for title in movies + series {
            guard let spec = DemoMetadataBuilder.spec(for: title) else { continue }
            let key = "\(spec.kind.rawValue):\(spec.seed)"
            if let existing = bySeed[key], existing.placement.isShowcase || !title.placement.isShowcase { continue }
            bySeed[key] = title
        }
        func movie(_ seed: String) -> Title? { bySeed["movie:\(seed)"] }
        func show(_ seed: String) -> Title? { bySeed["series:\(seed)"] }
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var state = UserState()
        // Continue Watching: three movies and two episodes, most recent first.
        let fractions = [0.42, 0.67, 0.18]
        for (offset, seed) in continueMovies.enumerated() {
            guard let title = movie(seed), let variant = title.defaultVariant,
                  let spec = DemoMetadataBuilder.spec(for: title) else { continue }
            let duration = Double(spec.runtime * 60)
            state.progress[title.id] = WatchProgress(titleID: title.id, variantID: variant.id,
                                                     position: (duration * fractions[offset]).rounded(), duration: duration,
                                                     updatedAt: ago(Double(35 + offset * 410)))
            state.history.append(HistoryEntry(kind: .title, itemID: title.id, watchedAt: ago(Double(35 + offset * 410)),
                                              secondsWatched: (duration * fractions[offset]).rounded()))
        }
        for (offset, item) in continueSeries.enumerated() {
            guard let title = show(item.seed), let variant = title.defaultVariant,
                  let info = DemoContent.seriesInfo(for: variant.ref),
                  let episode = info.episodes.first(where: { $0.season == item.season && $0.episode == item.episode })
                    ?? info.episodes.first else { continue }
            let duration = Double(episode.durationSeconds ?? 3_000)
            let position = (duration * (offset == 0 ? 0.55 : 0.31)).rounded()
            let updated = ago(Double(160 + offset * 1_300))
            state.progress[episode.ref.id] = WatchProgress(titleID: title.id, variantID: variant.id, episodeRef: episode.ref,
                                                           season: episode.season, episode: episode.episode,
                                                           position: position, duration: duration, updatedAt: updated)
            state.history.append(HistoryEntry(kind: .title, itemID: title.id, watchedAt: updated, secondsWatched: position))
        }
        // My List: eight titles, newest first.
        var list: [String] = myListSeeds.compactMap { movie($0) ?? show($0) }.map(\.id)
        for title in movies + series where list.count < 8 && title.placement.isShowcase && !title.isAdult && !list.contains(title.id) {
            list.append(title.id)
        }
        state.myList = Array(list.prefix(8))
        // Finished titles from earlier in the month.
        for (offset, seed) in ["glasswing", "the-lisbon-ledger", "letters-to-juniper"].enumerated() {
            guard let title = movie(seed), let spec = DemoMetadataBuilder.spec(for: title) else { continue }
            state.history.append(HistoryEntry(kind: .title, itemID: title.id, watchedAt: ago(Double((offset + 2) * 2_880 + 95)),
                                              secondsWatched: Double(spec.runtime * 60)))
        }
        // Channels.
        func channel(_ epg: String) -> Channel? {
            channels.first { $0.epgChannelID == epg && $0.placement.isShowcase } ?? channels.first { $0.epgChannelID == epg }
        }
        state.favoriteChannels = favoriteEPG.compactMap { channel($0)?.id }
        state.recentChannels = recentEPG.compactMap { channel($0)?.id }
        for (offset, id) in state.recentChannels.enumerated() {
            state.history.append(HistoryEntry(kind: .channel, itemID: id, watchedAt: ago(Double(12 + offset * 240)),
                                              secondsWatched: Double(600 + offset * 420)))
        }
        state.history.sort { $0.watchedAt == $1.watchedAt ? $0.itemID < $1.itemID : $0.watchedAt > $1.watchedAt }
        // A couple of thumbs.
        if let t = movie("neon-harbor") { state.ratings[t.id] = 1 }
        if let t = movie("glasswing") { state.ratings[t.id] = 1 }
        if let t = movie("parking-lot-prophets") { state.ratings[t.id] = -1 }
        return state
    }
}
