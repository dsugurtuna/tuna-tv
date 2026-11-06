import Foundation

// =====================================================================================================
// Stage 3 of the tag grammar: the TAG DICTIONARY and CLASSIFY. One merged dictionary lookup per token
// (every meaning of a word in one entry) plus a few hand-written pattern scanners for S01E02 / 1080p /
// +1 / years. Mirrors `classify_key` and `classify_tokens` of the Python reference.
// =====================================================================================================

/// Locale meaning of a tag: ISO 639-1 languages, ISO 3166-1 alpha-2 countries and region codes.
struct LocaleTag: Sendable {
    let languages: [String]
    let countries: [String]
    let regions: [String]
    /// Also an ordinary word ("IT", "NO", "IS" ...): only trusted in tag positions.
    let ambiguous: Bool
}

/// One meaning of a token.
enum TagValue: Sendable {
    case seasonEpisode(season: Int, episode: Int)
    case season(Int)
    case episode(Int)
    case quality(Quality)
    case fps(Int)
    case adult
    case timeshift(Int)
    case source(SourceTag)
    case hdr(HDRFormat)
    case codec(VideoCodec)
    case threeD
    case audioFormat
    case audio(AudioMarker, String?)
    case locale(LocaleTag)
    case platform(String)
    case backup
    case event
    case kindWord(StreamKind)
    case promo
    case seasonWord
    case episodeWord
    case year(Int)
    case flag(String)
}

/// Bit masks for `TagValue` classes (plain integers: cheap in debug builds).
enum TagClass {
    static let seasonEpisode: UInt32 = 1 << 0
    static let season: UInt32 = 1 << 1
    static let episode: UInt32 = 1 << 2
    static let quality: UInt32 = 1 << 3
    static let fps: UInt32 = 1 << 4
    static let adult: UInt32 = 1 << 5
    static let timeshift: UInt32 = 1 << 6
    static let source: UInt32 = 1 << 7
    static let hdr: UInt32 = 1 << 8
    static let codec: UInt32 = 1 << 9
    static let threeD: UInt32 = 1 << 10
    static let audioFormat: UInt32 = 1 << 11
    static let audio: UInt32 = 1 << 12
    static let locale: UInt32 = 1 << 13
    static let platform: UInt32 = 1 << 14
    static let backup: UInt32 = 1 << 15
    static let event: UInt32 = 1 << 16
    static let kindWord: UInt32 = 1 << 17
    static let promo: UInt32 = 1 << 18
    static let seasonWord: UInt32 = 1 << 19
    static let episodeWord: UInt32 = 1 << 20
    static let year: UInt32 = 1 << 21
    static let flag: UInt32 = 1 << 22

    /// Technical tags removable from the middle of a title.
    static let strongTech: UInt32 = quality | source | hdr | codec | fps | threeD | audioFormat
    /// Tags the trailing zone may strip.
    static let vocabulary: UInt32 = strongTech | timeshift | adult | audio | platform | backup | promo | event
    static let seriesMarkers: UInt32 = seasonEpisode | season | episode

    static func of(_ value: TagValue) -> UInt32 {
        switch value {
        case .seasonEpisode: return seasonEpisode
        case .season: return season
        case .episode: return episode
        case .quality: return quality
        case .fps: return fps
        case .adult: return adult
        case .timeshift: return timeshift
        case .source: return source
        case .hdr: return hdr
        case .codec: return codec
        case .threeD: return threeD
        case .audioFormat: return audioFormat
        case .audio: return audio
        case .locale: return locale
        case .platform: return platform
        case .backup: return backup
        case .event: return event
        case .kindWord: return kindWord
        case .promo: return promo
        case .seasonWord: return seasonWord
        case .episodeWord: return episodeWord
        case .year: return year
        case .flag: return flag
        }
    }
}

struct Tag: Sendable {
    let value: TagValue
    let ambiguous: Bool
    let cls: UInt32

    init(_ value: TagValue, ambiguous: Bool = false) {
        self.value = value
        self.ambiguous = ambiguous
        self.cls = TagClass.of(value)
    }

    func with(ambiguous: Bool) -> Tag { Tag(value, ambiguous: ambiguous) }
}

/// Internal parse modes. Episodes parse like series; provider categories have their own rules.
enum ParseKind {
    case live, movie, series, category

    init(_ kind: StreamKind) {
        switch kind {
        case .live: self = .live
        case .movie: self = .movie
        case .series, .episode: self = .series
        }
    }

    var isVOD: Bool { self == .movie || self == .series }
}

struct LexEntry {
    var tags: [Tag] = []
    /// First word of a bigram ("DOLBY" of "DOLBY VISION").
    var bigramHead = false
}

enum Lexicon {
    static let minYear = 1900
    static let maxYear = 2035

    /// Folded-uppercase word -> every meaning.
    static let entries: [String: LexEntry] = build()

