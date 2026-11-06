import Foundation

/// Picks the TMDB/TVMaze candidate for a curated title. Pure, unit-tested.
///
/// Score (0...1) = 0.85 × title similarity (best of title / original title, own normalization: case, diacritics,
/// punctuation, "&" → "and", leading articles, roman numerals) + year term (same year +0.15, ±1 +0.07, ±2 −0.30,
/// further −0.45, unknown 0) + a ≤ 0.03 popularity/vote-count tiebreak. Differing sequel numbers cost 30 % of the
/// similarity ("Toy Story" ≠ "Toy Story 2").
public enum TitleMatcher {
    /// 0...1 confidence. Uses normalized similarity (TitleKey), original title, year delta (±1 tolerated),
    /// popularity / vote count as tiebreak.
    public static func score(title: String, year: Int?, candidate: TMDBClient.SearchResult) -> Double {
        let query = normalize(title)
        guard !query.isEmpty else { return 0 }
        var similarity = self.similarity(query, normalize(candidate.title))
        if let original = candidate.originalTitle {
            similarity = max(similarity, self.similarity(query, normalize(original)))
        }
        var score = similarity * 0.85
        if let year, let candidateYear = candidate.year {
            switch abs(year - candidateYear) {
            case 0: score += 0.15
            case 1: score += 0.07
            case 2: score -= 0.30
            default: score -= 0.45
            }
        }
        let votes = Double(max(0, candidate.voteCount))
        let popularity = candidate.popularity.isFinite ? max(0, candidate.popularity) : 0
        score += 0.02 * min(1, log10(1 + votes) / 4) + 0.01 * min(1, log10(1 + popularity) / 3)
        return min(1, max(0, score))
    }

    /// Best candidate with score >= threshold (default 0.72), else nil.
    public static func best(title: String, year: Int?, candidates: [TMDBClient.SearchResult], threshold: Double = 0.72) -> TMDBClient.SearchResult? {
        var best: (score: Double, candidate: TMDBClient.SearchResult)?
        for candidate in candidates {
            let value = score(title: title, year: year, candidate: candidate)
            guard value >= threshold else { continue }
            guard let current = best else {
                best = (value, candidate)
                continue
            }
            let better: Bool
            if value != current.score {
                better = value > current.score
            } else if candidate.voteCount != current.candidate.voteCount {
                better = candidate.voteCount > current.candidate.voteCount
            } else {
                better = candidate.popularity > current.candidate.popularity
            }
            if better { best = (value, candidate) }
        }
        return best?.candidate
    }

    // MARK: - Normalization (own rules; deliberately independent of `TitleKey`)

    static let leadingArticles: Set<String> = ["the", "a", "an", "der", "die", "das", "le", "la", "les", "l", "el", "los", "las",
                                               "il", "lo", "gli", "un", "une", "ein", "eine"]
    static let romanNumerals: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7",
                                                  "viii": "8", "ix": "9", "x": "10"]

    /// "The Lord of the Rings: The Two Towers" → "lord of the rings the two towers"; "Amélie" → "amelie";
    /// "Rocky II" → "rocky 2"; "Fast & Furious" → "fast and furious".
    static func normalize(_ title: String) -> String {
        let folded = title.tunaFolded
        var tokens: [String] = []
        var current = ""
        let characters = Array(folded)
        var index = 0
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if character == "'" || character == "’" || character == "`" || character == "´" {
                // Possessive "'s" stays glued ("philosopher's" → "philosophers"); elision splits ("l'odyssee" → "l odyssee").
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                let afterNext = index + 2 < characters.count ? characters[index + 2] : " "
                if !(next == "s" && !(afterNext.isLetter || afterNext.isNumber)) { flush() }
            } else if character == "&" {
                flush()
                tokens.append("and")
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
            index += 1
        }
        flush()
        if tokens.count > 1, leadingArticles.contains(tokens[0]) { tokens.removeFirst() }
        if tokens.count > 1 {
            tokens = tokens.map { romanNumerals[$0] ?? $0 }
        }
        return tokens.joined(separator: " ")
    }

    /// Similarity of two normalized titles: edit-distance ratio on the space-free form blended with token overlap,
    /// penalized when the numbers in them differ.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let tokensA = a.split(separator: " ").map(String.init)
        let tokensB = b.split(separator: " ").map(String.init)
        let numbersA = tokensA.filter { $0.allSatisfy(\.isNumber) }
        let numbersB = tokensB.filter { $0.allSatisfy(\.isNumber) }
        let compactA = tokensA.joined()
        let compactB = tokensB.joined()
        var value: Double
        if compactA == compactB {
            value = 0.97
        } else {
            let scalarsA = MetadataSupport.scalars(compactA)
            let scalarsB = MetadataSupport.scalars(compactB)
            let distance = MetadataSupport.levenshtein(scalarsA, scalarsB)
            let edit = 1 - Double(distance) / Double(max(scalarsA.count, scalarsB.count))
            let setA = Set(tokensA)
            let setB = Set(tokensB)
            let dice = 2 * Double(setA.intersection(setB).count) / Double(setA.count + setB.count)
            value = max(edit, (edit + dice) / 2)
        }
        if numbersA != numbersB { value *= 0.7 }
        return min(1, max(0, value))
    }
}
