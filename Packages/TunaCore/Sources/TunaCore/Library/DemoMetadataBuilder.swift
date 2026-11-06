import Foundation

enum DemoMetadataBuilder {
    /// Finds the demo spec behind a curated title: provider TMDB id, variant TMDB ids, stream ids, then the name.
    static func spec(for title: Title) -> DemoTitleSpec? {
        if let id = title.providerTMDBID, let spec = DemoSpecs.byTMDBID[id], spec.kind == title.kind { return spec }
        for variant in title.variants {
            if let id = variant.raw.tmdbID, let spec = DemoSpecs.byTMDBID[id], spec.kind == title.kind { return spec }
            if variant.raw.ref.providerID == DemoContent.providerID,
               let spec = DemoCatalogBuilder.spec(forStreamID: variant.raw.ref.streamID), spec.kind == title.kind { return spec }
        }
        return DemoSpecs.byFoldedName["\(title.kind.rawValue):\(DemoText.slug(title.name))"]
    }

    static func metadata(for titles: [Title]) -> [String: MediaMetadata] {
        var out: [String: MediaMetadata] = [:]
        for title in titles {
            if let spec = spec(for: title) {
                out[title.id] = metadata(spec)
            } else {
                out[title.id] = placeholder(for: title)
            }
        }
        return out
    }

    /// Neutral metadata for titles that are not in the tables (the adult placeholders, unknown items).
    static func placeholder(for title: Title) -> MediaMetadata {
        let seed = DemoText.slug(title.name).nonEmpty ?? "untitled"
        let id = 909_000 + Int(DemoHash.fnv1a(title.id) % 999)
        return MediaMetadata(kind: title.kind, source: .demo, title: title.name, tmdbID: id,
                             overview: title.isAdult ? "A placeholder entry that demonstrates the PIN-locked Adult shelf."
                                 : "Part of the Tuna TV demo catalog.",
                             year: title.year, genres: [], certification: title.isAdult ? "18+" : nil,
                             posterURL: "demo://poster/\(seed)", backdropURL: "demo://backdrop/\(seed)",
                             fetchedAt: DemoClock.reference)
    }

    private static func company(_ entry: String, id: Int) -> Company {
        let f = entry.split(separator: "#").map(String.init)
        return Company(id: id, name: f[0], logoURL: "demo://studio/\(id)", country: f.count > 1 ? f[1] : nil)
    }

    private static func companies(_ table: [String], culture: String, count: Int, base: Int, rng: inout DemoRNG) -> [Company] {
        let indexed = table.enumerated().map { (index: $0.offset, entry: $0.element) }
        let local = indexed.filter { $0.entry.hasSuffix("#\(culture)") }
        let anglo = indexed.filter { $0.entry.hasSuffix("#anglo") }
        var picks: [(index: Int, entry: String)] = rng.sample(local.isEmpty ? anglo : local, count: 1)
        for candidate in rng.sample(anglo + local, count: count + 2) where picks.count < count {
            if !picks.contains(where: { $0.index == candidate.index }) { picks.append(candidate) }
        }
        return picks.map { company($0.entry, id: base + $0.index) }
    }

    private static func related(_ spec: DemoTitleSpec, rng: inout DemoRNG, count: Int, decadeWeight: Double) -> [Int] {
        let pool = DemoSpecs.all.filter { $0.kind == spec.kind && $0.seed != spec.seed }
        let scored: [(id: Int, score: Double)] = pool.map { other in
            let shared = Double(Set(other.genres).intersection(spec.genres).count)
            let decade = abs(other.year - spec.year) <= 8 ? decadeWeight : 0
            let language = other.language == spec.language ? 0.6 : 0
            return (other.tmdbID, shared * 2 + decade + language + rng.double(0, 1.5))
        }
        return scored.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(count).map(\.id)
    }