    /// "A B" -> merged key, looked up again ("DOLBY VISION" -> "DOLBYVISION").
    static let bigrams: [String: String] = [
        "DOLBY VISION": "DOLBYVISION", "BLU RAY": "BLURAY", "WEB DL": "WEB-DL", "WEB RIP": "WEBRIP",
        "FULL HD": "FULLHD", "ULTRA HD": "ULTRAHD", "HDR10 PLUS": "HDR10+", "MULTI SUB": "MULTI-SUB",
        "MULTI SUBS": "MULTI-SUB", "MULTI AUDIO": "MULTI-AUDIO", "DUAL AUDIO": "DUAL-AUDIO", "PRIME VIDEO": "PRIMEVIDEO",
        "AMAZON PRIME": "PRIMEVIDEO", "DISNEY PLUS": "DISNEYPLUS", "PARAMOUNT PLUS": "PARAMOUNTPLUS", "HBO MAX": "HBOMAX",
        "APPLE TV+": "APPLETV+", "APPLE TV": "APPLETV", "BLU TV": "BLUTV", "PUHU TV": "PUHUTV", "DTS HD": "DTS-HD",
        "DOLBY ATMOS": "ATMOS", "HD CAM": "HDCAM", "HD TS": "HDTS", "FOR ADULTS": "ADULTSONLY", "ADULTS ONLY": "ADULTSONLY",
        "ADULT ONLY": "ADULTSONLY", "RED LIGHT": "REDLIGHT", "LIVE EVENT": "EVENT", "LIVE EVENTS": "EVENTS", "SUB ESP": "VOSE",
        "SUB ITA": "SUBITA", "ENG SUB": "ESUB", "ENG SUBS": "ESUB", "BACK UP": "BACKUP", "PT BR": "PTBR", "EX YU": "EXYU",
        "TV SHOWS": "TVSHOWS", "SOUTH AFRICA": "SOUTHAFRICA", "COSTA RICA": "COSTARICA", "PUERTO RICO": "PUERTORICO",
        "ULTRA 4K": "4K", "4K UHD": "4KUHD", "UHD 4K": "UHD4K", "HDR 10": "HDR10", "HDR 10+": "HDR10+", "H 265": "H265",
        "H 264": "H264", "3D SBS": "3D-SBS", "DUAL LANG": "DUAL-AUDIO", "TURKCE DUBLAJ": "TRDUBLAJ",
        "TURKCE ALTYAZI": "TRALTYAZI", "TURKCE ALTYAZILI": "TRALTYAZI", "TR DUBLAJ": "TRDUBLAJ", "TR ALTYAZI": "TRALTYAZI",
        "TR ALTYAZILI": "TRALTYAZI", "60 FPS": "60FPS", "50 FPS": "50FPS",
    ]
    /// Bigrams whose merge keeps the ambiguity of its parts.
    static let ambiguousBigrams: Set<String> = ["LIVE EVENT", "LIVE EVENTS", "APPLE TV"]
    /// "Canal+1" is a brand, not a timeshift.
    static let plusBrands: Set<String> = ["CANAL", "DISNEY", "APPLE", "APPLETV", "TV", "PARAMOUNT", "STAR", "MOVISTAR", "OSN",
                                          "ESPN", "DISCOVERY", "MGM", "AMC", "RTL", "BET", "HD", "FHD", "UHD", "HDR10", "HDR",
                                          "D", "P", "A", "C", "M", "DD", "NOW", "SKY", "BEIN", "ATV"]
    static let seasonWords: Set<String> = Set(("SEASON SAISON STAFFEL TEMPORADA SEZON SEZONA STAGIONE SEIZOEN SASONG SAESON "
        + "SESONG KAUSI SEZONUL СЕЗОН الموسم").split(separator: " ").map { TextFold.upperKey(String($0)) })
    static let episodeWords: Set<String> = Set(("EPISODE EPISODES EP EPS EPISODIO EPISODIOS FOLGE BOLUM CAPITULO CAP AFLEVERING "
        + "ODCINEK EPISOD EPIZOD СЕРИЯ ЭПИЗОД الحلقة حلقة").split(separator: " ").map { TextFold.upperKey(String($0)) })
    /// "AR" means Argentina in a Latin American context.
    static let argentina = LocaleTag(languages: ["es"], countries: ["AR"], regions: ["LATAM"], ambiguous: false)
    /// Trailing locale codes too common as words/series suffixes to strip from VOD titles.
    static let trailingLocaleExclusions: Set<String> = ["US", "USA", "UK", "LA", "IN", "IS", "IT", "NO", "ME", "BE", "AT",
                                                        "BY", "ID", "MY", "AM", "SE", "SI", "AL", "HE", "EL"]

    // MARK: Lookup

    /// Tags of one folded key: dictionary first, then the pattern scanners.
    static func classify(_ key: String) -> [Tag] {
        if let entry = entries[key], !entry.tags.isEmpty { return entry.tags }
        return patternTags(key)
    }

    // MARK: Patterns (hand scanners, no regex)

    static func patternTags(_ key: String) -> [Tag] {
        let bytes = Array(key.utf8)
        let n = bytes.count
        guard n > 0 else { return [] }
        // Fast path: pure numbers (years, channel numbers).
        var allDigits = true
        var anyDigit = false
        var x = 0
        while x < n {
            let c = bytes[x]
            if c >= 48 && c <= 57 { anyDigit = true } else { allDigits = false }
            x += 1
        }
        guard anyDigit else { return [] }
        if allDigits {
            if n == 4 && ((bytes[0] == 49 && bytes[1] == 57) || (bytes[0] == 50 && bytes[1] == 48)) {
                let year = Int(bytes[0] - 48) * 1000 + Int(bytes[1] - 48) * 100 + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
                return [Tag(.year(year))]
            }
            return []
        }
        var b: [UInt32] = []
        b.reserveCapacity(n)
        let loop1Items = Array(key.unicodeScalars)
        var loop1 = 0
        while loop1 < loop1Items.count {
            let s = loop1Items[loop1]
            loop1 += 1
            b.append(s.value)
        }
        return patternTagsSlow(b, key)
    }

    private static func patternTagsSlow(_ b: [UInt32], _ key: String) -> [Tag] {
        let n = b.count
        if let (s, e) = matchSE(b) { return [Tag(.seasonEpisode(season: s, episode: e))] }
        // 1x01
        if let (s, i) = digits(b, 0, 1, 2), i < n, b[i] == 88, let (e, j) = digits(b, i + 1, 2, 3), j == n, s <= 30 {
            return [Tag(.seasonEpisode(season: s, episode: e))]
        }
        // S01
        if b[0] == 83, let (s, i) = digits(b, 1, 1, 2), i == n { return [Tag(.season(s))] }
        // E05, EP05, EP.5
        if b[0] == 69 {
            var i = 1
            if i < n && b[i] == 80 { i += 1; if i < n && b[i] == 46 { i += 1 } }
            if let (e, j) = digits(b, i, 1, 4), j == n { return [Tag(.episode(e))] }
        }
        // 1080p, 720i, 1080p60
        if let (h, i) = digits(b, 0, 3, 4), i < n, b[i] == 80 || b[i] == 73 {
            let fpsPart = digits(b, i + 1, 2, 3)
            if i + 1 == n || fpsPart?.1 == n, [240, 360, 480, 540, 576, 720, 1080, 1440, 2160, 4320].contains(h) {
                var out = [Tag(.quality(Quality.fromLines(h)))]
                if let (f, _) = fpsPart { out.append(Tag(.fps(f))) }
                return out
            }
        }
        // 60FPS
        if let (f, i) = digits(b, 0, 2, 3), n - i == 3, b[i] == 70, b[i + 1] == 80, b[i + 2] == 83 { return [Tag(.fps(f))] }
        if key == "18+" || key == "+18" || key == "21+" { return [Tag(.adult)] }
        // +1, +2H, -1H (timeshift; +18 is adult)
        if b[0] == 43 || b[0] == 45, let (h, i) = digits(b, 1, 1, 2) {
            let hasH = i < n && b[i] == 72
            if (i == n && b[0] == 43) || (hasH && i + 1 == n), h != 18, h >= 1, h <= 48 {
                return [Tag(.timeshift(b[0] == 45 ? -h : h))]
            }
        }
        // 1.SEZON / SEZON1 / ALT2 / PPV1 / PLUS1
        if let (num, i) = digits(b, 0, 1, 3) {
            var j = i
            if j < n && b[j] == 46 { j += 1 }
            if j < n, allLetters(b, j, n) {
                let word = Tokenizer.makeString(b, j, n)
                if seasonWords.contains(word) { return [Tag(.season(num))] }
                if episodeWords.contains(word) { return [Tag(.episode(num))] }
            }
        }
        var letterEnd = 0
        while letterEnd < n && isUpperLetter(b[letterEnd]) { letterEnd += 1 }
        if letterEnd > 0 {
            var j = letterEnd
            if j < n && b[j] == 46 { j += 1 }
            if let (num, k) = digits(b, j, 1, 3), k == n {
                let word = Tokenizer.makeString(b, 0, letterEnd)
                if seasonWords.contains(word) { return [Tag(.season(num))] }
                if episodeWords.contains(word) { return [Tag(.episode(num))] }
                if word == "ALT" || word == "BACKUP" || word == "BKP" || word == "B" { return [Tag(.backup)] }
                if word == "PPV" || word == "EVENT" { return [Tag(.event)] }
                if word == "PLUS" && num >= 1 && num <= 48 { return [Tag(.timeshift(num))] }
            }
        }
        return []
    }

