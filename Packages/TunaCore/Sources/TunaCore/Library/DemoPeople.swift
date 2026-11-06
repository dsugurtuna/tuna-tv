import Foundation

struct DemoPerson: Sendable {
    let id: Int
    let name: String
    let isFemale: Bool
    let culture: String
    /// "Acting", "Directing", "Writing", "Sound", "Camera".
    let department: String
    let birthplace: String
    let demonym: String
    var seed: String { DemoText.slug(name) }
}

struct DemoCredits: Sendable {
    struct Role: Sendable { let personIndex: Int; let character: String }
    let cast: [Role]
    let director: Int
    let writer: Int
    let composer: Int
    let photographer: Int
}

enum DemoPeople {
    static let all: [DemoPerson] = generate()

    /// Person indices grouped by culture and department.
    private static let pools: [String: [Int]] = {
        var map: [String: [Int]] = [:]
        for (i, p) in all.enumerated() { map["\(p.culture)/\(p.department)", default: []].append(i) }
        return map
    }()

    private static func pool(_ culture: String, _ department: String) -> [Int] {
        pools["\(culture)/\(department)"] ?? pools["anglo/\(department)"] ?? []
    }

    static func person(id: Int) -> DemoPerson? {
        let index = id - 800_001
        return all.indices.contains(index) ? all[index] : nil
    }

    private static func generate() -> [DemoPerson] {
        var people: [DemoPerson] = []
        var used = Set<String>()
        for culture in DemoTables.cultures {
            var rng = DemoRNG("people/\(culture.code)")
            var made = 0
            var attempts = 0
            while made < culture.population && attempts < culture.population * 20 {
                attempts += 1
                let female = rng.chance(0.5)
                let first = rng.pick(female ? culture.female : culture.male)
                let last = rng.pick(culture.surnames)
                let name = culture.familyFirst ? "\(last) \(first)" : "\(first) \(last)"
                guard used.insert(name).inserted else { continue }
                // Roughly 72% actors, the rest crew.
                let roll = Double(made) / Double(culture.population)
                let department: String
                switch roll {
                case ..<0.72: department = "Acting"
                case ..<0.82: department = "Directing"
                case ..<0.90: department = "Writing"
                case ..<0.95: department = "Sound"
                default: department = "Camera"
                }
                let place = rng.pick(culture.birthplaces).split(separator: "#").map(String.init)
                people.append(DemoPerson(id: 800_001 + people.count, name: name, isFemale: female, culture: culture.code,
                                         department: department, birthplace: place[0],
                                         demonym: place.count > 1 ? place[1] : ""))
                made += 1
            }
        }
        return people
    }

    // MARK: - Casting

    static let creditsTable: [String: DemoCredits] = {
        var map: [String: DemoCredits] = [:]
        // Collections share their leads, so cast the first member first.
        var leadsBySeed: [String: [Int]] = [:]
        for spec in DemoSpecs.all {
            let leads = DemoSpecs.collection(for: spec.seed).flatMap { leadsBySeed[$0.seeds[0]] }
            let c = cast(spec, inheritedLeads: leads)
            if spec.seed == DemoSpecs.collection(for: spec.seed)?.seeds.first {
                leadsBySeed[spec.seed] = Array(c.cast.prefix(3).map(\.personIndex))
            }
            map[key(spec)] = c
        }
        return map
    }()

    static func key(_ spec: DemoTitleSpec) -> String { "\(spec.kind.rawValue):\(spec.seed)" }

    static func credits(for spec: DemoTitleSpec) -> DemoCredits { creditsTable[key(spec)] ?? cast(spec, inheritedLeads: nil) }

    private static func cast(_ spec: DemoTitleSpec, inheritedLeads: [Int]?) -> DemoCredits {
        var rng = DemoRNG("cast/\(key(spec))")
        let home = spec.culture
        let international = ["anglo", "anglo", "anglo", "wafrica", "sasia", "es", "it", "slavic", "nordic", "ko", "zh",
                             "ar", "fr", "de", "tr", "ja", "pt"]
        func cultureForSlot() -> String {
            if home != "anglo" { return rng.chance(0.85) ? home : rng.pick(international) }
            return rng.chance(0.5) ? "anglo" : rng.pick(international)
        }
        let count = rng.int(8...12)
        let featured = (DemoTables.featuredCharacters[spec.seed] ?? []).map { entry -> (gender: Character, name: String) in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (Character(parts[0]), parts[1]) : ("X", entry)
        }
        var chosen: [Int] = inheritedLeads ?? []
        var guardCount = 0
        while chosen.count < count && guardCount < 400 {
            guardCount += 1
            let candidates = pool(cultureForSlot(), "Acting")
            guard !candidates.isEmpty else { continue }
            let pick = rng.pick(candidates)
            if chosen.contains(pick) { continue }
            if chosen.count < featured.count && guardCount < 300 {
                let wanted = featured[chosen.count].gender
                if wanted == "F" && !all[pick].isFemale { continue }
                if wanted == "M" && all[pick].isFemale { continue }
            }
            chosen.append(pick)
        }
        var characterNames = Set<String>()
        let roles: [DemoCredits.Role] = chosen.enumerated().map { offset, personIndex in
            var character = offset < featured.count ? featured[offset].name : characterName(spec, person: all[personIndex], rng: &rng)
            if !characterNames.insert(character).inserted { character += " (Young)" }
            return DemoCredits.Role(personIndex: personIndex, character: character)
        }
        func crew(_ department: String, homeBias: Double) -> Int {
            let culture = rng.chance(homeBias) ? home : rng.pick(international)
            let candidates = pool(culture, department)
            return candidates.isEmpty ? 0 : rng.pick(candidates)
        }
        let director = crew("Directing", homeBias: 0.85)
        let writer = rng.chance(0.3) ? director : crew("Writing", homeBias: 0.85)
        return DemoCredits(cast: roles, director: director, writer: writer, composer: crew("Sound", homeBias: 0.5),
                           photographer: crew("Camera", homeBias: 0.5))
    }

    private static let titlesPrefix = ["Detective ", "Dr. ", "Captain ", "Agent ", "Professor ", "Sergeant ", "Mayor ", "Inspector "]

    private static func characterName(_ spec: DemoTitleSpec, person: DemoPerson, rng: inout DemoRNG) -> String {
        let culture = DemoTables.cultures.first { $0.code == spec.culture } ?? DemoTables.cultures[0]
        let first = rng.pick(person.isFemale ? culture.female : culture.male)
        if spec.isAnimation { return "\(first) (voice)" }
        if rng.chance(0.25) { return first }
        let last = rng.pick(culture.surnames)
        let full = culture.familyFirst ? "\(last) \(first)" : "\(first) \(last)"
        return rng.chance(0.18) ? rng.pick(titlesPrefix) + full : full
    }

    /// TMDB ids each person is credited on (movies, series).
    static let filmography: [Int: (movies: [Int], series: [Int])] = {
        var map: [Int: (movies: [Int], series: [Int])] = [:]
        for spec in DemoSpecs.all {
            let c = credits(for: spec)
            var people = c.cast.map(\.personIndex)
            people += [c.director, c.writer, c.composer, c.photographer]
            for index in Set(people) {
                let id = all[index].id
                var entry = map[id] ?? (movies: [], series: [])
                if spec.kind == .movie { entry.movies.append(spec.tmdbID) } else { entry.series.append(spec.tmdbID) }
                map[id] = entry
            }
        }
        return map
    }()
}