    static func metadata(_ spec: DemoTitleSpec) -> MediaMetadata {
        var rng = DemoRNG("metadata/\(DemoPeople.key(spec))")
        let stats = DemoStats.of(spec)
        let credits = DemoPeople.credits(for: spec)
        let isMovie = spec.kind == .movie
        let release = DemoCalendar.day(in: spec.year, rng: &rng)
        let shape = isMovie ? nil : DemoSeriesInfoBuilder.shape(spec)
        let firstDay = shape?.firstAirDay ?? release

        let cast: [CastMember] = credits.cast.enumerated().map { order, role in
            let person = DemoPeople.all[role.personIndex]
            return CastMember(personID: person.id, name: person.name, character: role.character,
                              profileURL: "demo://person/\(person.seed)", order: order)
        }
        func crew(_ index: Int, _ job: String, _ department: String) -> CrewMember {
            let person = DemoPeople.all[index]
            return CrewMember(personID: person.id, name: person.name, job: job, department: department,
                              profileURL: "demo://person/\(person.seed)")
        }
        let director = DemoPeople.all[credits.director].name
        let writer = DemoPeople.all[credits.writer].name
        let crewList = [crew(credits.director, "Director", "Directing"), crew(credits.writer, "Screenplay", "Writing"),
                        crew(credits.composer, "Original Music Composer", "Sound"),
                        crew(credits.photographer, "Director of Photography", "Camera")]

        let imdb = (min(9.6, max(4.5, stats.voteAverage + rng.double(-0.3, 0.3))) * 10).rounded() / 10
        let rt = min(100, max(18, Int((stats.voteAverage - 4.2) * 20) + rng.int(-8...8)))
        let meta = min(97, max(30, Int((stats.voteAverage - 3.6) * 15) + rng.int(-7...7)))
        let awards: String? = stats.voteAverage >= 8.0
            ? rng.pick(["Won the Silver Lantern at the Solenne Film Festival. \(rng.int(4...19)) wins & \(rng.int(10...45)) nominations.",
                        "Winner of \(rng.int(2...5)) Harborview Critics Awards. \(rng.int(8...30)) wins total.",
                        "Nominated for the Golden Tide. \(rng.int(3...12)) wins & \(rng.int(9...28)) nominations."])
            : nil
        let budget: Int? = isMovie && !spec.genres.contains("Documentary") ? rng.int(4...180) * 1_000_000 : nil
        let revenue: Int? = budget.map { Int(Double($0) * (stats.voteAverage / 7.0) * rng.double(0.6, 3.4)) }
        let collection = DemoSpecs.collection(for: spec.seed).map {
            CollectionRef(id: $0.id, name: $0.name, posterURL: "demo://poster/collection-\($0.id)",
                          backdropURL: "demo://backdrop/collection-\($0.id)")
        }
        let trailers = [Trailer(youtubeKey: "demo-\(spec.seed)", name: "Official Trailer"),
                        Trailer(youtubeKey: "demo-\(spec.seed)-teaser", name: "Teaser", type: "Teaser")]
        let spoken = Array(Set([spec.language] + (spec.language == "en" ? [] : ["en"]))).sorted()
        let studioCount = rng.int(1...3)

        return MediaMetadata(
            kind: spec.kind, source: .demo, title: spec.englishTitle, tmdbID: spec.tmdbID,
            imdbID: "tt\(9_800_000 + spec.tmdbID - 900_000)",
            originalTitle: spec.title, tagline: spec.tagline, overview: spec.overview,
            releaseDate: DemoCalendar.string(days: firstDay), year: spec.year,
            runtimeMinutes: spec.runtime, genres: spec.genres, certification: spec.certification,
            status: spec.status, voteAverage: stats.voteAverage, voteCount: stats.voteCount, popularity: stats.popularity,
            imdbRating: imdb, imdbVotes: stats.voteCount * rng.int(3...11), rottenTomatoes: rt, metacritic: meta,
            awards: awards, boxOffice: revenue.map { "$" + DemoText.grouped($0 / 3) },
            originalLanguage: spec.language, spokenLanguages: spoken, originCountries: [spec.countries.first ?? "US"],
            productionCountries: spec.countries,
            studios: companies(DemoTables.studios, culture: spec.culture, count: studioCount, base: 860_001, rng: &rng),
            networks: isMovie ? [] : companies(DemoTables.networks, culture: spec.culture, count: 1, base: 865_001, rng: &rng),
            posterURL: "demo://poster/\(spec.seed)", backdropURL: "demo://backdrop/\(spec.seed)",
            logoURL: "demo://logo/\(spec.seed)",
            backdrops: (1...rng.int(3...5)).map { $0 == 1 ? "demo://backdrop/\(spec.seed)" : "demo://backdrop/\(spec.seed)-\($0)" },
            cast: cast, crew: crewList, directors: [director], writers: Array(Set([writer, director])).sorted(),
            creators: isMovie ? [] : [writer], trailers: trailers, keywords: spec.keywords, collection: collection,
            recommendationIDs: related(spec, rng: &rng, count: 8, decadeWeight: 0.5),
            similarIDs: related(spec, rng: &rng, count: 6, decadeWeight: 1.5),
            budget: budget, revenue: revenue, homepage: nil,
            seasonCount: shape?.seasonCount, episodeCount: shape?.episodeCount,
            firstAirDate: shape.map { DemoCalendar.string(days: $0.firstAirDay) },
            lastAirDate: shape.map { DemoCalendar.string(days: $0.lastAirDay) },
            inProduction: shape.map { _ in spec.status == "Returning Series" },
            fetchedAt: DemoClock.reference)
    }