    private static func matchSE(_ b: [UInt32]) -> (Int, Int)? {
        let n = b.count
        guard n >= 4, b[0] == 83, let (s, i0) = digits(b, 1, 1, 2) else { return nil }
        var i = i0
        if i < n && (b[i] == 32 || b[i] == 46 || b[i] == 95 || b[i] == 45) { i += 1 }
        guard i < n, b[i] == 69 else { return nil }
        i += 1
        if i < n && b[i] == 80 { i += 1 }
        guard let (e, i1) = digits(b, i, 1, 4) else { return nil }
        i = i1
        if i == n { return (s, e) }
        if b[i] == 45 { i += 1 }
        if i < n && b[i] == 69 { i += 1 }
        guard let (_, i2) = digits(b, i, 1, 4), i2 == n else { return nil }
        return (s, e)
    }

    /// Reads `min...max` ASCII digits at `start`; nil if fewer than `min`. Greedy, stops at `max`.
    private static func digits(_ b: [UInt32], _ start: Int, _ min: Int, _ max: Int) -> (Int, Int)? {
        var i = start
        var value = 0
        while i < b.count && i - start < max && b[i] >= 48 && b[i] <= 57 {
            value = value * 10 + Int(b[i] - 48)
            i += 1
        }
        return i - start >= min ? (value, i) : nil
    }

    private static func isUpperLetter(_ c: UInt32) -> Bool { (c >= 65 && c <= 90) || (c >= 0x410 && c <= 0x42F) }

    private static func allLetters(_ b: [UInt32], _ a: Int, _ e: Int) -> Bool {
        var k = a
        while k < e {
            if !isUpperLetter(b[k]) { return false }
            k += 1
        }
        return true
    }

    // MARK: Dictionary data

    private struct Builder {
        var entries: [String: LexEntry] = [:]

        mutating func add(_ words: String, _ value: TagValue, ambiguous: String = "", all: Bool = false) {
            let amb = Set(ambiguous.split(separator: " ").map { TextFold.upperKey(String($0)) })
            for word in words.split(separator: " ") {
                let key = TextFold.upperKey(String(word))
                entries[key, default: LexEntry()].tags.append(Tag(value, ambiguous: all || amb.contains(key)))
            }
        }

        mutating func loc(_ words: String, _ languages: [String], _ countries: [String] = [], _ regions: [String] = [],
                          amb: Bool = false) {
            let tag = LocaleTag(languages: languages, countries: countries, regions: regions, ambiguous: amb)
            for word in words.split(separator: " ") {
                let key = TextFold.upperKey(String(word))
                entries[key, default: LexEntry()].tags.append(Tag(.locale(tag), ambiguous: amb))
            }
        }

        mutating func head(_ key: String) { entries[key, default: LexEntry()].bigramHead = true }
    }

