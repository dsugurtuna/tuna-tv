import Foundation

/// Matches provider channels to iptv-org channels (name/alt-names/country scoring).
///
/// - An EPG id equal to an iptv-org id (case-insensitive, feed suffix "@HD" ignored, e.g. "BBCOne.uk") wins.
/// - Names are folded and normalized: country/quality prefixes ("UK:", "|UK|", "[VIP]"), quality/backup tags
///   ("FHD", "(Backup)", "+1") and punctuation are dropped: "UK: BBC One FHD" → "bbc one".
/// - Exact normalized (or space-free, "one" = "1") name/alt-name hits score 1.0; otherwise candidates come from token
///   and prefix buckets and are scored with Jaro-Winkler blended with token overlap. Different channel numbers
///   ("BBC Two" vs "BBC Three") never match.
/// - Country bonus +0.04 when the channel's country is among `countries` (GB ≙ UK), −0.06 when countries are known
///   and differ; closed channels −0.03. Threshold 0.86.
public struct ChannelMatcher: Sendable {
    public init(channels: [IPTVOrgChannel]) {
        var entries: [Entry] = []
        var byID: [String: Int32] = [:]
        var exact: [String: [Int32]] = [:]
        var stripped: [String: [Int32]] = [:]
        var compact: [String: [Int32]] = [:]
        var tokens: [String: [Int32]] = [:]
        var prefixes: [String: [Int32]] = [:]

        for (channelIndex, channel) in channels.enumerated() {
            let channelNumber = Int32(channelIndex)
            byID[channel.id.lowercased()] = channelNumber
            var names = Set<String>()
            for name in [channel.name] + channel.altNames {
                let parsed = Self.parse(name)
                guard !parsed.stripped.isEmpty, names.insert(parsed.stripped).inserted else { continue }
                let entryNumber = Int32(entries.count)
                entries.append(Entry(channel: channelNumber, scalars: MetadataSupport.scalars(parsed.stripped),
                                     tokens: parsed.tokens, numbers: parsed.numbers))
                exact[parsed.full, default: []].append(entryNumber)
                if parsed.stripped != parsed.full, parsed.tokens.count > 1 || parsed.stripped.count > 3 {
                    stripped[parsed.stripped, default: []].append(entryNumber)
                }
                compact[parsed.compact, default: []].append(entryNumber)
                for token in Set(parsed.tokens) { tokens[token, default: []].append(entryNumber) }
                prefixes[String(parsed.compact.prefix(3)), default: []].append(entryNumber)
            }
        }
        self.channels = channels
        self.entries = entries
        self.byID = byID
        self.exactIndex = exact
        self.strippedIndex = stripped
        self.compactIndex = compact
        self.tokenIndex = tokens
        self.prefixIndex = prefixes
    }

    /// Best match for a cleaned channel name + countries, or nil below the confidence threshold.
    public func match(name: String, countries: [String], epgID: String?) -> IPTVOrgChannel? {
        if let epgID, let channel = channel(epgID: epgID) { return channel }
        let query = Self.parse(name)
        guard !query.stripped.isEmpty else { return nil }

        var wanted = Set(countries.compactMap(Self.iptvOrgCountry))
        if let country = query.prefixCountry { wanted.insert(country) }
        if wanted.isEmpty, let epgID, let suffix = epgID.split(separator: "@").first?.split(separator: ".").last,
           let country = Self.iptvOrgCountry(String(suffix)) {
            wanted.insert(country)
        }

        var best: (score: Double, channel: Int32)?
        var visited = Set<Int32>()
        func consider(_ entryNumber: Int32, similarity: Double) {
            guard visited.insert(entryNumber).inserted else { return }
            let entry = entries[Int(entryNumber)]
            let channel = channels[Int(entry.channel)]
            var score = similarity
            if !wanted.isEmpty { score += wanted.contains(channel.country.uppercased()) ? Self.countryBonus : -Self.countryPenalty }
            if channel.closed != nil { score -= 0.03 }
            if channel.logoURL == nil { score -= 0.001 }
            if let current = best {
                if score > current.score || (score == current.score && entry.channel < current.channel) { best = (score, entry.channel) }
            } else {
                best = (score, entry.channel)
            }
        }

        for entry in exactIndex[query.full] ?? [] { consider(entry, similarity: 1.0) }
        if query.stripped != query.full {
            for entry in exactIndex[query.stripped] ?? [] { consider(entry, similarity: 1.0) }
        }
        for entry in strippedIndex[query.stripped] ?? [] { consider(entry, similarity: 0.97) }
        for entry in compactIndex[query.compact] ?? [] { consider(entry, similarity: 0.96) }
        if let best, best.score >= Self.threshold { return channels[Int(best.channel)] }

        let queryScalars = MetadataSupport.scalars(query.stripped)
        for entry in candidates(for: query) {
            consider(entry, similarity: similarity(query, scalars: queryScalars, entries[Int(entry)]))
        }
        guard let best, best.score >= Self.threshold else { return nil }
        return channels[Int(best.channel)]
    }

