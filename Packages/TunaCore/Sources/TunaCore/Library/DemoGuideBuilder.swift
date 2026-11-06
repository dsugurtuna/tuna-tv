import Foundation

enum DemoGuideBuilder {
    static let pastHours = 6
    static let futureHours = 30

    struct Slot {
        var title: String
        var minutes: Int
        var summary: String? = nil
        var subtitle: String? = nil
        var categories: [String] = []
        var episodeLabel: String? = nil
        var icon: String? = nil
        var isNew = false
        var isLive = false
    }

    /// Window covered by the demo guide.
    static func window(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(pastHours) * 3_600),
                     end: now.addingTimeInterval(Double(futureHours) * 3_600))
    }

    /// Programmes for every demo EPG key (plus `extraKeys` for unknown channels, scheduled as entertainment).
    static func programs(now: Date, extraKeys: [String] = []) -> [Program] {
        let window = window(now: now)
        let dayStart = floor(window.start.timeIntervalSince1970 / 86_400) * 86_400
        let anchor = Date(timeIntervalSince1970: dayStart - 6 * 3_600)
        let limit = window.end.addingTimeInterval(4 * 3_600)
        var base: [String: [Program]] = [:]
        var out: [Program] = []
        for entry in DemoLiveBuilder.guideKeys {
            let schedule: [Program]
            if let cached = base[entry.spec.epgID] {
                schedule = cached
            } else {
                schedule = channelSchedule(entry.spec, key: entry.spec.epgID, from: anchor, to: limit, now: now)
                base[entry.spec.epgID] = schedule
            }
            let shift = TimeInterval(entry.shiftHours * 3_600)
            for program in schedule {
                var p = program
                if shift != 0 {
                    p.channelKey = entry.key
                    p.start = p.start.addingTimeInterval(shift)
                    p.end = p.end.addingTimeInterval(shift)
                    p.hasArchive = false
                    p.isLive = false
                }
                if p.end > window.start && p.start < window.end { out.append(p) }
            }
        }
        let known = Set(DemoLiveBuilder.guideKeys.map(\.key))
        for key in extraKeys where !known.contains(key) {
            let generic = DemoChannelSpec(index: 0, name: key, prefix: "", group: "Entertainment", epgID: key, codes: [],
                                          catchupDays: 0, categoryID: "", seed: DemoText.slug(key))
            out += channelSchedule(generic, key: key, from: anchor, to: limit, now: now)
                .filter { $0.end > window.start && $0.start < window.end }
        }
        return out
    }

    // MARK: Schedule

    private static func halfHourFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 1_800) * 1_800)
    }

    /// Big live events pinned around `now` so the "Live Now" rails always have something to show.
    private static func pinned(_ spec: DemoChannelSpec, now: Date) -> [(start: Date, slot: Slot)] {
        let h = halfHourFloor(now)
        func at(_ minutes: Int) -> Date { h.addingTimeInterval(TimeInterval(minutes * 60)) }
        switch spec.epgID {
        case "KestrelSports1.uk":
            return [(at(-120), Slot(title: "Matchday Live", minutes: 60, summary: "Build-up, team news and analysis before kick-off at the Quayside.", categories: ["Sports"], isLive: true)),
                    (at(-60), Slot(title: "Harbor City FC vs Northbridge United", minutes: 120,
                                   summary: "Coastal League. The league leaders host their fiercest rivals in a sold-out Quayside derby.",
                                   categories: ["Sports"], isNew: true, isLive: true)),
                    (at(60), Slot(title: "The Final Whistle", minutes: 60, summary: "Reaction, goals and debate from the derby.", categories: ["Sports"]))]
        case "KestrelSportsRacing.uk":
            return [(at(-300), Slot(title: "Grand Prix of Solenne: Qualifying", minutes: 90,
                                    summary: "One flying lap decides the grid on the streets of Solenne.", categories: ["Sports", "Motorsport"])),
                    (at(-90), Slot(title: "Pit Lane Live", minutes: 60, summary: "Strategy, tyres and the grid walk before lights out.",
                                   categories: ["Sports", "Motorsport"], isLive: true)),
                    (at(-30), Slot(title: "Grand Prix of Solenne", minutes: 150,
                                   summary: "Live: sixty-two laps around the harbour circuit of Solenne, the jewel of the championship.",
                                   categories: ["Sports", "Motorsport"], isNew: true, isLive: true)),
                    (at(120), Slot(title: "Grand Prix of Solenne: Podium & Reaction", minutes: 60,
                                   summary: "The champagne, the interviews and the championship fallout.", categories: ["Sports", "Motorsport"]))]
        case "SummitSportsNetwork.us":
            return [(at(-90), Slot(title: "Bay City Comets vs Lakeport Herons", minutes: 150,
                                   summary: "Live basketball: the Comets defend a nine-game winning streak at home.",
                                   categories: ["Sports", "Basketball"], isNew: true, isLive: true))]
        case "SporArena1.tr":
            return [(at(30), Slot(title: "Maç Önü", minutes: 60, summary: "Derbi öncesi kadrolar ve son gelişmeler.", categories: ["Sports"], isLive: true)),
                    (at(90), Slot(title: "Canlı: Karadeniz Gücü - Ege Yıldızları", minutes: 120,
                                  summary: "Süper derbide iki takım zirve için karşı karşıya.", categories: ["Sports"], isNew: true, isLive: true))]
        case "NakheelSports1.ae":
            return [(at(-30), Slot(title: "Live: Al Waha FC vs Desert Falcons", minutes: 120,
                                   summary: "Gulf Cup semi-final, live from the Oasis Stadium.", categories: ["Sports"], isNew: true, isLive: true))]
        case "KestrelCinemaPremiere.uk":
            guard let film = DemoSpecs.movies.first(where: { $0.seed == "neon-harbor-undertow" }) else { return [] }
            return [(at(120), Slot(title: film.englishTitle, minutes: 150, summary: film.overview, subtitle: "Premiere",
                                   categories: ["Movie", "Premiere"], icon: "demo://backdrop/\(film.seed)", isNew: true))]
        default:
            return []
        }
    }

    private static func channelSchedule(_ spec: DemoChannelSpec, key: String, from: Date, to: Date, now: Date) -> [Program] {
        var rng = DemoRNG("guide/\(key)/\(Int(from.timeIntervalSince1970))")
        var out: [Program] = []
        var cursor = from
        func emit(_ slot: Slot, at start: Date, minutes: Int) {
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))
            out.append(Program(channelKey: key, start: start, end: end, title: slot.title, subtitle: slot.subtitle,
                               summary: slot.summary, categories: slot.categories, iconURL: slot.icon,
                               episodeLabel: slot.episodeLabel, isNew: slot.isNew, isLive: slot.isLive,
                               hasArchive: spec.catchupDays > 0 && end <= now))
        }
        func fill(until end: Date) {
            while cursor < end {
                let remaining = Int(end.timeIntervalSince(cursor) / 60)
                let slot = nextSlot(spec, at: cursor, remaining: remaining, previous: out.last?.title, rng: &rng)
                let minutes = max(1, min(slot.minutes, remaining))
                emit(slot, at: cursor, minutes: minutes)
                cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            }
        }
        for event in pinned(spec, now: now).sorted(by: { $0.start < $1.start }) where event.start >= cursor {
            fill(until: event.start)
            emit(event.slot, at: event.start, minutes: event.slot.minutes)
            cursor = event.start.addingTimeInterval(TimeInterval(event.slot.minutes * 60))
        }
        fill(until: to)
        return out
    }

    // MARK: Slot generators

    private static func localHour(_ spec: DemoChannelSpec, _ date: Date) -> Int {
        let hours = Int(floor(date.timeIntervalSince1970 / 3_600)) + spec.utcOffsetHours
        return ((hours % 24) + 24) % 24
    }

    private static func pool(_ group: String, _ language: String) -> [String] {
        DemoTables.programPools["\(group)/\(language)"] ?? DemoTables.programPools["\(group)/en"] ?? []
    }

    private static func pooled(_ group: String, _ language: String, remaining: Int, category: String,
                               previous: String? = nil, rng: inout DemoRNG) -> Slot {
        let entries = pool(group, language).map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        let fitting = entries.filter { (Int($0[1]) ?? 30) <= remaining && $0[0] != previous }
        let pickFrom = fitting.isEmpty ? entries : fitting
        guard !pickFrom.isEmpty else { return Slot(title: "Off Air", minutes: remaining) }
        let e = rng.pick(pickFrom)
        return Slot(title: e[0], minutes: Int(e[1]) ?? 30, summary: e[2], categories: [category])
    }

    private static func episodeSlot(_ series: DemoTitleSpec, rng: inout DemoRNG, isNew: Bool) -> Slot {
        let shape = DemoSeriesInfoBuilder.shape(series)
        let season = rng.int(1...shape.seasonCount)
        let episode = rng.int(1...shape.episodesPerSeason[season - 1])
        let title = DemoSeriesInfoBuilder.episodeTitle(series, season: season, episode: episode,
                                                       isFinale: episode == shape.episodesPerSeason[season - 1])
        let minutes = Int((Double(series.runtime) / 30).rounded(.up)) * 30
        return Slot(title: series.title, minutes: minutes,
                    summary: DemoSeriesInfoBuilder.plot(series, season: season, episode: episode), subtitle: title,
                    categories: [series.genres.first ?? "Series"], episodeLabel: "S\(season) E\(episode)",
                    icon: "demo://still/\(series.seed)-s\(season)e\(episode)", isNew: isNew)
    }

    private static func seriesPool(_ spec: DemoChannelSpec, documentary: Bool, kids: Bool) -> [DemoTitleSpec] {
        let wanted = spec.language
        let all = DemoSpecs.series.filter { s in
            let isDoc = s.genres.contains("Documentary")
            let isKids = s.genres.contains("Kids") || s.genres.contains("Animation")
            return isDoc == documentary && isKids == kids
        }
        let local = all.filter { $0.language == wanted }
        return local.isEmpty ? all.filter { $0.language == "en" } : local
    }

    private static func moviePool(_ spec: DemoChannelSpec) -> [DemoTitleSpec] {
        let movies = DemoSpecs.movies
        switch spec.epgID {
        case "BijouClassics.us", "RetroReels.int", "KestrelCinemaClassics.uk": return movies.filter { $0.year < 2005 }
        case "MidnightScreams.us": return movies.filter { $0.genres.contains("Horror") || $0.genres.contains("Thriller") }
        case "MaviSinema.tr": return movies.filter { $0.language == "tr" || $0.codes.contains("T") }
        case "FilmpalastTV.de": return movies.filter { $0.language == "de" || $0.codes.contains("D") }
        default: return movies.filter { $0.year >= 2005 && $0.listingLanguage == "en" }
        }
    }

    private static func nextSlot(_ spec: DemoChannelSpec, at date: Date, remaining: Int, previous: String?,
                                 rng: inout DemoRNG) -> Slot {
        let hour = localHour(spec, date)
        let onTheHour = Int(date.timeIntervalSince1970) % 3_600 == 0
        let lang = spec.language
        switch spec.group {
        case "News":
            if onTheHour {
                if (6...8).contains(hour) && remaining >= 60 && lang == "en" {
                    return Slot(title: "First Light", minutes: 60, summary: "News, weather and conversation to start the day.",
                                categories: ["News"], isLive: true)
                }
                let title: String
                switch lang {
                case "tr": title = (19...20).contains(hour) ? "Ana Haber" : "Haber Saati"
                case "de": title = "Nachrichten"
                case "ar": title = "نشرة الأخبار"
                case "fr": title = "Le Journal"
                default: title = hour < 6 ? "Overnight News" : hour < 12 ? "Morning Headlines" : hour < 18 ? "The Afternoon Report" : "World Tonight"
                }
                return Slot(title: title, minutes: 30, summary: "The latest headlines, live from the \(spec.name) newsroom.",
                            categories: ["News"], isLive: true)
            }
            return pooled("News", lang, remaining: remaining, category: "News", previous: previous, rng: &rng)
        case "Sports":
            if onTheHour && hour == 19 && remaining >= 120 {
                return match(spec, rng: &rng)
            }
            return pooled("Sports", lang, remaining: remaining, category: "Sports", previous: previous, rng: &rng)
        case "Movies":
            let film = rng.pick(moviePool(spec).isEmpty ? DemoSpecs.movies : moviePool(spec))
            let minutes = Int((Double(film.runtime) / 30).rounded(.up)) * 30
            if minutes > remaining {
                return Slot(title: "Trailer Park", minutes: 30, summary: "The best new trailers and behind-the-scenes clips.",
                            categories: ["Movie"])
            }
            return Slot(title: lang == "en" ? film.englishTitle : film.title, minutes: minutes, summary: film.overview,
                        subtitle: "\(film.year)", categories: ["Movie"] + film.genres.prefix(1),
                        icon: "demo://backdrop/\(film.seed)", isNew: rng.chance(0.1))
        case "Kids":
            if !(6...19).contains(hour) {
                return Slot(title: lang == "tr" ? "Uyku Masalları" : "Bedtime Stories", minutes: min(60, remaining),
                            summary: "Gentle stories and lullabies for little ones.", categories: ["Kids"])
            }
            let shows = seriesPool(spec, documentary: false, kids: true)
            if lang == "en" && !shows.isEmpty && rng.chance(0.4) && remaining >= 30 {
                var slot = episodeSlot(rng.pick(shows), rng: &rng, isNew: false)
                slot.minutes = 30
                slot.categories = ["Kids"]
                return slot
            }
            return pooled("Kids", lang, remaining: remaining, category: "Kids", previous: previous, rng: &rng)
        case "Documentary":
            let docs = seriesPool(spec, documentary: true, kids: false)
            if lang == "en" && !docs.isEmpty && rng.chance(0.35) && remaining >= 60 {
                var slot = episodeSlot(rng.pick(docs), rng: &rng, isNew: hour >= 20)
                slot.minutes = 60
                slot.categories = ["Documentary"]
                return slot
            }
            var slot = pooled("Documentary", lang, remaining: remaining, category: "Documentary", previous: previous, rng: &rng)
            slot.episodeLabel = "S\(rng.int(1...4)) E\(rng.int(1...8))"
            return slot
        case "Music":
            if onTheHour && hour == 18 && remaining >= 120 {
                return Slot(title: lang == "tr" ? "Ritim Top 40" : "Top 40 Countdown", minutes: 120,
                            summary: "The forty biggest songs of the week, counted down.", categories: ["Music"], isNew: true)
            }
            return pooled("Music", lang, remaining: remaining, category: "Music", previous: previous, rng: &rng)
        default:
            let drama = seriesPool(spec, documentary: false, kids: false)
            if onTheHour && (7...9).contains(hour) && remaining >= 60 {
                let morning: (String, String)
                switch lang {
                case "tr": morning = ("Sabah Kahvesi", "Güne keyifli bir başlangıç: haberler, sohbet ve müzik.")
                case "de": morning = ("Guten Morgen Rhein", "Das Frühstücksfernsehen mit Nachrichten, Wetter und Gästen.")
                case "ar": morning = ("صباح الواحة", "برنامج صباحي منوع.")
                case "fr": morning = ("Bonjour Brume", "La matinale : actualité, météo et invités.")
                default: morning = ("\(spec.name) Breakfast", "News, weather, guests and good company to start the day.")
                }
                return Slot(title: morning.0, minutes: 60, summary: morning.1, categories: ["Entertainment"], isLive: true)
            }
            if !drama.isEmpty && remaining >= 60 && ((20...22).contains(hour) || rng.chance(0.35)) {
                let slot = episodeSlot(rng.pick(drama), rng: &rng, isNew: (20...22).contains(hour))
                if slot.minutes <= remaining { return slot }
            }
            return pooled("Entertainment", lang, remaining: remaining, category: "Entertainment", previous: previous, rng: &rng)
        }
    }

    private static func match(_ spec: DemoChannelSpec, rng: inout DemoRNG) -> Slot {
        switch spec.language {
        case "tr":
            let clubs = ["Karadeniz Gücü", "Ege Yıldızları", "Bozkır Spor", "Marmara Kartalları", "Toros Gençlik", "Kapadokya FK"]
            let pair = rng.sample(clubs, count: 2)
            return Slot(title: "Canlı: \(pair[0]) - \(pair[1])", minutes: 120, summary: "Ligde haftanın maçı.",
                        categories: ["Sports"], isLive: true)
        case "de":
            let clubs = ["FC Rheinfels", "SV Nordheide", "TSV Alpenland", "Union Elbtal"]
            let pair = rng.sample(clubs, count: 2)
            return Slot(title: "Live: \(pair[0]) vs \(pair[1])", minutes: 120, summary: "Das Topspiel des Spieltags.",
                        categories: ["Sports"], isLive: true)
        case "ar":
            return Slot(title: "Live: Desert Falcons vs Gulf Mariners", minutes: 120, summary: "Gulf Cup, live.",
                        categories: ["Sports"], isLive: true)
        default:
            if spec.prefix == "US" {
                let teams = ["Bay City Comets", "Lakeport Herons", "Mesa Thunderbirds", "Riverside Foxes", "Granite Peak Owls"]
                let pair = rng.sample(teams, count: 2)
                return Slot(title: "\(pair[0]) vs \(pair[1])", minutes: 150, summary: "Prime-time basketball, live.",
                            categories: ["Sports", "Basketball"], isLive: true)
            }
            let clubs = ["Harbor City FC", "Northbridge United", "Ravenshaw Town", "Calder Vale FC", "Westmoor Albion",
                         "Saltmarsh Rangers", "Elmstead City", "Kingsferry Athletic"]
            let pair = rng.sample(clubs, count: 2)
            return Slot(title: "\(pair[0]) vs \(pair[1])", minutes: 120, summary: "Coastal League, live from \(pair[0])'s home ground.",
                        categories: ["Sports"], isLive: true)
        }
    }
}