    private static func build() -> [String: LexEntry] {
        var b = Builder()
        // Quality (the reference's tier tables).
        b.add("4K UHD 2160P 2160I 4KUHD UHD4K ULTRAHD 4K+ UHD+ 8K 4320P", .quality(.uhd))
        b.add("FHD FULLHD 1080P 1080I HD+ FHD+ 2K QHD 1440P", .quality(.fhd), ambiguous: "HD+ 2K")
        b.add("HD 720P 720I", .quality(.hd), ambiguous: "HD")
        b.add("SD SDTV 576P 576I 480P 480I 360P 240P LQ", .quality(.sd), ambiguous: "SD LQ")
        // Sources.
        b.add("BLURAY BLU-RAY BDRIP BRRIP BD BD25 BD50 BDMV BLURAYRIP", .source(.bluray), ambiguous: "BD")
        b.add("REMUX BDREMUX UHDREMUX", .source(.remux))
        b.add("WEB-DL WEBDL WEB AMZN-DL", .source(.webdl), ambiguous: "WEB")
        b.add("WEBRIP WEB-RIP HDRIP", .source(.webrip))
        b.add("HDTV PDTV TVRIP SATRIP DVB DSR HDTVRIP", .source(.hdtv), ambiguous: "DVB DSR")
        b.add("DVD DVDRIP DVD5 DVD9 DVDR", .source(.dvd))
        b.add("CAM HDCAM CAMRIP CAM-RIP", .source(.cam), ambiguous: "CAM")
        b.add("TS HDTS TELESYNC HD-TS TC HDTC TELECINE PDVD", .source(.telesync), ambiguous: "TS TC")
        b.add("SCR SCREENER DVDSCR BDSCR WEBSCR R5", .source(.screener), ambiguous: "SCR R5")
        // HDR / codecs / 3D / audio formats.
        b.add("HDR", .hdr(.hdr))
        b.add("HDR10", .hdr(.hdr10))
        b.add("HDR10+ HDR10PLUS HDR+", .hdr(.hdr10Plus))
        b.add("DV DOVI DOLBYVISION", .hdr(.dolbyVision), ambiguous: "DV")
        b.add("HLG", .hdr(.hlg))
        b.add("HEVC H265 H.265 X265 H-265", .codec(.hevc))
        b.add("H264 H.264 X264 AVC H-264", .codec(.h264), ambiguous: "AVC")
        b.add("AV1", .codec(.av1))
        b.add("3D SBS HSBS H-SBS HOU H-OU 3D-SBS 3DSBS", .threeD, ambiguous: "SBS HOU")
        b.add("ATMOS TRUEHD DTS DTS-HD DTSHD DTS-X DTSX DD5.1 DD+ DDP DDP5.1 EAC3 E-AC3 AC3 AAC FLAC 5.1 7.1 2.0",
              .audioFormat, ambiguous: "DTS AAC 2.0 5.1 7.1")
        // Audio markers (language-implying ones carry the language).
        b.add("DUB DUBBED DUBBING DUBB", .audio(.dubbed, nil))
        b.add("DUBLAJ DUBLAJLI TRDUBLAJ", .audio(.dubbed, "tr"))
        b.add("DUBLADO", .audio(.dubbed, "pt"))
        b.add("DOBLADO", .audio(.dubbed, "es"))
        b.add("DOPPIATO", .audio(.dubbed, "it"))
        b.add("LEKTOR", .audio(.dubbed, "pl"))
        b.add("ДУБЛЯЖ MVO DVO AVO", .audio(.dubbed, "ru"))
        b.add("SYNCHRO SYNCHRONISIERT", .audio(.dubbed, "de"))
        b.add("VF VFF VFQ VFI TRUEFRENCH", .audio(.dubbed, "fr"))
        b.add("SUB SUBS SUBBED SUBTITLED SUBTITLE SUBTITLES ESUB ESUBS", .audio(.subtitled, nil), ambiguous: "SUB")
        b.add("ALTYAZI ALTYAZILI TRALTYAZI", .audio(.subtitled, "tr"))
        b.add("VOST VOSTFR", .audio(.subtitled, "fr"))
        b.add("VOSE VOS SUBTITULADO SUBTITULADA", .audio(.subtitled, "es"), ambiguous: "VOS")
        b.add("LEG LEGENDADO LEGENDA", .audio(.subtitled, "pt"), ambiguous: "LEG")
        b.add("NAPISY", .audio(.subtitled, "pl"))
        b.add("СУБТИТРЫ", .audio(.subtitled, "ru"))
        b.add("SUBITA", .audio(.subtitled, "it"))
        b.add("OMU OMDU", .audio(.subtitled, "de"))
        b.add("MULTI MULTI-AUDIO MULTIAUDIO MULTILANG MULTI-LANG DUAL DUALAUDIO DUAL-AUDIO DL MSUB MULTISUB MULTI-SUB "
              + "MULTI-SUBS MULTISUBS", .audio(.multiAudio, nil), ambiguous: "DL DUAL")
        b.add("VO OV ORIGINAL ORG VOSTA", .audio(.original, nil), ambiguous: "VO OV ORIGINAL ORG")
        // Languages / countries / regions.
        addLocales(&b)
        // Streaming platforms.
        let platforms: [(String, String)] = [
            ("NF NFLX NETFLIX", "Netflix"), ("AMZ AMZN AMAZON PRIME PRIMEVIDEO", "Prime Video"),
            ("DSNP DSNY DISNEY+ DISNEYPLUS D+", "Disney+"), ("HMAX HBOMAX HBO MAX", "HBO Max"),
            ("ATVP ATV+ APPLETV+ APPLE+ APPLETV", "Apple TV+"), ("HULU", "Hulu"),
            ("PARAMOUNT+ PMTP P+ PARAMOUNTPLUS", "Paramount+"), ("EXXEN", "Exxen"), ("BLUTV", "BluTV"), ("GAIN", "Gain"),
            ("TABII", "Tabii"), ("PCOK PEACOCK", "Peacock"), ("HOTSTAR", "Disney+ Hotstar"), ("STAR+", "Star+"),
            ("CRAVE", "Crave"), ("STARZ", "Starz"), ("MUBI", "MUBI"), ("ZEE5", "ZEE5"), ("SONYLIV", "SonyLIV"),
            ("SHAHID", "Shahid"), ("OSN OSN+", "OSN+"), ("TOD", "TOD"), ("PUHU PUHUTV", "puhutv"), ("VIAPLAY", "Viaplay"),
            ("SKYSHOWTIME", "SkyShowtime"), ("DISCOVERY+", "discovery+"), ("MGM+", "MGM+"), ("AMC+", "AMC+"),
            ("BRITBOX", "BritBox"), ("RTL+", "RTL+"), ("JOYN", "Joyn"), ("MOVISTAR+", "Movistar+"), ("CANAL+", "Canal+"),
            ("CRUNCHYROLL", "Crunchyroll"), ("STAN", "Stan"), ("IQIYI", "iQIYI"), ("VIU", "Viu"), ("SHOWTIME", "Showtime"),
            ("BEIN", "beIN"),
        ]
        let platformAmbiguous = "MAX STAN GAIN PRIME HBO TOD AMAZON APPLETV VIU CRAVE STARZ SHOWTIME D+ P+ BEIN"
        for (words, name) in platforms { b.add(words, .platform(name), ambiguous: platformAmbiguous) }
        // Adult, backup, events, kind words, promo words.
        b.add("XXX ADULT ADULTS ADULTSONLY ADULTO ADULTOS ADULTE ADULTES ERWACHSENE YETISKIN PORN PORNO EROTIC EROTICA "
              + "EROTIK EROTICO EROTIQUE HENTAI PLAYBOY HUSTLER BRAZZERS PENTHOUSE DORCEL REDLIGHT 18+ +18 21+ للكبار ВЗРОСЛЫЕ",
              .adult, ambiguous: "ADULT ADULTS")
        b.add("BACKUP BACK-UP BKP BCK BAK ALT ALT1 ALT2 ALT3 ALTERNATE ALTERNATIVE RESERVE RESERVA REZERV YEDEK SECOURS "
              + "ERSATZ MIRROR B", .backup, ambiguous: "ALT B MIRROR RESERVE")
        b.add("PPV EVENT EVENTS", .event, ambiguous: "EVENT EVENTS")
        b.add("VOD MOVIES MOVIE FILMS FILM FILME FILMLER FILMLERI FILMES PELICULAS PELICULA CINE CINEMA KINO AFLAM "
              + "افلام أفلام فيلم", .kindWord(.movie), all: true)
        b.add("SERIES SERIE SERIEN SERIALS DIZI DIZILER DIZILERI SHOWS TVSHOWS TELENOVELAS NOVELAS MUSALSALAT "
              + "مسلسلات مسلسل", .kindWord(.series), all: true)
        b.add("LIVE CHANNELS KANALLAR ULUSAL", .kindWord(.live), all: true)
        b.add("VIP PREMIUM PRE PREM NEW NEU YENI NUEVO NOUVEAU HOT TOP TOP10 TRENDING POPULAR EXCLUSIVE EXCLU RAW LITE "
              + "MOBILE LOW TEST FREE OK UP COOL UPDATED UPDATE COMPLETE EXTENDED REMASTERED UNCUT UNRATED THEATRICAL IMAX "
              + "PROPER REPACK LIMITED INTERNAL SBS HSBS H-SBS HOU H-OU 10BIT 8BIT 12BIT HQ HIGH VS", .promo,
              ambiguous: "NEW HOT TOP FREE OK UP COOL LOW HIGH RAW LITE MOBILE TEST PRE COMPLETE LIMITED INTERNAL PROPER "
                + "VS IMAX UPDATE UPDATED HQ")
        for word in seasonWords { b.entries[word, default: LexEntry()].tags.append(Tag(.seasonWord, ambiguous: true)) }
        for word in episodeWords { b.entries[word, default: LexEntry()].tags.append(Tag(.episodeWord, ambiguous: true)) }
        for pair in bigrams.keys {
            if let first = pair.split(separator: " ").first { b.head(String(first)) }
        }
        return b.entries
    }