    /// Number of indexed iptv-org channels.
    public var count: Int { channels.count }

    /// iptv-org channel by id (case-insensitive).
    public func channel(id: String) -> IPTVOrgChannel? {
        byID[id.lowercased()].map { channels[Int($0)] }
    }

    // MARK: - Index

    struct Entry: Sendable {
        let channel: Int32
        let scalars: [UInt32]
        let tokens: [String]
        let numbers: [String]
    }

    let channels: [IPTVOrgChannel]
    let entries: [Entry]
    let byID: [String: Int32]
    /// Normalized names with quality words kept ("bbc hd").
    let exactIndex: [String: [Int32]]
    /// Names whose quality words were dropped ("bbc hd" → "bbc"), slightly weaker evidence.
    let strippedIndex: [String: [Int32]]
    /// Space-free names with number words as digits ("bbc1").
    let compactIndex: [String: [Int32]]
    let tokenIndex: [String: [Int32]]
    let prefixIndex: [String: [Int32]]

    static let threshold = 0.86
    static let countryBonus = 0.04
    static let countryPenalty = 0.06
    /// Fuzzy scoring is bounded per lookup so matching thousands of provider channels stays fast.
    static let maxCandidates = 300
    static let maxBucket = 4000

    func channel(epgID: String) -> IPTVOrgChannel? {
        let key = epgID.tunaTrimmed.split(separator: "@").first.map { String($0).lowercased() } ?? ""
        guard !key.isEmpty else { return nil }
        return byID[key].map { channels[Int($0)] }
    }

