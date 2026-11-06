import Foundation

// Shared helpers for the Library module (owner: Library): tokenizing, world/genre names, dates, model shortcuts.

// MARK: - Model shortcuts

extension Title {
    /// Placement with the adult rule enforced: adult content always lives on the Vault's adult shelf.
    var libraryPlacement: Placement { isAdult ? .vault(.adult) : placement }
    /// Showcase and not adult.
    var isLibraryShowcase: Bool { !isAdult && placement.isShowcase }
}

extension Channel {
    var libraryPlacement: Placement { isAdult ? .vault(.adult) : placement }
    var isLibraryShowcase: Bool { !isAdult && placement.isShowcase }
}

// MARK: - Tokens

/// Folded word tokens used by search and matching. Lowercased, diacritics removed (`String.tunaFolded`), split on
/// anything that is not a letter, digit or combining mark. Apostrophes are dropped inside words ("Schindler's" ->
/// "schindlers"); hyphenated words also yield their joined form ("Spider-Man" -> "spider", "man" + "spiderman").
enum TextTokens {
    struct Split {
        var words: [String] = []
        /// Joined forms of hyphenated words.
        var compounds: [String] = []
    }

    static func split(_ text: String) -> Split {
        var result = Split()
        var ascii = true
        for byte in text.utf8 where byte >= 0x80 { ascii = false; break }
        if ascii { splitASCII(text, into: &result) } else { splitUnicode(text.tunaFolded, into: &result) }
        return result
    }

    /// Words only (no compounds).
    static func words(_ text: String) -> [String] { split(text).words }

    /// Words joined by single spaces with a leading and trailing space, for phrase checks (" premier league ").
    static func phraseText(_ text: String) -> String { " " + split(text).words.joined(separator: " ") + " " }

    private static func splitASCII(_ text: String, into result: inout Split) {
        var word: [UInt8] = []
        var compound: [UInt8] = []
        var parts = 0
        word.reserveCapacity(16)
        func flushWord() {
            guard !word.isEmpty else { return }
            result.words.append(String(decoding: word, as: UTF8.self))
            compound.append(contentsOf: word)
            parts += 1
            word.removeAll(keepingCapacity: true)
        }
        func flushCompound() {
            if parts > 1 { result.compounds.append(String(decoding: compound, as: UTF8.self)) }
            compound.removeAll(keepingCapacity: true)
            parts = 0
        }
        for byte in text.utf8 {
            switch byte {
            case 0x61...0x7A, 0x30...0x39: word.append(byte)
            case 0x41...0x5A: word.append(byte + 32)
            case 0x27: continue
            case 0x2D: flushWord()
            default:
                flushWord()
                flushCompound()
            }
        }
        flushWord()
        flushCompound()
    }