    private static func addLocales(_ b: inout Builder) {
        b.loc("EN ENG ENGLISH INGLES ANGLAIS", ["en"])
        b.loc("UK GB GBR BRIT BRITISH", ["en"], ["GB"])
        b.loc("US USA AMERICA", ["en"], ["US"])
        b.loc("CA CANADA", ["en"], ["CA"])
        b.loc("CAN", ["en"], ["CA"], amb: true)
        b.loc("AU AUS AUSTRALIA", ["en"], ["AU"])
        b.loc("NZ", ["en"], ["NZ"])
        b.loc("IE IRL IRELAND", ["en"], ["IE"])
        b.loc("CARIB CARIBBEAN CARIBE", ["en"], [], ["CARIB"])
        b.loc("JM JAM JAMAICA", ["en"], ["JM"], ["CARIB"])
        b.loc("TT TRINIDAD", ["en"], ["TT"], ["CARIB"])
        b.loc("TR TUR TURK TURKISH TURKCE TURKIYE TURKEY TURKIA", ["tr"], ["TR"])
        b.loc("AR ARA ARB ARAB ARABIC ARABIA ARABE العربية عربي", ["ar"], [], ["ARAB"])
        b.loc("MENA GULF KHALEEJ GCC MAGHREB", ["ar"], [], ["ARAB"])
        b.loc("KSA SA SAUDI", ["ar"], ["SA"], ["ARAB"])
        b.loc("AE UAE EMIRATES", ["ar"], ["AE"], ["ARAB"])
        b.loc("EG EGY EGYPT MASR", ["ar"], ["EG"], ["ARAB"])
        b.loc("MAROC MOROCCO", ["ar"], ["MA"], ["ARAB", "AFRICA"])
        b.loc("MA", ["ar"], ["MA"], ["ARAB", "AFRICA"], amb: true)
        b.loc("DZ ALG ALGERIE ALGERIA", ["ar"], ["DZ"], ["ARAB", "AFRICA"])
        b.loc("TN TUN TUNISIE TUNISIA", ["ar"], ["TN"], ["ARAB", "AFRICA"])
        b.loc("LB LEB LIBAN LEBANON", ["ar"], ["LB"], ["ARAB"])
        b.loc("IQ IRQ IRAQ", ["ar"], ["IQ"], ["ARAB"])
        b.loc("SY SYR SYRIA", ["ar"], ["SY"], ["ARAB"])
        b.loc("JOR JORDAN", ["ar"], ["JO"], ["ARAB"])
        b.loc("JO", ["ar"], ["JO"], ["ARAB"], amb: true)
        b.loc("KW KUW KUWAIT", ["ar"], ["KW"], ["ARAB"])
        b.loc("QA QAT QATAR", ["ar"], ["QA"], ["ARAB"])
        b.loc("OMAN", ["ar"], ["OM"], ["ARAB"])
        b.loc("OM", ["ar"], ["OM"], ["ARAB"], amb: true)
        b.loc("BH BAHRAIN", ["ar"], ["BH"], ["ARAB"])
        b.loc("YEM YEMEN", ["ar"], ["YE"], ["ARAB"])
        b.loc("YE", ["ar"], ["YE"], ["ARAB"], amb: true)
        b.loc("PALESTINE", ["ar"], ["PS"], ["ARAB"])
        b.loc("PS PAL", ["ar"], ["PS"], ["ARAB"], amb: true)
        b.loc("LY LBY LIBYA", ["ar"], ["LY"], ["ARAB", "AFRICA"])
        b.loc("SUDAN", ["ar"], ["SD"], ["ARAB", "AFRICA"])
        b.loc("KU KUR KURD KURDISH KURDI KURDISTAN", ["ku"])
        b.loc("IR IRN IRAN", ["fa"], ["IR"])
        b.loc("FAR FARSI PERSIAN", ["fa"])
        b.loc("FA", ["fa"], [], [], amb: true)
        b.loc("AF AFG AFGHAN AFGHANISTAN", ["fa", "ps"], ["AF"])
        b.loc("EXYU EX-YU YU YUG BALKAN", ["sr", "hr", "bs"], [], ["EXYU"])
        b.loc("RS SRB SRBIJA SERBIA", ["sr"], ["RS"], ["EXYU"])
        b.loc("HR CRO HRV HRVATSKA CROATIA", ["hr"], ["HR"], ["EXYU"])
        b.loc("BA BIH BOSNA BOSNIA", ["bs"], ["BA"], ["EXYU"])
        b.loc("MNE CG MONTENEGRO", ["sr"], ["ME"], ["EXYU"])
        b.loc("ME", ["sr"], ["ME"], ["EXYU"], amb: true)
        b.loc("MK MKD MAKEDONIJA MACEDONIA", ["mk"], ["MK"], ["EXYU"])
        b.loc("SLO SLOVENIJA SLOVENIA", ["sl"], ["SI"], ["EXYU"])
        b.loc("SI", ["sl"], ["SI"], ["EXYU"], amb: true)
        b.loc("ALB SHQIP ALBANIA", ["sq"], ["AL"])
        b.loc("AL", ["sq"], ["AL"], amb: true)
        b.loc("XK KOS KOSOVO", ["sq"], ["XK"])
        b.loc("NORDIC NORDICS NORD SCANDINAVIA SCANDI NORDEN", [], [], ["NORDIC"])
        b.loc("SE SWE SWEDEN SVERIGE SV SVE SWEDISH", ["sv"], ["SE"], ["NORDIC"])
        b.loc("DK DAN DANSK DENMARK DANISH", ["da"], ["DK"], ["NORDIC"])
        b.loc("DEN DA", ["da"], ["DK"], ["NORDIC"], amb: true)
        b.loc("NORGE NORWAY NORSK NORWEGIAN", ["no"], ["NO"], ["NORDIC"])
        b.loc("NO NOR", ["no"], ["NO"], ["NORDIC"], amb: true)
        b.loc("FI SUOMI FINLAND FINNISH", ["fi"], ["FI"], ["NORDIC"])
        b.loc("FIN", ["fi"], ["FI"], ["NORDIC"], amb: true)
        b.loc("ISL ICELAND", ["is"], ["IS"], ["NORDIC"])
        b.loc("IS", ["is"], ["IS"], ["NORDIC"], amb: true)
        b.loc("BALTIC BALTICS", [], [], ["BALTIC"])
        b.loc("LT LTU LIETUVA LITHUANIA", ["lt"], ["LT"], ["BALTIC"])
        b.loc("LV LVA LATVIJA LATVIA", ["lv"], ["LV"], ["BALTIC"])
        b.loc("EE EESTI ESTONIA", ["et"], ["EE"], ["BALTIC"])
        b.loc("EST", ["et"], ["EE"], ["BALTIC"], amb: true)
        b.loc("LATAM LATINO LATINA LAT HISPAM LATINOAMERICA", ["es"], [], ["LATAM"])
        b.loc("LA LATIN", ["es"], [], ["LATAM"], amb: true)
        b.loc("MX MEX MEXICO", ["es"], ["MX"], ["LATAM"])
        b.loc("ARG ARGENTINA", ["es"], ["AR"], ["LATAM"])
        b.loc("COL COLOMBIA", ["es"], ["CO"], ["LATAM"])
        b.loc("CO", ["es"], ["CO"], ["LATAM"], amb: true)
        b.loc("CL CHILE", ["es"], ["CL"], ["LATAM"])
        b.loc("PE PERU", ["es"], ["PE"], ["LATAM"])
        b.loc("VE VEN VENEZUELA", ["es"], ["VE"], ["LATAM"])
        b.loc("EC ECUADOR", ["es"], ["EC"], ["LATAM"])
        b.loc("UY URUGUAY", ["es"], ["UY"], ["LATAM"])
        b.loc("PY PARAGUAY", ["es"], ["PY"], ["LATAM"])
        b.loc("BOLIVIA", ["es"], ["BO"], ["LATAM"])
        b.loc("BO", ["es"], ["BO"], ["LATAM"], amb: true)
        b.loc("CR COSTARICA", ["es"], ["CR"], ["LATAM"])
        b.loc("PANAMA", ["es"], ["PA"], ["LATAM"])
        b.loc("PA", ["es"], ["PA"], ["LATAM"], amb: true)
        b.loc("PUERTORICO", ["es"], ["PR"], ["LATAM", "CARIB"])
        b.loc("PR", ["es"], ["PR"], ["LATAM", "CARIB"], amb: true)
        b.loc("CUBA", ["es"], ["CU"], ["LATAM", "CARIB"])
        b.loc("CU", ["es"], ["CU"], ["LATAM", "CARIB"], amb: true)
        b.loc("DOMINICANA", ["es"], ["DO"], ["LATAM", "CARIB"])
        b.loc("BR BRA BRASIL BRAZIL PTBR PT-BR", ["pt"], ["BR"], ["LATAM"])
        b.loc("PT POR PRT PORTUGAL PORTUGUESE PORTUGUES", ["pt"], ["PT"])
        b.loc("ES ESP SPAIN ESPANA CAST CASTELLANO", ["es"], ["ES"])
        b.loc("SPA", ["es"], ["ES"], amb: true)
        b.loc("ESPANOL SPANISH", ["es"])
        b.loc("FR FRA FRENCH FRANCE FRANCAIS", ["fr"], ["FR"])
        b.loc("FRE", ["fr"], ["FR"], amb: true)
        b.loc("QC QUEBEC CAFR CA-FR QFR", ["fr"], ["CA"])
        b.loc("BEL BELGIQUE BELGIE BELGIUM", ["fr", "nl"], ["BE"])
        b.loc("BE", ["fr", "nl"], ["BE"], amb: true)
        b.loc("CH SUI SWISS SCHWEIZ SUISSE", ["de", "fr", "it"], ["CH"])
        b.loc("LU LUX", ["fr", "de"], ["LU"])
        b.loc("DE GER DEU GERMAN DEUTSCH GERMANY DEUTSCHLAND", ["de"], ["DE"])
        b.loc("AUT AUSTRIA OSTERREICH", ["de"], ["AT"])
        b.loc("AT", ["de"], ["AT"], amb: true)
        b.loc("DACH", ["de"], ["DE", "AT", "CH"])
        b.loc("ITA ITALIA ITALIAN ITALY ITALIANO", ["it"], ["IT"])
        b.loc("IT", ["it"], ["IT"], amb: true)
        b.loc("NL NLD NED DUT DUTCH NEDERLAND HOLLAND NEDERLANDS", ["nl"], ["NL"])
        b.loc("VL VLAAMS", ["nl"], ["BE"])
        b.loc("PL POL POLSKA POLISH POLSKI", ["pl"], ["PL"])
        b.loc("RU RUS RUSSIA RUSSIAN РУ РУС РОССИЯ", ["ru"], ["RU"])
        b.loc("UA UKR UKRAINE UKRAINIAN УКР", ["uk"], ["UA"])
        b.loc("BLR BELARUS", ["be"], ["BY"])
        b.loc("BY", ["be"], ["BY"], amb: true)
        b.loc("KZ KAZ KAZAKHSTAN", ["kk"], ["KZ"])
        b.loc("UZ UZB UZBEKISTAN", ["uz"], ["UZ"])
        b.loc("AZ AZE AZERBAIJAN", ["az"], ["AZ"])
        b.loc("GEORGIA", ["ka"], ["GE"])
        b.loc("GE GEO", ["ka"], ["GE"], amb: true)
        b.loc("ARMENIA HY", ["hy"], ["AM"])
        b.loc("AM ARM", ["hy"], ["AM"], amb: true)
        b.loc("RO ROU RON ROMANIA ROMANIAN", ["ro"], ["RO"])
        b.loc("ROM RUM", ["ro"], ["RO"], amb: true)
        b.loc("MD MDA MOLDOVA", ["ro"], ["MD"])
        b.loc("HU HUN HUNGARY MAGYAR", ["hu"], ["HU"])
        b.loc("CZ CZE CES CZECH CS", ["cs"], ["CZ"])
        b.loc("SK SVK SLOVAKIA", ["sk"], ["SK"])
        b.loc("BG BUL BGR BULGARIA", ["bg"], ["BG"])
        b.loc("GR GRE GRC ELL GREECE GREEK ELLADA", ["el"], ["GR"])
        b.loc("EL", ["el"], ["GR"], amb: true)
        b.loc("CY CYP CYPRUS", ["el"], ["CY"])
        b.loc("IL ISR ISRAEL HEB HEBREW", ["he"], ["IL"])
        b.loc("HE", ["he"], ["IL"], amb: true)
        b.loc("IN IND INDIA INDIAN", [], ["IN"], amb: true)
        b.loc("HI HIN HINDI", ["hi"], ["IN"])
        b.loc("TAM TAMIL", ["ta"], ["IN"])
        b.loc("TA", ["ta"], ["IN"], amb: true)
        b.loc("TEL TELUGU", ["te"], ["IN"])
        b.loc("TE", ["te"], ["IN"], amb: true)
        b.loc("MALAYALAM", ["ml"], ["IN"])
        b.loc("ML MAL", ["ml"], ["IN"], amb: true)
        b.loc("KN KAN KANNADA", ["kn"], ["IN"])
        b.loc("PUNJABI", ["pa"])
        b.loc("PUN", ["pa"], [], [], amb: true)
        b.loc("BN BENGALI BANGLA", ["bn"])
        b.loc("MARATHI", ["mr"], ["IN"])
        b.loc("MR", ["mr"], ["IN"], amb: true)
        b.loc("GU GUJ GUJARATI", ["gu"], ["IN"])
        b.loc("PK PAK PAKISTAN", ["ur"], ["PK"])
        b.loc("URD URDU", ["ur"])
        b.loc("UR", ["ur"], [], [], amb: true)
        b.loc("BD BANGLADESH", ["bn"], ["BD"])
        b.loc("PH PHI PHIL PINOY FILIPINO TAGALOG TL", ["tl"], ["PH"])
        b.loc("JP JPN JAPAN JAPANESE", ["ja"], ["JP"])
        b.loc("JA JAP", ["ja"], ["JP"], amb: true)
        b.loc("KR KOR KOREA KOREAN KDRAMA K-DRAMA", ["ko"], ["KR"])
        b.loc("KO", ["ko"], ["KR"], amb: true)
        b.loc("CN CHN ZH CHI CHINA CHINESE MANDARIN", ["zh"], ["CN"])
        b.loc("HK HKG CANTONESE", ["zh"], ["HK"])
        b.loc("TW TWN TAIWAN", ["zh"], ["TW"])
        b.loc("TH THA THAI THAILAND", ["th"], ["TH"])
        b.loc("VN VIE VIET VIETNAM", ["vi"], ["VN"])
        b.loc("VI", ["vi"], ["VN"], amb: true)
        b.loc("IDN INDO INDONESIA", ["id"], ["ID"])
        b.loc("ID", ["id"], ["ID"], amb: true)
        b.loc("MYS MALAYSIA MALAY", ["ms"], ["MY"])
        b.loc("MY", ["ms"], ["MY"], amb: true)
        b.loc("AFR AFRICA AFRIQUE AFRICAN", [], [], ["AFRICA"])
        b.loc("NG NGA NIGERIA", ["en"], ["NG"], ["AFRICA"])
        b.loc("GH GHA GHANA", ["en"], ["GH"], ["AFRICA"])
        b.loc("KE KEN KENYA", ["sw", "en"], ["KE"], ["AFRICA"])
        b.loc("ZA RSA SOUTHAFRICA", ["en"], ["ZA"], ["AFRICA"])
        b.loc("SN SEN SENEGAL", ["fr"], ["SN"], ["AFRICA"])
        b.loc("CM CMR CAMEROUN CAMEROON", ["fr"], ["CM"], ["AFRICA"])
        b.loc("CI CIV", ["fr"], ["CI"], ["AFRICA"])
        b.loc("SOM SOMALI SOMALIA", ["so"], ["SO"], ["AFRICA"])
        b.loc("SWA SWAHILI", ["sw"], [], ["AFRICA"])
        b.loc("SW", ["sw"], [], ["AFRICA"], amb: true)
        b.loc("ETH ETHIOPIA AMHARIC", ["am"], ["ET"], ["AFRICA"])
    }
}