    /// Entries sharing tokens (rare tokens first) or the first three letters with the query.
    func candidates(for query: Parsed) -> [Int32] {
        var counts: [Int32: Int] = [:]
        let buckets = Set(query.tokens).compactMap { tokenIndex[$0] }.sorted { $0.count < $1.count }
        for (index, bucket) in buckets.enumerated() {
            // Very common tokens ("tv", "channel") only count when nothing rarer is shared.
            if index > 0 && bucket.count > Self.maxBucket { continue }
            for entry in bucket { counts[entry, default: 0] += 1 }
        }
        if let bucket = prefixIndex[String(query.compact.prefix(3))], bucket.count <= Self.maxBucket {
            for entry in bucket { counts[entry, default: 0] += 1 }
        }
        guard counts.count > Self.maxCandidates else { return Array(counts.keys) }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maxCandidates).map { $0.key }
    }

    func similarity(_ query: Parsed, scalars: [UInt32], _ entry: Entry) -> Double {
        // Channel numbers are identity: "BBC Two" is never "BBC Three", "beIN Sports 1" never "2".
        if query.numbers != entry.numbers { return 0 }
        let jaroWinkler = MetadataSupport.jaroWinkler(scalars, entry.scalars)
        // Soft token overlap: tokens count as shared when nearly identical ("sport" ~ "sports").
        var used = Set<Int>()
        var shared = 0.0
        for token in query.tokens {
            let tokenScalars = MetadataSupport.scalars(token)
            var bestIndex = -1
            var bestValue = 0.0
            for (index, other) in entry.tokens.enumerated() where !used.contains(index) {
                let value = token == other ? 1 : MetadataSupport.jaroWinkler(tokenScalars, MetadataSupport.scalars(other))
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }
            if bestIndex >= 0, bestValue >= 0.88 {
                used.insert(bestIndex)
                shared += bestValue
            }
        }
        let overlap = 2 * shared / Double(query.tokens.count + entry.tokens.count)
        return 0.5 * jaroWinkler + 0.5 * overlap
    }

    // MARK: - Normalization

    struct Parsed: Sendable {
        /// Normalized tokens with quality words kept.
        let full: String
        /// Normalized tokens without quality/backup/timeshift words.
        let stripped: String
        let tokens: [String]
        /// Space-free `stripped` with number words as digits.
        let compact: String
        let numbers: [String]
        /// Country implied by a prefix such as "UK:" (iptv-org spelling).
        let prefixCountry: String?
    }

    /// "UK: BBC One FHD" → "bbc one".
    static func normalize(_ name: String) -> String { parse(name).stripped }

    static func parse(_ name: String) -> Parsed {
        var text = name.tunaFolded
        var prefixCountry: String?
        // Leading tags: "UK:", "|UK|", "UK |", "[UK]", "(UK)", "UK -", "UK »", "VIP | UK | ...".
        for _ in 0..<3 {
            guard let (tag, rest) = splitLeadingTag(text) else { break }
            if prefixCountry == nil, let country = iptvOrgCountry(tag), !languageOnlyTags.contains(tag) { prefixCountry = country }
            text = rest
        }
        // Bracketed segments made only of noise ("(Backup)", "[FHD]", "(B)") are dropped; others keep their words.
        text = dropNoiseBrackets(text)

        var rawTokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { rawTokens.append(current) }
            current = ""
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "+" {
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if next.isNumber {
                    flush()
                    current = "+"
                } else {
                    flush()
                    rawTokens.append("plus")
                }
            } else if character == "&" {
                flush()
                rawTokens.append("and")
            } else if character == "'" || character == "’" {
                continue
            } else {
                flush()
            }
        }
        flush()

        // "+1" style timeshift markers never take part in matching (a timeshift feed shares the channel's identity).
        let full = rawTokens.filter { !$0.hasPrefix("+") }
        var tokens = full.filter { !noiseTokens.contains($0) }
        // A trailing country tag ("CNN US", "BBC One UK") is dropped when something else remains.
        if tokens.count > 1, let last = tokens.last, trailingCountryTags.contains(last) {
            tokens.removeLast()
            if prefixCountry == nil { prefixCountry = iptvOrgCountry(last) }
        }
        let fullText = full.joined(separator: " ")
        let strippedText = tokens.joined(separator: " ")
        let digits = tokens.map { numberWords[$0] ?? $0 }
        return Parsed(full: fullText, stripped: strippedText, tokens: tokens, compact: digits.joined(),
                      numbers: digits.filter { $0.allSatisfy(\.isNumber) }, prefixCountry: prefixCountry)
    }

    /// Splits "uk: bbc one" into ("uk", "bbc one") when the leading word is a known country/language/IPTV tag
    /// followed by a separator.
    static func splitLeadingTag(_ text: String) -> (String, String)? {
        let characters = Array(text)
        var index = 0
        let openers: Set<Character> = [" ", "|", "[", "(", "#", "*", "★", "▎", "•", "»", ":", "-", "{"]
        while index < characters.count, openers.contains(characters[index]) { index += 1 }
        let tagStart = index
        while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "/" {
            index += 1
        }
        let tag = String(characters[tagStart..<index])
        guard !tag.isEmpty, tag.count <= 6, knownTags.contains(tag) || iptvOrgCountries.contains(tag.uppercased()) else { return nil }
        var separatorIndex = index
        while separatorIndex < characters.count, characters[separatorIndex] == " " { separatorIndex += 1 }
        guard separatorIndex < characters.count else { return nil }
        let separator = characters[separatorIndex]
        let closers: Set<Character> = ["|", ":", "]", ")", "}", "»", "▎", "•", "-", "/"]
        guard closers.contains(separator) else { return nil }
        // "UK-Drama" style hyphenation is part of a name; a tag needs "UK -", "UK:", "|UK|" ...
        if separator == "-" && separatorIndex == index { return nil }
        let rest = String(characters[(separatorIndex + 1)...]).trimmingCharacters(in: CharacterSet(charactersIn: " |:]-»▎•"))
        guard !rest.isEmpty else { return nil }
        return (tag, rest)
    }

    static func dropNoiseBrackets(_ text: String) -> String {
        guard text.contains("(") || text.contains("[") || text.contains("{") else { return text }
        var result = ""
        var segment = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "[" || character == "{" {
                if depth == 0 { segment = "" } else { segment.append(character) }
                depth += 1
            } else if (character == ")" || character == "]" || character == "}") && depth > 0 {
                depth -= 1
                if depth == 0 {
                    let words = segment.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "+") }).map(String.init)
                    let isNoise = words.allSatisfy { noiseTokens.contains($0) || bracketNoise.contains($0) || $0.hasPrefix("+") }
                    if !isNoise { result += " " + segment + " " }
                } else {
                    segment.append(character)
                }
            } else if depth > 0 {
                segment.append(character)
            } else {
                result.append(character)
            }
        }
        if depth > 0 { result += " " + segment }
        return result
    }

    /// iptv-org country code for a provider/ISO code ("GB" → "UK"), nil when unknown.
    static func iptvOrgCountry(_ code: String) -> String? {
        let upper = code.tunaTrimmed.uppercased()
        if let mapped = countryAliases[upper] { return mapped }
        return iptvOrgCountries.contains(upper) ? upper : nil
    }

    static let noiseTokens: Set<String> = ["hd", "fhd", "uhd", "sd", "hq", "lq", "4k", "8k", "hevc", "h264", "h265", "x264", "x265",
                                           "hdr", "hdr10", "1080", "1080p", "1080i", "720", "720p", "2160p", "576p", "576i", "480p",
                                           "50fps", "60fps", "25fps", "fps", "backup", "bkp", "bk", "alt", "raw", "vip", "low", "mobile"]
    /// Words that are noise only inside brackets ("(B)", "(Main)", "[Multi]").
    static let bracketNoise: Set<String> = ["b", "main", "multi", "audio", "sub", "subs", "dub", "dubbed", "live", "test", "new",
                                            "geo", "blocked", "geoblocked", "not", "24", "7", "247", "1", "2", "3"]
    /// Prefix tags that are not countries but appear in front of IPTV names.
    static let knownTags: Set<String> = ["en", "eng", "usa", "uk", "ger", "fra", "fre", "ita", "esp", "spa", "tur", "ara", "arab",
                                         "por", "bra", "can", "aus", "ind", "pak", "rus", "pol", "nld", "dut", "swe", "nor", "dnk",
                                         "fin", "exyu", "latam", "latino", "vip", "4k", "uhd", "fhd", "hd", "sd", "hevc", "24/7",
                                         "ppv", "nordic", "baltic", "carib", "afr", "africa", "asia", "eu", "euro", "int", "intl",
                                         "multi", "kurd", "persian", "farsi", "ex", "xxx", "adult"]
    /// Prefix tags that name a language rather than a country (never a country hint).
    static let languageOnlyTags: Set<String> = ["en", "eng", "ar", "ara", "arab", "farsi", "persian", "kurd", "latino"]
    static let trailingCountryTags: Set<String> = ["uk", "us", "usa", "ca", "au", "nz", "ie", "de", "fr", "es", "it", "tr", "nl", "pl",
                                                   "pt", "br", "mx", "se", "no", "dk", "fi", "gr", "ro", "hu", "cz", "ru", "in", "pk"]
    static let countryAliases: [String: String] = ["GB": "UK", "USA": "US", "GER": "DE", "FRA": "FR", "FRE": "FR", "ITA": "IT",
                                                   "ESP": "ES", "SPA": "ES", "TUR": "TR", "POR": "PT", "BRA": "BR", "CAN": "CA",
                                                   "AUS": "AU", "IND": "IN", "PAK": "PK", "RUS": "RU", "POL": "PL", "NLD": "NL",
                                                   "DUT": "NL", "SWE": "SE", "NOR": "NO", "DNK": "DK", "FIN": "FI"]
    static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                                                "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
    /// Country codes used by iptv-org (ISO 3166-1 alpha-2, except "UK" for the United Kingdom).
    static let iptvOrgCountries: Set<String> = Set(("AF AX AL DZ AS AD AO AI AQ AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO "
        + "BQ BA BW BV BR IO VG BN BG BF BI KH CM CA CV KY CF TD CL CN CX CC CO KM CK CR HR CU CW CY CZ CD DK DJ DM DO TL EC EG SV "
        + "GQ ER EE ET FK FO FJ FI FR GF PF TF GA GM GE DE GH GI GR GL GD GP GU GT GG GN GW GY HT HM HN HK HU IS IN ID IR IQ IE IM "
        + "IL IT CI JM JP JE JO KZ KE KI XK KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU YT MX FM MD MC MN ME "
        + "MS MA MZ MM NA NR NP NL NC NZ NI NE NG NU NF KP MK MP NO OM PK PW PS PA PG PY PE PH PN PL PT PR QA CG RO RU RW RE BL SH "
        + "KN LC MF PM VC WS SM SA SN RS SC SL SG SX SK SI SB SO ZA GS KR SS ES LK SD SR SJ SZ SE CH SY ST TW TJ TZ TH TG TK TO TT "
        + "TN TR TM TC TV UM VI UG UA AE UK US UY UZ VU VA VE VN WF EH YE ZM ZW").split(separator: " ").map(String.init))
}