    // MARK: People

    private static let careerLines: [String: [String]] = [
        "Acting": ["began on stage in regional theatre before a breakout television role",
                   "worked as a stage manager for years before stepping in front of the camera",
                   "started out in short films that travelled to festivals around the world",
                   "made a name in independent cinema before moving into larger productions"],
        "Directing": ["began directing music videos and short documentaries",
                      "worked as an editor for a decade before directing a first feature",
                      "came to film from theatre, where early productions toured internationally"],
        "Writing": ["wrote for radio and the stage before turning to screenwriting",
                    "published two novels before adapting work for the screen",
                    "spent years in television writers' rooms before a first produced feature"],
        "Sound": ["trained as a classical pianist and scored dozens of documentaries",
                  "played in touring bands before writing music for film and television"],
        "Camera": ["started as a camera assistant on commercials and nature films",
                   "shot documentaries on four continents before moving into drama"],
    ]
    private static let roleWord: [String: String] = ["Acting": "actor", "Directing": "director", "Writing": "screenwriter",
                                                      "Sound": "composer", "Camera": "cinematographer"]
    private static let extras = ["Outside of work, %N is a keen sailor and an amateur beekeeper.",
                                 "%N lives near the coast and spends the off-season restoring an old boat.",
                                 "%N is an outspoken supporter of community cinemas and film education.",
                                 "%N splits time between two cities and a very opinionated cat.",
                                 "%N is known among colleagues for meticulous preparation and an infectious laugh."]

    static func person(id: Int) -> PersonDetails? {
        guard let person = DemoPeople.person(id: id) else { return nil }
        var rng = DemoRNG("person/\(id)")
        let credits = DemoPeople.filmography[id] ?? (movies: [], series: [])
        let titles = (credits.movies + credits.series).compactMap { DemoSpecs.byTMDBID[$0] }
            .sorted { DemoStats.of($0).popularity > DemoStats.of($1).popularity }
        let firstYear = titles.map(\.year).min() ?? 2015
        let birthYear = min(2004, firstYear - rng.int(18...34))
        let birthday = DemoCalendar.string(days: DemoCalendar.day(in: birthYear, rng: &rng))
        let known = titles.prefix(2).map(\.englishTitle)
        let role = roleWord[person.department] ?? "actor"
        var bio = "\(person.name) is \(person.demonym.isEmpty ? "a" : (person.demonym.first.map { "AEIOU".contains($0) } == true ? "an" : "a")) "
        bio += person.demonym.isEmpty ? role : "\(person.demonym) \(role)"
        bio += known.isEmpty ? "." : " best known for \(known.map { "\u{201C}\($0)\u{201D}" }.joined(separator: " and "))."
        bio += " Born in \(person.birthplace), \(person.name) \(rng.pick(careerLines[person.department] ?? careerLines["Acting"] ?? [""]))."
        bio += " " + rng.pick(extras).replacingOccurrences(of: "%N", with: person.name)
        return PersonDetails(id: id, name: person.name, biography: bio, birthday: birthday, placeOfBirth: person.birthplace,
                             knownForDepartment: person.department, profileURL: "demo://person/\(person.seed)",
                             popularity: (Double(titles.count) * 3.1 + rng.double(0.5, 12) ) * 10 / 10,
                             movieCredits: credits.movies, tvCredits: credits.series, fetchedAt: DemoClock.reference)
    }
}
