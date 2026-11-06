import Foundation

/// String similarity measures used for title / channel matching. Every function compares the `tunaFolded` forms
/// of its inputs (lowercased, diacritics removed, Turkish ı/İ mapped to i), working on Unicode scalars.
///
/// - `levenshtein`: edit distance (insert / delete / substitute, each cost 1).
/// - `jaroWinkler`: 0...1, Winkler prefix boost (scale 0.1, up to 4 characters, applied when Jaro > 0.7).
/// - `tokenSetRatio`: 0...1, RapidFuzz `token_set_ratio` semantics on alphanumeric tokens, so word order,
///   duplicated words and punctuation do not matter ("The Matrix (1999)" vs "Matrix, The 1999" → 1).
public enum Similarity {
    /// Edit distance between the folded forms of `a` and `b`.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        levenshtein(scalars(a), scalars(b))
    }

    /// Jaro-Winkler similarity in 0...1 (1 = identical after folding; two empty strings are identical).
    public static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let x = scalars(a), y = scalars(b)
        let jaro = jaro(x, y)
        guard jaro > 0.7 else { return jaro }
        var prefix = 0
        while prefix < min(4, x.count, y.count), x[prefix] == y[prefix] { prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// Token-set ratio in 0...1. Inputs without any alphanumeric token score 0.
    public static func tokenSetRatio(_ a: String, _ b: String) -> Double {
        let tokensA = Set(tokens(a)), tokensB = Set(tokens(b))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersection = tokensA.intersection(tokensB)
        let onlyA = tokensA.subtracting(tokensB).sorted()
        let onlyB = tokensB.subtracting(tokensA).sorted()
        // One token set contains the other.
        if !intersection.isEmpty, onlyA.isEmpty || onlyB.isEmpty { return 1 }

        let joinedA = Array(onlyA.joined(separator: " ").unicodeScalars.map(\.value))
        let joinedB = Array(onlyB.joined(separator: " ").unicodeScalars.map(\.value))
        let lengthA = joinedA.count, lengthB = joinedB.count
        let sectLength = intersection.sorted().joined(separator: " ").unicodeScalars.count
        let separator = sectLength > 0 ? 1 : 0
        // Lengths of "sect + diffA" and "sect + diffB".
        let sectALength = sectLength + separator + lengthA
        let sectBLength = sectLength + separator + lengthB

        // "sect + diffA" vs "sect + diffB": the shared prefix costs nothing, so the distance is that of the diffs.
        var best = normalizedSimilarity(distance: indelDistance(joinedA, joinedB), total: sectALength + sectBLength)
        guard sectLength > 0 else { return best }
        // "sect" vs "sect + diff": only the diff (plus the joining space) differs, so the indel distance is its length.
        best = max(best, normalizedSimilarity(distance: separator + lengthA, total: sectLength + sectALength))
        best = max(best, normalizedSimilarity(distance: separator + lengthB, total: sectLength + sectBLength))
        return best
    }

    /// Normalized indel similarity in 0...1 (`2 * LCS / (len a + len b)`, RapidFuzz `fuzz.ratio` / 100).
    /// Two empty strings score 1.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = scalars(a), y = scalars(b)
        return normalizedSimilarity(distance: indelDistance(x, y), total: x.count + y.count)
    }

    /// Lowercase alphanumeric tokens of the folded string, in order ("Matrix, The (1999)" → ["matrix", "the", "1999"]).
    public static func tokens(_ string: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in fold(string).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    // MARK: - Internals

    /// `tunaFolded`, with a fast path for plain ASCII (where folding is just lowercasing).
    static func fold(_ string: String) -> String {
        if string.utf8.allSatisfy({ $0 < 0x80 }) { return string.lowercased() }
        return string.tunaFolded
    }

    static func scalars(_ string: String) -> [UInt32] { fold(string).unicodeScalars.map(\.value) }

    static func levenshtein(_ x: [UInt32], _ y: [UInt32]) -> Int {
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0 ... y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1 ... x.count {
            current[0] = i
            for j in 1 ... y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    static func jaro(_ x: [UInt32], _ y: [UInt32]) -> Double {
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        let window = max(0, max(x.count, y.count) / 2 - 1)
        var matchedX = [Bool](repeating: false, count: x.count)
        var matchedY = [Bool](repeating: false, count: y.count)
        var matches = 0
        for i in 0 ..< x.count {
            let start = max(0, i - window), end = min(y.count - 1, i + window)
            guard start <= end else { continue }
            for j in start ... end where !matchedY[j] && x[i] == y[j] {
                matchedX[i] = true
                matchedY[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0
        var k = 0
        for i in 0 ..< x.count where matchedX[i] {
            while !matchedY[k] { k += 1 }
            if x[i] != y[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        return (m / Double(x.count) + m / Double(y.count) + (m - Double(transpositions / 2)) / m) / 3
    }

    /// Insertions + deletions needed to turn `x` into `y` (`len x + len y - 2 * LCS`).
    static func indelDistance(_ x: [UInt32], _ y: [UInt32]) -> Int {
        if x.isEmpty || y.isEmpty { return x.count + y.count }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1 ... x.count {
            for j in 1 ... y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return x.count + y.count - 2 * previous[y.count]
    }

    static func normalizedSimilarity(distance: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return max(0, 1 - Double(distance) / Double(total))
    }
}
