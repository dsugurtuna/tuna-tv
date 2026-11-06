import Foundation
import TunaCore

/// Pure helpers for the user's "worlds" (WorldSelection): grouping for display, the "English · Türkiye"
/// summary and add/remove semantics shared by the top-bar World Switcher, onboarding and Settings.
///
/// Semantics:
/// - A *world group* is one language with the selected countries that speak it ("English": US, GB, CA …),
///   shown by the country's native name when it is the only one ("Türkiye").
/// - Featured worlds (onboarding cards, popover tiles) toggle a whole language world.
/// - The country list toggles single countries; the language goes when its last country goes.
/// - The last language is never removed (the showcase always has a world).
enum WorldEditing {
    struct WorldGroup: Identifiable, Hashable {
        var id: String
        /// ISO 639-1, nil for a country whose language is not one of the selected languages.
        var language: String?
        /// ISO 3166-1 alpha-2 codes (upper case).
        var countries: [String]
        var name: String
        /// Country code whose flag represents the group ("" when unknown).
        var flagCode: String
    }

    // MARK: Names

    static func primaryLanguage(ofCountry code: String) -> String? {
        WorldDirectory.country(code.uppercased())?.languages.first?.lowercased()
    }

    /// Native name ("Türkiye"), falling back to the system's name for the region.
    static func countryName(_ code: String) -> String {
        if let info = WorldDirectory.country(code.uppercased()) {
            return info.nativeName.isEmpty ? info.name : info.nativeName
        }
        return Locale.current.localizedString(forRegionCode: code) ?? code.uppercased()
    }

    /// English name ("Turkey").
    static func countryEnglishName(_ code: String) -> String {
        if let info = WorldDirectory.country(code.uppercased()), !info.name.isEmpty { return info.name }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code.uppercased()
    }

    /// Native name ("Türkçe"), falling back to the system's name for the language.
    static func languageName(_ code: String) -> String {
        if let info = WorldDirectory.language(code.lowercased()) {
            return info.nativeName.isEmpty ? info.name : info.nativeName
        }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// English name ("Turkish").
    static func languageEnglishName(_ code: String) -> String {
        if let info = WorldDirectory.language(code.lowercased()), !info.name.isEmpty { return info.name }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// Flag emoji for a language ("en" -> 🇬🇧).
    static func languageFlag(_ code: String) -> String {
        if let info = WorldDirectory.language(code.lowercased()) { return info.flag }
        return ""
    }

    // MARK: Groups

    static func groups(for worlds: WorldSelection) -> [WorldGroup] {
        var result: [WorldGroup] = []
        var claimed = Set<String>()
        for language in worlds.languages {
            var members: [String] = []
            for code in worlds.countries where !claimed.contains(code) && primaryLanguage(ofCountry: code) == language {
                members.append(code)
                claimed.insert(code)
            }
            let name: String
            let flag: String
            if members.count == 1, let only = members.first {
                name = countryName(only)
                flag = only
            } else {
                name = languageName(language)
                flag = WorldDirectory.language(language)?.flagCountry ?? members.first ?? ""
            }
            result.append(WorldGroup(id: "lang:\(language)", language: language, countries: members, name: name, flagCode: flag))
        }
        for code in worlds.countries where !claimed.contains(code) {
            claimed.insert(code)
            result.append(WorldGroup(id: "country:\(code)", language: nil, countries: [code], name: countryName(code), flagCode: code))
        }
        return result
    }

    /// "English · Türkiye".
    static func summary(for worlds: WorldSelection) -> String {
        let names = groups(for: worlds).map(\.name)
        return names.isEmpty ? "English" : names.joined(separator: " · ")
    }

    static func canRemove(_ group: WorldGroup, from worlds: WorldSelection) -> Bool {
        removingGroup(group, from: worlds) != worlds
    }

    static func removingGroup(_ group: WorldGroup, from worlds: WorldSelection) -> WorldSelection {
        var copy = worlds
        if let language = group.language {
            copy.languages.removeAll { $0 == language }
        }
        copy.countries.removeAll { group.countries.contains($0) }
        return copy.languages.isEmpty ? worlds : copy
    }

    // MARK: Featured worlds (language level)

    static func isLanguageWorldSelected(_ country: CountryInfo, in worlds: WorldSelection) -> Bool {
        if let language = country.languages.first { return worlds.includes(language: language) }
        return worlds.includes(country: country.code)
    }

    static func toggledLanguageWorld(_ country: CountryInfo, in worlds: WorldSelection) -> WorldSelection {
        let code = country.code.uppercased()
        let language = country.languages.first?.lowercased()
        guard isLanguageWorldSelected(country, in: worlds) else {
            return worlds.adding(country: code, language: language)
        }
        var copy = worlds
        if let language {
            copy.languages.removeAll { $0 == language }
            copy.countries.removeAll { $0 == code || primaryLanguage(ofCountry: $0) == language }
        } else {
            copy.countries.removeAll { $0 == code }
        }
        return copy.languages.isEmpty ? worlds : copy
    }

    // MARK: Single countries

    static func toggledCountry(_ country: CountryInfo, in worlds: WorldSelection) -> WorldSelection {
        let code = country.code.uppercased()
        let language = country.languages.first?.lowercased()
        guard worlds.includes(country: code) else {
            return worlds.adding(country: code, language: language)
        }
        var copy = worlds
        copy.countries.removeAll { $0 == code }
        if let language, copy.languages.count > 1,
           !copy.countries.contains(where: { primaryLanguage(ofCountry: $0) == language }) {
            copy.languages.removeAll { $0 == language }
        }
        return copy
    }

    // MARK: Search

    /// Countries matching a query (English/native name, code or language), all when the query is empty.
    static func search(_ query: String) -> [CountryInfo] {
        let all = WorldDirectory.countries
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).tunaFolded
        guard !needle.isEmpty else { return all }
        return all.filter { country in
            if country.name.tunaFolded.contains(needle) || country.nativeName.tunaFolded.contains(needle) { return true }
            if country.code.lowercased() == needle { return true }
            return country.languages.contains { languageEnglishName($0).tunaFolded.hasPrefix(needle) }
        }
    }
}