extension Quality {
    /// Tier for a line count in a resolution tag ("1080p" -> fhd).
    static func fromLines(_ lines: Int) -> Quality {
        if lines >= 2000 { return .uhd }
        if lines >= 1000 { return .fhd }
        if lines >= 700 { return .hd }
        if lines >= 200 { return .sd }
        return .unknown
    }
}

/// Stage 3b: tags each word at creation, then merges bigrams and splits attached timeshifts ("ITV+1").
enum Classifier {
    /// A classified word token.
    static func word(_ facts: WordFacts, kind: ParseKind, wsBefore: Bool, wsAfter: Bool) -> Token {
        var tags: [Tag] = []
        var head = false
        if let entry = Lexicon.entries[facts.key] {
            tags = entry.tags
            head = entry.bigramHead
        }
        if tags.isEmpty && facts.hasDigit { tags = Lexicon.patternTags(facts.key) }
        if tags.isEmpty && facts.hasDash { tags = compoundTags(facts.key) }
        var split = 0
        var hours = 0
        if tags.isEmpty, kind == .live, facts.hasDigit, let attached = attachedTimeshift(facts.text) {
            split = attached.split
            hours = attached.hours
        }
        if tags.count > 1 { tags = resolveDoubleMeaning(tags, kind: kind) }
        return Token(kind: .word, facts: facts, wsBefore: wsBefore, wsAfter: wsAfter, tags: tags, bigramHead: head,
                     attachedSplit: split, attachedHours: hours)
    }

