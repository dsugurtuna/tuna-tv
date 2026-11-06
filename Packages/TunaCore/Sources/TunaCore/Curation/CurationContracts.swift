import Foundation

// =====================================================================================================
// CURATION CONTRACT (owner: Curation). Turns provider garbage into a premium catalog.
// Hand-written tokenizer + dictionary lookups (few regexes): must parse 150k names in < 1 s (release build).
// =====================================================================================================

public enum NameParser {
    /// Parses one provider name. `category` hints (from the provider category) fill gaps (language, quality).
    /// Examples: "EN| The Matrix (1999) 4K" -> title "The Matrix", year 1999, quality .uhd, languages ["en"].
    ///           "|TR| Kurtlar Vadisi S01 E05" -> title "Kurtlar Vadisi", season 1, episode 5, languages ["tr"].
    ///           "UK: BBC One FHD (Backup)" -> title "BBC One", quality .fhd, countries ["GB"], isBackup.
    public static func parse(_ name: String, kind: StreamKind, category: CategoryHints? = nil) -> ParsedName { fatalError("TODO(curation)") }
}

public enum CategoryParser {
    /// "EN | MOVIES 4K" -> cleanName "Movies", languages ["en"], quality .uhd. "XXX | Adult" -> isAdult.
    public static func parse(_ name: String, kind: StreamKind) -> CategoryHints { fatalError("TODO(curation)") }
}

public enum TitleKey {
    /// Canonical dedupe key: folded case/diacritics (Turkish ı/İ -> i), '&' -> "and", punctuation removed,
    /// leading article dropped (the/a/an/der/die/das/le/la/les/el/los/il), roman numerals II..X -> digits,
    /// whitespace collapsed. "The Lord of the Rings: The Two Towers" -> "lord of the rings the two towers".
    public static func make(_ title: String) -> String { fatalError("TODO(curation)") }
}

public enum ScriptDetector {
    /// Language implied by the dominant non-Latin script, if any: Arabic -> "ar", Cyrillic -> "ru",
    /// Greek -> "el", Hebrew -> "he", Hangul -> "ko", Kana -> "ja", Han -> "zh", Devanagari -> "hi", Thai -> "th".
    public static func languageHint(for text: String) -> String? { fatalError("TODO(curation)") }
}

public struct CountryInfo: Codable, Hashable, Sendable, Identifiable {
    /// ISO 3166-1 alpha-2.
    public var code: String
    public var name: String
    /// Native name ("Türkiye").
    public var nativeName: String
    /// Primary language(s), ISO 639-1.
    public var languages: [String]
    public var id: String { code }
    public var flag: String { Flags.emoji(for: code) }

    public init(code: String, name: String, nativeName: String, languages: [String]) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.languages = languages
    }
}

public struct LanguageInfo: Codable, Hashable, Sendable, Identifiable {
    public var code: String
    public var name: String
    public var nativeName: String
    /// Country whose flag represents the language in the UI ("en" -> "GB", "tr" -> "TR", "ar" -> "SA").
    public var flagCountry: String
    public var id: String { code }
    public var flag: String { Flags.emoji(for: flagCountry) }

    public init(code: String, name: String, nativeName: String, flagCountry: String) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.flagCountry = flagCountry
    }
}

/// Countries and languages for the "Choose your worlds" picker and for flag rendering.
public enum WorldDirectory {
    /// ~120 countries commonly seen in IPTV catalogs, sorted by English name.
    public static var countries: [CountryInfo] { fatalError("TODO(curation)") }
    /// ~60 languages commonly seen in IPTV catalogs, sorted by English name.
    public static var languages: [LanguageInfo] { fatalError("TODO(curation)") }
    public static func country(_ code: String) -> CountryInfo? { fatalError("TODO(curation)") }
    public static func language(_ code: String) -> LanguageInfo? { fatalError("TODO(curation)") }
    /// Display name for a region code ("LATAM" -> "Latin America", "EXYU" -> "Ex-Yugoslavia").
    public static func regionName(_ code: String) -> String { fatalError("TODO(curation)") }
    /// Featured worlds shown first in onboarding (English, Türkiye, Deutschland, España, France, Italia, العربية ...).
    public static var featured: [CountryInfo] { fatalError("TODO(curation)") }
}

/// Builds the curated catalog: parses every raw item, merges duplicates into Titles/Channels, scores variants,
/// decides showcase vs Vault shelf. Pure and deterministic (same input -> same output). Rules:
/// - Adult (name/category) -> .vault(.adult) always; excluded from everything else.
/// - Variant matches the world if its languages ∩ worlds.languages ≠ ∅, or (no language tag) its countries ∩
///   worlds.countries ≠ ∅, or it carries neither language nor country tags (untagged = assumed in-world),
///   unless its script hint is a language outside the worlds.
/// - Movies/series: a title is SHOWCASE if it has a world-matching variant with quality >= showcase minimum and
///   no low-grade source. Otherwise its shelf is: no world-matching variant -> .otherLanguages; best world variant
///   is CAM/TS/SCR -> .lowQuality; disc source -> .disc; fhd/hd -> .highDefinition; sd/unknown -> .legacy.
/// - Auto-relax: if showcase movies (or series) < relaxThreshold, the minimum drops one tier (uhd -> fhd -> hd)
///   for that kind only; `stats.showcaseRelaxed` is set so the UI can say so.
/// - Series: provider series records are grouped by key (+ year when present); quality comes from the record
///   name/category (episodes are fetched on demand).
/// - Live: channels grouped by key + country; variants ordered by quality desc, non-backup first; showcase if any
///   variant matches the world, else .vault(.otherLanguages). Timeshift "+1" feeds become separate channels.
/// - Variant score: quality*100 + hdr 20 + world match 300 + hevc 5 - backup 50 - lowGrade 400 - failures*80
///   + verified quality bonus.
/// - Ids: "movie:<key>:<year or 0>", "series:<key>", "live:<key>:<country or xx>".
public struct Curator: Sendable {
    public var preferences: ContentPreferences

    public init(preferences: ContentPreferences) { self.preferences = preferences }

    public func curate(_ catalogs: [ProviderCatalog], verifiedQualities: [String: Int] = [:],
                       failingVariants: [String: Int] = [:]) -> CuratedCatalog {
        fatalError("TODO(curation)")
    }
}
