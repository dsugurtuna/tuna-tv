import Foundation

/// Provider category names ("EN | MOVIES 4K", "TR | YERLİ FİLMLER", "XXX | Adult", "UK SPORTS ᴴᴰ") through the same
/// tag grammar in category mode: locale codes anywhere, kind words kept, quality / platform / adult picked up,
/// ALL-CAPS names title-cased for display.
enum CategoryParsing {
    static func parse(_ name: String, kind: StreamKind) -> CategoryHints {
        let p = NameParse(name: name, kind: .category, category: nil)
        p.runZones()
        p.categoryPasses()
        let parsed = p.parsedName(original: name)
        var clean = NameParse.render(p.toks, from: p.leadEnd, to: p.titleEnd, roles: .title)
        if clean.isEmpty { clean = NameParse.render(p.toks, from: p.leadEnd, to: p.n, roles: .tags) }
        if clean.isEmpty { clean = name.tunaTrimmed }
        var platform = parsed.platform
        if platform == nil {
            for t in p.toks where t.isWord && t.hasStrong(TagClass.platform) {
                for tag in t.tags {
                    if case .platform(let found) = tag.value { platform = found; break }
                }
                if platform != nil { break }
            }
        }
        let adult = parsed.isAdult || hasAdultWord(p.toks)
        var channelCategory: String?
        if kind == .live {
            channelCategory = adult ? ChannelCategory.xxx.rawValue : ChannelClassifier.category(forName: name)?.rawValue
        }
        return CategoryHints(cleanName: prettify(clean), languages: parsed.languages, countries: parsed.countries,
                             regions: parsed.regions, quality: parsed.quality, isAdult: adult, platform: platform,
                             genre: ChannelClassifier.genre(forName: name), channelCategory: channelCategory)
    }

    /// "ADULT" / "ADULTS" mark adult categories, except "Adult Swim" and "Young Adult".
    private static func hasAdultWord(_ toks: [Token]) -> Bool {
        for (i, t) in toks.enumerated() where t.isWord && t.has(TagClass.adult) {
            if i + 1 < toks.count && toks[i + 1].key == "SWIM" { continue }
            if i > 0 && toks[i - 1].key == "YOUNG" { continue }
            return true
        }
        return false
    }

    /// Display forms for all-caps words that are not simply capitalized.
    private static let specialWords: [String: String] = {
        var map: [String: String] = [:]
        for word in ("TV HD FHD UHD 4K 8K HDR VIP PPV VOD USA UK BBC ITV CNN HBO NBA NFL NHL MLB UFC WWE MMA ESPN DAZN TRT ATV "
            + "MBC OSN RTL ZDF ARD NPO RAI TVE NHK KBS SBS MTV TNT AMC BET CBS NBC ABC FOX TOD SSC EPL UEFA FIFA F1 IPTV "
            + "3D TLC CNBC MSNBC HGTV QVC DW TV5 TF1 M6 SVT NRK DR YLE ERT RTP RTS HRT RTV BTV OTV LBC NTV HTV VTV PTV ARY "
            + "GEO STV TVN TVP RTL2 SAT1 BBC1 BBC2 ITV1 ITV2 ITV3 ITV4 S4C EWTN").split(separator: " ") {
            map[String(word)] = String(word)
        }
        let mixed: [(String, String)] = [("BEIN", "beIN"), ("SKY", "Sky"), ("EXXEN", "Exxen"), ("BLUTV", "BluTV"),
                                         ("NETFLIX", "Netflix"), ("DISNEY+", "Disney+"), ("TABII", "Tabii"),
                                         ("PUHUTV", "puhutv"), ("DSTV", "DStv"), ("24/7", "24/7"), ("TV+", "TV+"),
                                         ("MOTOGP", "MotoGP"), ("NASCAR", "NASCAR"), ("IMDB", "IMDb")]
        for (key, value) in mixed { map[key] = value }
        return map
    }()

    /// Title-cases names without lowercase letters: "YERLİ FİLMLER" -> "Yerli Filmler", "UK SPORTS" -> "UK Sports".
    static func prettify(_ name: String) -> String {
        var hasLetter = false
        for scalar in name.unicodeScalars where TextFold.isLetter(scalar) {
            hasLetter = true
            if TextFold.isLowercase(scalar) { return name }
        }
        guard hasLetter else { return name }
        var words: [String] = []
        for word in name.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if let special = specialWords[w] {
                words.append(special)
                continue
            }
            var letters = 0
            for scalar in w.unicodeScalars where TextFold.isLetter(scalar) { letters += 1 }
            if letters == 0 || w.unicodeScalars.count <= 2 {
                words.append(w)
                continue
            }
            // Hyphenated parts are capitalized separately ("SCI-FI" -> "Sci-Fi").
            let parts = w.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                let p = String(part)
                if let special = specialWords[p] { return special }
                return p.unicodeScalars.count <= 1 ? p : TextFold.capitalizeWord(p)
            }
            words.append(parts.joined(separator: "-"))
        }
        return words.joined(separator: " ")
    }
}