    static func classify(_ toks: [Token], kind: ParseKind) -> [Token] {
        var anyHead = false
        var needsSplit = false
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.bigramHead { anyHead = true }
            if t.attachedHours != 0 { needsSplit = true }
            i += 1
        }
        var out = anyHead ? mergeBigrams(toks, kind: kind) : toks
        if needsSplit { out = splitAttached(out, kind: kind) }
        return out
    }

    /// "BD" is Blu-ray in VOD names and Bangladesh in live/category names.
    private static func resolveDoubleMeaning(_ tags: [Tag], kind: ParseKind) -> [Tag] {
        guard tags.count > 1 else { return tags }
        var mask: UInt32 = 0
        let loop2Items = tags
        var loop2 = 0
        while loop2 < loop2Items.count {
            let tag = loop2Items[loop2]
            loop2 += 1
            mask |= tag.cls
        }
        guard mask & TagClass.source != 0 && mask & TagClass.locale != 0 else { return tags }
        let drop = kind.isVOD ? TagClass.locale : TagClass.source
        return tags.filter { $0.cls != drop }
    }

    /// "4K-NF", "NF-4K", "EN-SUB": every dash-separated part is a tag -> unambiguous compound.
    private static func compoundTags(_ key: String) -> [Tag] {
        let parts = key.split(separator: "-")
        guard parts.count >= 2 else { return [] }
        var all: [Tag] = []
        let loop3Items = parts
        var loop3 = 0
        while loop3 < loop3Items.count {
            let part = loop3Items[loop3]
            loop3 += 1
            let sub = Lexicon.classify(String(part))
            if sub.isEmpty { return [] }
            let loop4Items = sub
            var loop4 = 0
            while loop4 < loop4Items.count {
                let tag = loop4Items[loop4]
                loop4 += 1
                if tag.cls == TagClass.year { return [] }
                all.append(tag.with(ambiguous: false))
            }
        }
        return all
    }

    /// Detects "ITV+1": channel part + "+N" at the end.
    private static func attachedTimeshift(_ text: String) -> (split: Int, hours: Int)? {
        let scalars = Array(text.unicodeScalars)
        var plus = -1
        var k = scalars.count - 1
        while k >= 0 {
            if scalars[k].value == 43 { plus = k; break }
            k -= 1
        }
        guard plus > 0 else { return nil }
        let digitCount = scalars.count - plus - 1
        guard digitCount >= 1 && digitCount <= 2 else { return nil }
        var hours = 0
        var loop5 = plus + 1
        while loop5 < scalars.count {
            let s = scalars[loop5]
            loop5 += 1
            guard s.value >= 48 && s.value <= 57 else { return nil }
            hours = hours * 10 + Int(s.value - 48)
        }
        guard hours != 18, hours >= 1, hours <= 48 else { return nil }
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars[0..<plus])
        if Lexicon.plusBrands.contains(TextFold.upperKey(String(prefix))) { return nil }
        return (plus, hours)
    }

    private static func mergeBigrams(_ toks: [Token], kind: ParseKind) -> [Token] {
        var out: [Token] = []
        out.reserveCapacity(toks.count)
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.isWord && t.bigramHead && i + 1 < toks.count && toks[i + 1].isWord {
                let next = toks[i + 1]
                let pair = t.key + " " + next.key
                if let mergedKey = Lexicon.bigrams[pair] {
                    let tags = Lexicon.classify(mergedKey)
                    if !tags.isEmpty {
                        let keepAmbiguity = Lexicon.ambiguousBigrams.contains(pair)
                        let facts = WordFacts(text: t.text + " " + next.text, key: mergedKey,
                                              decorated: t.decorated || next.decorated, hasLetter: t.hasLetter || next.hasLetter,
                                              hasLower: t.hasLower || next.hasLower, hasDigit: t.hasDigit || next.hasDigit,
                                              length: t.length + 1 + next.length, hasDash: false)
                        let merged = Token(kind: .word, facts: facts, wsBefore: t.wsBefore, wsAfter: next.wsAfter,
                                           tags: resolveDoubleMeaning(keepAmbiguity ? tags : tags.map { $0.with(ambiguous: false) },
                                                                      kind: kind),
                                           forceUpper: !keepAmbiguity, merged: true)
                        out.append(merged)
                        i += 2
                        continue
                    }
                }
            }
            out.append(t)
            i += 1
        }
        return out
    }

    private static func splitAttached(_ toks: [Token], kind: ParseKind) -> [Token] {
        var out: [Token] = []
        out.reserveCapacity(toks.count + 2)
        let loop6Items = toks
        var loop6 = 0
        while loop6 < loop6Items.count {
            let t = loop6Items[loop6]
            loop6 += 1
            guard t.isWord, t.attachedHours > 0 else { out.append(t); continue }
            var values: [UInt32] = []
            let loop7Items = Array(t.text.unicodeScalars)
            var loop7 = 0
            while loop7 < loop7Items.count {
                let s = loop7Items[loop7]
                loop7 += 1
                values.append(s.value)
            }
            let decorated = [Bool](repeating: t.decorated, count: values.count)
            let channelFacts = Tokenizer.makeWord(values, decorated, 0, t.attachedSplit)
            var channelTags = Lexicon.classify(channelFacts.key)
            if channelTags.count > 1 { channelTags = resolveDoubleMeaning(channelTags, kind: kind) }
            out.append(Token(kind: .word, facts: channelFacts, wsBefore: t.wsBefore, wsAfter: false, tags: channelTags))
            let shiftFacts = Tokenizer.makeWord(values, decorated, t.attachedSplit, values.count)
            out.append(Token(kind: .word, facts: shiftFacts, wsBefore: false, wsAfter: t.wsAfter,
                             tags: [Tag(.timeshift(t.attachedHours))]))
        }
        return out
    }
}
