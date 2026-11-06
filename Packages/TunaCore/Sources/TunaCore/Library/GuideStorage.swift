import Foundation

/// Programme storage behind `Guide` (owner: Library): one start-sorted lane per channel key plus a running maximum
/// of end times, so now/next/interval queries are binary searches even when programmes overlap.
final class GuideStorage: @unchecked Sendable {
    private struct Lane {
        let programs: [Program]
        /// maxEnd[i] = latest end among programs[0...i] (non-decreasing).
        let maxEnd: [Date]
    }

    private let lanes: [String: Lane]
    let channelKeys: Set<String>
    /// Every programme, channel keys sorted, each lane by start.
    let allPrograms: [Program]

    init(programs: [Program]) {
        var latest: [String: Int] = [:]
        latest.reserveCapacity(programs.count)
        for (index, program) in programs.enumerated() { latest[program.id] = index }
        var grouped: [String: [Program]] = [:]
        for (index, program) in programs.enumerated() where latest[program.id] == index {
            grouped[program.channelKey, default: []].append(program)
        }
        var lanes: [String: Lane] = [:]
        var all: [Program] = []
        all.reserveCapacity(latest.count)
        for key in grouped.keys.sorted() {
            let sorted = (grouped[key] ?? []).sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                if a.end != b.end { return a.end < b.end }
                return a.title < b.title
            }
            var maxEnd: [Date] = []
            maxEnd.reserveCapacity(sorted.count)
            var running = Date.distantPast
            for program in sorted {
                if program.end > running { running = program.end }
                maxEnd.append(running)
            }
            lanes[key] = Lane(programs: sorted, maxEnd: maxEnd)
            all.append(contentsOf: sorted)
        }
        self.lanes = lanes
        self.channelKeys = Set(lanes.keys)
        self.allPrograms = all
    }

    func now(_ key: String, at date: Date) -> Program? {
        guard let lane = lanes[key] else { return nil }
        var index = firstStart(after: date, in: lane) - 1
        while index >= 0 && lane.maxEnd[index] > date {
            let program = lane.programs[index]
            if program.end > date { return program }
            index -= 1
        }
        return nil
    }

    func next(_ key: String, after date: Date) -> Program? {
        guard let lane = lanes[key] else { return nil }
        let index = firstStart(after: date, in: lane)
        return index < lane.programs.count ? lane.programs[index] : nil
    }

    func programs(_ key: String, in interval: DateInterval) -> [Program] {
        guard let lane = lanes[key] else { return [] }
        var lo = 0, hi = lane.programs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lane.maxEnd[mid] > interval.start { hi = mid } else { lo = mid + 1 }
        }
        // A zero-length interval asks "what airs at this instant".
        let instant = interval.duration <= 0
        var out: [Program] = []
        var index = lo
        while index < lane.programs.count {
            let program = lane.programs[index]
            if instant ? program.start > interval.start : program.start >= interval.end { break }
            if instant ? program.contains(interval.start) : program.end > interval.start { out.append(program) }
            index += 1
        }
        return out
    }

    /// The programme on `channel` at `date`, by `epgChannelID`, then `iptvOrgID`.
    func current(for channel: Channel, at date: Date) -> Program? {
        for key in [channel.epgChannelID, channel.iptvOrgID] {
            guard let key = key?.nonEmpty, let program = now(key, at: date) else { continue }
            return program
        }
        return nil
    }

    func liveEvents(at date: Date, channels: [Channel]) -> [(channel: Channel, program: Program)] {
        var found: [(channel: Channel, program: Program, sports: Bool, order: Int)] = []
        var seen = Set<String>()
        for (order, channel) in channels.enumerated() where seen.insert(channel.id).inserted {
            guard let program = current(for: channel, at: date), LiveEventRules.isLiveEvent(program) else { continue }
            found.append((channel, program, LiveEventRules.sportsKind(program) != nil, order))
        }
        found.sort { a, b in
            if a.sports != b.sports { return a.sports }
            if a.program.start != b.program.start { return a.program.start < b.program.start }
            return a.order < b.order
        }
        return found.map { (channel: $0.channel, program: $0.program) }
    }

    /// Index of the first programme starting strictly after `date`.
    private func firstStart(after date: Date, in lane: Lane) -> Int {
        var lo = 0, hi = lane.programs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lane.programs[mid].start <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Live events

/// Heuristics behind `LiveEventDetector` (owner: Library). Phrases are matched on folded word sequences, so
/// "Süper Lig", "SUPER LIG" and "super-lig" all match "super lig".
enum LiveEventRules {
    static let sportsKinds: [(name: String, phrases: [String])] = [
        ("American Football", ["nfl", "american football", "super bowl", "college football", "ncaa football"]),
        ("Basketball", ["nba", "wnba", "euroleague", "eurobasket", "basketball", "ncaa basketball"]),
        ("Ice Hockey", ["nhl", "ice hockey", "khl", "hockey"]),
        ("Baseball", ["mlb", "baseball", "world series"]),
        ("Motorsport", ["f1", "formula 1", "formula one", "grand prix", "motogp", "moto gp", "nascar", "indycar",
                        "superbike", "superbikes", "wrc", "rally", "motorsport", "motorsports"]),
        ("Tennis", ["atp", "wta", "tennis", "wimbledon", "roland garros", "davis cup"]),
        ("Fighting", ["ufc", "boxing", "mma", "bellator", "kickboxing", "wrestling", "wwe", "fight night"]),
        ("Football", ["premier league", "la liga", "laliga", "serie a", "bundesliga", "ligue 1", "super lig",
                      "champions league", "europa league", "conference league", "eredivisie", "primeira liga",
                      "fa cup", "efl", "carabao cup", "copa del rey", "dfb pokal", "coppa italia", "world cup", "uefa",
                      "fifa", "mls", "football", "soccer", "derby", "el clasico"]),
    ]

    /// League and event names that make a programme a live event on their own.
    static let eventPhrases: [String] = [
        "premier league", "la liga", "laliga", "serie a", "bundesliga", "ligue 1", "super lig", "champions league",
        "europa league", "conference league", "nba", "nfl", "nhl", "mlb", "f1", "formula 1", "formula one", "motogp",
        "atp", "wta", "euroleague", "eredivisie", "fa cup", "copa del rey", "super bowl", "world cup",
        "grand prix", "derby", "ufc", "boxing", "el clasico", "playoffs", "playoff",
    ]
    static let finalPhrases: [String] = ["final", "finals", "semifinal", "semifinals", "quarterfinal", "quarterfinals"]
    /// Recaps and magazines are not live, unless explicitly marked so.
    static let recapPhrases: [String] = ["highlights", "review", "magazine", "classics", "classic match", "rewind",
                                         "best of", "preview", "replay", "repeat", "documentary"]
    /// Categories where a "Final" in the title is a story, not a match.
    static let storyCategories: Set<String> = ["movie", "movies", "film", "films", "series", "drama", "comedy",
                                                "documentary", "kids", "children", "animation", "soap", "sitcom"]

    private static let kindMatcher = PhraseMatcher(sportsKinds.enumerated().flatMap { index, kind in kind.phrases.map { ($0, index) } })
    private static let eventMatcher = PhraseMatcher(eventPhrases.map { ($0, 0) })
    private static let finalMatcher = PhraseMatcher(finalPhrases.map { ($0, 0) })
    private static let recapMatcher = PhraseMatcher(recapPhrases.map { ($0, 0) })

    static func isLiveEvent(_ program: Program) -> Bool {
        if program.isLive || hasLiveMarker(program.title) { return true }
        let text = program.subtitle.map { program.title + " " + $0 } ?? program.title
        let words = TextTokens.words(text)
        if recapMatcher.firstMatch(in: words) != nil { return false }
        let lower = " " + text.lowercased() + " "
        if lower.contains(" vs ") || lower.contains(" vs. ") || lower.contains(" v ") { return true }
        if eventMatcher.firstMatch(in: words) != nil { return true }
        if finalMatcher.firstMatch(in: words) != nil {
            let categoryWords = Set(program.categories.flatMap { TextTokens.words($0) })
            return categoryWords.isDisjoint(with: storyCategories)
        }
        return false
    }

    static func sportsKind(_ program: Program) -> String? {
        let text = program.subtitle.map { program.title + " " + $0 } ?? program.title
        if let index = kindMatcher.firstMatch(in: TextTokens.words(text)) { return sportsKinds[index].name }
        let categoryWords = program.categories.flatMap { TextTokens.words($0) + ["|"] }
        if let index = kindMatcher.firstMatch(in: categoryWords) { return sportsKinds[index].name }
        return nil
    }

    /// "LIVE" (as an uppercase word), "Live:", "🔴", "(L)", "(Live)", "[Live]".
    static func hasLiveMarker(_ title: String) -> Bool {
        if title.contains("🔴") || title.contains("Live:") || title.contains("LIVE:") || title.contains("(L)") { return true }
        let lower = title.lowercased()
        if lower.contains("(live)") || lower.contains("[live]") { return true }
        var word = ""
        for scalar in title.unicodeScalars {
            if scalar.properties.isAlphabetic {
                word.unicodeScalars.append(scalar)
            } else {
                if word == "LIVE" { return true }
                word = ""
            }
        }
        return word == "LIVE"
    }
}

/// Finds known multi-word phrases in a word sequence; returns the smallest value among matches.
struct PhraseMatcher: Sendable {
    private let byFirstWord: [String: [(words: [String], value: Int)]]

    init(_ phrases: [(String, Int)]) {
        var map: [String: [(words: [String], value: Int)]] = [:]
        for (phrase, value) in phrases {
            let words = TextTokens.words(phrase)
            guard let first = words.first else { continue }
            map[first, default: []].append((words, value))
        }
        byFirstWord = map
    }

    func firstMatch(in words: [String]) -> Int? {
        var best: Int?
        for (position, word) in words.enumerated() {
            guard let candidates = byFirstWord[word] else { continue }
            for candidate in candidates where best == nil || candidate.value < best! {
                guard position + candidate.words.count <= words.count else { continue }
                var matches = true
                for offset in 1..<max(1, candidate.words.count) where words[position + offset] != candidate.words[offset] {
                    matches = false
                    break
                }
                if matches { best = candidate.value }
            }
        }
        return best
    }
}