    private static func splitUnicode(_ folded: String, into result: inout Split) {
        var word = String.UnicodeScalarView()
        var compound = String.UnicodeScalarView()
        var parts = 0
        func flushWord() {
            guard !word.isEmpty else { return }
            result.words.append(String(word))
            compound.append(contentsOf: word)
            parts += 1
            word = String.UnicodeScalarView()
        }
        func flushCompound() {
            if parts > 1 { result.compounds.append(String(compound)) }
            compound = String.UnicodeScalarView()
            parts = 0
        }
        for scalar in folded.unicodeScalars {
            if isWordScalar(scalar) {
                if scalar.value >= 0x41 && scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 32) {
                    word.append(lower)
                } else {
                    word.append(scalar)
                }
            } else if scalar.value == 0x27 || scalar.value == 0x2019 || scalar.value == 0x02BC {
                continue
            } else if scalar.value == 0x2D || scalar.value == 0x2010 || scalar.value == 0x2011 {
                flushWord()
            } else {
                flushWord()
                flushCompound()
            }
        }
        flushWord()
        flushCompound()
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x80 { return (v >= 0x30 && v <= 0x39) || (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) }
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Sort key for alphabetical ordering: folded, leading article dropped ("The Matrix" -> "matrix").
    static func sortKey(_ name: String) -> String {
        var words = split(name).words
        if words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

// MARK: - World names

/// A small built-in table of common countries and languages (the Library cannot depend on other modules' tables).
enum WorldNames {
    struct Country: Sendable {
        let name: String
        /// Primary language, ISO 639-1.
        let language: String
    }

    /// Countries whose main language is English (the default world).
    static let englishCountries: Set<String> = ["US", "GB", "CA", "AU", "IE", "NZ"]

    static let countries: [String: Country] = [
        "US": Country(name: "the United States", language: "en"), "GB": Country(name: "the United Kingdom", language: "en"),
        "CA": Country(name: "Canada", language: "en"), "AU": Country(name: "Australia", language: "en"),
        "IE": Country(name: "Ireland", language: "en"), "NZ": Country(name: "New Zealand", language: "en"),
        "TR": Country(name: "Türkiye", language: "tr"), "DE": Country(name: "Germany", language: "de"),
        "AT": Country(name: "Austria", language: "de"), "CH": Country(name: "Switzerland", language: "de"),
        "FR": Country(name: "France", language: "fr"), "BE": Country(name: "Belgium", language: "nl"),
        "NL": Country(name: "the Netherlands", language: "nl"), "ES": Country(name: "Spain", language: "es"),
        "MX": Country(name: "Mexico", language: "es"), "AR": Country(name: "Argentina", language: "es"),
        "CO": Country(name: "Colombia", language: "es"), "CL": Country(name: "Chile", language: "es"),
        "PT": Country(name: "Portugal", language: "pt"), "BR": Country(name: "Brazil", language: "pt"),
        "IT": Country(name: "Italy", language: "it"), "GR": Country(name: "Greece", language: "el"),
        "CY": Country(name: "Cyprus", language: "el"), "PL": Country(name: "Poland", language: "pl"),
        "RO": Country(name: "Romania", language: "ro"), "BG": Country(name: "Bulgaria", language: "bg"),
        "RS": Country(name: "Serbia", language: "sr"), "HR": Country(name: "Croatia", language: "hr"),
        "BA": Country(name: "Bosnia and Herzegovina", language: "bs"), "AL": Country(name: "Albania", language: "sq"),
        "MK": Country(name: "North Macedonia", language: "mk"), "HU": Country(name: "Hungary", language: "hu"),
        "CZ": Country(name: "Czechia", language: "cs"), "SK": Country(name: "Slovakia", language: "sk"),
        "SE": Country(name: "Sweden", language: "sv"), "NO": Country(name: "Norway", language: "no"),
        "DK": Country(name: "Denmark", language: "da"), "FI": Country(name: "Finland", language: "fi"),
        "RU": Country(name: "Russia", language: "ru"), "UA": Country(name: "Ukraine", language: "uk"),
        "IN": Country(name: "India", language: "hi"), "PK": Country(name: "Pakistan", language: "ur"),
        "SA": Country(name: "Saudi Arabia", language: "ar"), "AE": Country(name: "the United Arab Emirates", language: "ar"),
        "EG": Country(name: "Egypt", language: "ar"), "MA": Country(name: "Morocco", language: "ar"),
        "IR": Country(name: "Iran", language: "fa"), "IL": Country(name: "Israel", language: "he"),
        "JP": Country(name: "Japan", language: "ja"), "KR": Country(name: "South Korea", language: "ko"),
        "CN": Country(name: "China", language: "zh"), "TW": Country(name: "Taiwan", language: "zh"),
        "HK": Country(name: "Hong Kong", language: "zh"), "TH": Country(name: "Thailand", language: "th"),
        "PH": Country(name: "the Philippines", language: "tl"), "ID": Country(name: "Indonesia", language: "id"),
        "VN": Country(name: "Vietnam", language: "vi"), "AZ": Country(name: "Azerbaijan", language: "az"),
        "NG": Country(name: "Nigeria", language: "en"), "ZA": Country(name: "South Africa", language: "en"),
    ]

    static let languages: [String: String] = [
        "en": "English", "tr": "Turkish", "de": "German", "fr": "French", "nl": "Dutch", "es": "Spanish",
        "pt": "Portuguese", "it": "Italian", "el": "Greek", "pl": "Polish", "ro": "Romanian", "bg": "Bulgarian",
        "sr": "Serbian", "hr": "Croatian", "bs": "Bosnian", "sq": "Albanian", "mk": "Macedonian", "hu": "Hungarian",
        "cs": "Czech", "sk": "Slovak", "sv": "Swedish", "no": "Norwegian", "da": "Danish", "fi": "Finnish",
        "ru": "Russian", "uk": "Ukrainian", "hi": "Hindi", "ur": "Urdu", "ar": "Arabic", "fa": "Persian",
        "he": "Hebrew", "ja": "Japanese", "ko": "Korean", "zh": "Chinese", "th": "Thai", "tl": "Tagalog",
        "id": "Indonesian", "vi": "Vietnamese", "az": "Azerbaijani", "ku": "Kurdish", "ta": "Tamil",
        "te": "Telugu", "ml": "Malayalam", "bn": "Bengali", "pa": "Punjabi", "sl": "Slovenian", "lt": "Lithuanian",
        "lv": "Latvian", "et": "Estonian", "ka": "Georgian", "hy": "Armenian", "ms": "Malay",
    ]

    /// Display name ("Türkiye", "the Netherlands"), nil when unknown.
    static func countryName(_ code: String) -> String? { countries[code.uppercased()]?.name }
    static func languageName(_ code: String) -> String? { languages[code.lowercased()] }
    static func primaryLanguage(ofCountry code: String) -> String? { countries[code.uppercased()]?.language }
}

// MARK: - Genres

/// Canonical genre names so provider hints ("SCI-FI", "Documentaries") and TMDB genres ("Science Fiction") merge.
/// TMDB TV combos are split ("Action & Adventure" -> "Action", "Adventure").
enum GenreNames {
    private static let synonyms: [String: String] = [
        "sci fi": "Science Fiction", "scifi": "Science Fiction", "science fiction": "Science Fiction", "sf": "Science Fiction",
        "documentaries": "Documentary", "documentary": "Documentary", "docu": "Documentary", "docs": "Documentary",
        "comedies": "Comedy", "dramas": "Drama", "thrillers": "Thriller", "horrors": "Horror",
        "animated": "Animation", "cartoon": "Animation", "cartoons": "Animation", "anime": "Animation",
        "romantic": "Romance", "kid": "Kids", "children": "Kids", "childrens": "Kids", "musical": "Music",
        "musicals": "Music", "historical": "History", "westerns": "Western", "war films": "War",
        "action movies": "Action", "family movies": "Family", "biography": "Biography", "biopic": "Biography",
        "tv movie": "TV Movie", "talk": "Talk", "reality": "Reality", "soap": "Soap", "news": "News",
        "politics": "Politics", "sports": "Sport", "sport": "Sport",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memo: [String: [String]] = [:]

    /// Canonical names for one raw genre string (memoized: catalogs only hold a few dozen distinct strings).
    static func expand(_ raw: String) -> [String] {
        lock.lock()
        if let hit = memo[raw] { lock.unlock(); return hit }
        lock.unlock()
        let value = compute(raw)
        lock.lock()
        if memo.count < 4096 { memo[raw] = value }
        lock.unlock()
        return value
    }

    /// Canonical genres of a title: metadata genres when present, else provider hints. Deduplicated, order kept.
    static func genres(of title: Title, metadata: MediaMetadata?) -> [String] {
        let source: [String]
        if let fromMetadata = metadata?.genres, !fromMetadata.isEmpty { source = fromMetadata } else { source = title.genres }
        if source.isEmpty { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in source {
            for name in expand(raw) where seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// Comparison key for a genre name ("science fiction").
    static func key(_ name: String) -> String { TextTokens.words(name).joined(separator: " ") }

    private static func compute(_ raw: String) -> [String] {
        let trimmed = raw.tunaTrimmed
        guard !trimmed.isEmpty else { return [] }
        var pieces: [String] = []
        if trimmed.contains("&") {
            pieces = trimmed.components(separatedBy: "&").map { $0.tunaTrimmed }.filter { !$0.isEmpty }
        } else if trimmed.contains("/") {
            pieces = trimmed.components(separatedBy: "/").map { $0.tunaTrimmed }.filter { !$0.isEmpty }
        } else {
            pieces = [trimmed]
        }
        var out: [String] = []
        for piece in pieces {
            let k = key(piece)
            guard !k.isEmpty else { continue }
            if let canonical = synonyms[k] {
                if !out.contains(canonical) { out.append(canonical) }
                continue
            }
            let display = displayCase(piece)
            if !out.contains(display) { out.append(display) }
        }
        return out
    }

    /// "ACTION" / "action" -> "Action"; mixed case is kept ("Sci-Fi" stays as written).
    private static func displayCase(_ text: String) -> String {
        let upper = text.uppercased(), lower = text.lowercased()
        guard text == upper || text == lower else { return text }
        return lower.split(separator: " ").map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Dates

/// Calendar-free date math (UTC civil dates), deterministic on every platform.
enum CivilDate {
    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func date(year: Int, month: Int = 1, day: Int = 1) -> Date {
        Date(timeIntervalSince1970: TimeInterval(days(year: year, month: month, day: day)) * 86_400)
    }

    /// Parses "YYYY-MM-DD", "YYYY-MM" or "YYYY" (a year alone means July 1st).
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.prefix(10).split(separator: "-")
        guard let first = parts.first, first.count == 4, let year = Int(first), year > 1800, year < 2300 else { return nil }
        if parts.count == 1 { return date(year: year, month: 7, day: 1) }
        let month = Int(parts[1]).map { min(12, max(1, $0)) } ?? 1
        let day = parts.count > 2 ? (Int(parts[2]).map { min(31, max(1, $0)) } ?? 1) : 1
        return date(year: year, month: month, day: day)
    }

    static func year(_ text: String?) -> Int? {
        guard let text, text.count >= 4, let year = Int(text.prefix(4)), year > 1800, year < 2300 else { return nil }
        return year
    }
}
