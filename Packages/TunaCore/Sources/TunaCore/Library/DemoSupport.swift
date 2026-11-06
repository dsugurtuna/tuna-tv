import Foundation

// Shared helpers for the demo content: a seeded generator, a platform-independent hash, slugs and
// calendar arithmetic that never touches the system clock, locale or time zone.

/// SplitMix64. Deterministic on every platform (unlike `Hasher`, which is seeded per process).
struct DemoRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Seeded from a stable 64-bit FNV-1a hash of `text`.
    init(_ text: String) { state = DemoHash.fnv1a(text) }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func double() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func double(_ low: Double, _ high: Double) -> Double { low + (high - low) * double() }

    mutating func chance(_ probability: Double) -> Bool { double() < probability }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var copy = items
        guard copy.count > 1 else { return copy }
        for i in stride(from: copy.count - 1, to: 0, by: -1) {
            let j = int(0...i)
            if i != j { copy.swapAt(i, j) }
        }
        return copy
    }

    /// `count` distinct elements, in random order.
    mutating func sample<T>(_ items: [T], count: Int) -> [T] { Array(shuffled(items).prefix(max(0, count))) }
}

enum DemoHash {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

enum DemoText {
    private static let foldMap: [Character: String] = [
        "ç": "c", "Ç": "c", "ğ": "g", "Ğ": "g", "ı": "i", "İ": "i", "ö": "o", "Ö": "o", "ş": "s", "Ş": "s",
        "ü": "u", "Ü": "u", "â": "a", "Â": "a", "î": "i", "Î": "i", "û": "u", "Û": "u", "ä": "a", "Ä": "a",
        "ß": "ss", "à": "a", "À": "a", "á": "a", "Á": "a", "æ": "ae", "é": "e", "É": "e", "è": "e", "È": "e",
        "ê": "e", "ë": "e", "ï": "i", "í": "i", "Í": "i", "ì": "i", "ô": "o", "ó": "o", "Ó": "o", "ò": "o",
        "œ": "oe", "ù": "u", "ú": "u", "Ú": "u", "ÿ": "y", "ñ": "n", "Ñ": "n", "ã": "a", "õ": "o", "ø": "o",
        "å": "a", "Å": "a", "ł": "l", "č": "c", "ć": "c", "š": "s", "ž": "z", "ř": "r", "ý": "y",
    ]

    /// Stable ASCII slug: "Kuzey Işığı" -> "kuzey-isigi", "Albion One +1" -> "albion-one-plus-1".
    /// Uses its own folding table so the result never depends on the platform's ICU data.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        func append(_ piece: String) {
            if pendingDash && !out.isEmpty { out += "-" }
            pendingDash = false
            out += piece
        }
        for character in text {
            if let mapped = foldMap[character] { append(mapped); continue }
            if character == "+" { pendingDash = true; append("plus"); pendingDash = true; continue }
            if character == "&" { pendingDash = true; append("and"); pendingDash = true; continue }
            if character == "'" || character == "’" { continue }
            let lower = String(character).lowercased()
            if lower.count == 1, let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1,
               (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                append(lower)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// True when the text contains at least one Arabic-script letter.
    static func hasArabicScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// "1,234,567"
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { out += "," }
            out.append(digit)
        }
        return out
    }
}

/// Proleptic Gregorian calendar arithmetic in UTC (Howard Hinnant's civil-from-days algorithms).
enum DemoCalendar {
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func string(days: Int) -> String {
        let c = civil(days: days)
        return "\(DemoText.pad(c.year, 4))-\(DemoText.pad(c.month, 2))-\(DemoText.pad(c.day, 2))"
    }

    static func date(days: Int, seconds: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(days * 86_400 + seconds))
    }

    static func dayNumber(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    /// A deterministic day inside `year` (avoids the last days of December so sequels stay ordered).
    static func day(in year: Int, rng: inout DemoRNG) -> Int {
        days(year: year, month: rng.int(1...12), day: rng.int(1...28))
    }
}

/// Fixed timestamps used where the API has no `now` (so repeated calls are byte-for-byte equal).
enum DemoClock {
    /// 2026-10-01T00:00:00Z
    static let reference = Date(timeIntervalSince1970: 1_790_812_800)
}
