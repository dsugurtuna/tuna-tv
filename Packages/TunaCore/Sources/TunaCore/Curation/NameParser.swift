import Foundation

// =====================================================================================================
// Stages 4-6 of the tag grammar: ZONES (leading tags, bracket groups, series markers, trailing tags,
// strong technical tags anywhere), FIELDS and KEY. A port of `parse` in the Python reference
// (research/11-parsing-ref.py) with these deliberate fixes:
//  - a year counts as a title word ("EN| 1917 (2019)" keeps "1917", strips "EN");
//  - Turkish ordinals ("1. Sezon 3. Bölüm") read the number before the word;
//  - trailing timeshift / mixed-case "Backup" (live) and "BluRay"-style sources are stripped;
//  - trailing tags after S01E01 ("Show S01E01 HD") are tags, not the episode title;
//  - everything after a bracketed movie year is metadata ("(1999) Türkçe Dublaj", "(2009) Extended Cut");
//  - a language word before an audio marker is a tag ("Türkçe Dublaj", "English Subtitles");
//  - adult / PPV words count anywhere; "-1h" timeshifts; "TVᴴᴰ" splits; flags use the country's language
//    (🇦🇷 = Spanish); "AR" means Argentina in a Latin-American context; "Name (US)" stays part of a series title;
//  - attached "!" / "?" stay in display titles ("Mamma Mia!").
// =====================================================================================================

final class NameParse {
    let toks: [Token]
    let n: Int
    let kind: ParseKind
    let category: CategoryHints?
    /// The (trimmed) name is pure ASCII: no script hint, no decoration.
    let asciiName: Bool
    private(set) var leadEnd = 0
    private(set) var titleEnd = 0
    private(set) var trailStart = 0
    private var bracketYears: [Int] = []
    private var bareYear: Int?
    /// Closing bracket of the first bracketed year that follows a title word.
    private var yearClose: Int?
    private var season: Int?
    private var episode: Int?
    private var seriesFound = false

    init(name: String, kind: ParseKind, category: CategoryHints?) {
        let (values, decorated, ascii) = Prefold.run(name)
        toks = Classifier.classify(Tokenizer.scan(values, decorated, ascii: ascii, kind: kind), kind: kind)
        asciiName = ascii != nil
        n = toks.count
        self.kind = kind
        self.category = category
        titleEnd = n
    }

    /// Runs every zone pass in reference order.
    func runZones() {
        leadingZone()
        bracketGroups()
        if kind.isVOD {
            seriesMarkers()
            episodeZone()
            afterYearPass()
        }
        trailingZone()
        strongPass()
    }

    // MARK: 5a. Leading zone ("EN|", "|TR|", "UK:", "[DE]", "TR -", "VIP |", "4K-NF |", "◉ AR")

    private enum LeadSep { case pipe, colon, dash, star, slash, close, open, bracket }

    private static func isLeadingSkip(_ c: UInt32) -> Bool {
        c == 124 || c == 42 || c == 45 || c == 58 || c == 47 || c == 44
    }

    private func leadingZone() {
        var i = 0
        var segments = 0
        outer: while i < n && segments < 6 {
            while i < n {
                let t = toks[i]
                if t.kind == .flag { t.role = .tag; i += 1; continue }
                if t.kind == .separator && NameParse.isLeadingSkip(t.sep) { t.role = .sep; i += 1; continue }
                break
            }
            if i >= n { break }
            if isDecoratedLocaleCode(i) {
                toks[i].role = .tag
                i += 1
                segments += 1
                continue
            }
            let start = i
            let bracket = toks[i].kind == .separator && Tokenizer.isOpen(toks[i].sep)
            let segStart: Int
            let segEnd: Int
            let end: Int
            let sepKind: LeadSep
            if bracket {
                var j = i + 1
                while j < n && !(toks[j].kind == .separator && Tokenizer.isClose(toks[j].sep)) { j += 1 }
                segStart = i + 1
                segEnd = j
                end = j
                sepKind = .bracket
            } else {
                var j = i
                while j < n && toks[j].kind != .separator { j += 1 }
                segStart = i
                segEnd = j
                end = j
                guard j < n else { break }
                switch toks[j].sep {
                case 124: sepKind = .pipe
                case 58: sepKind = .colon
                case 45: sepKind = .dash
                case 42: sepKind = .star
                case 47: sepKind = .slash
                case 93, 41: sepKind = .close
                case 91 where j > i: sepKind = .open
                default: break outer
                }
            }
            if segEnd <= segStart { break }
            var loop1 = segStart
            while loop1 < segEnd {
                let k = loop1
                loop1 += 1
                guard toks[k].kind == .separator else { continue }
                break outer
            }
            if !gate(segStart, segEnd, sepKind) { break }
            let restStart = end < n ? end + 1 : n
            if !restHasTitle(restStart, segStart, segEnd) { break }
            var loop2 = segStart
            while loop2 < segEnd {
                let k = loop2
                loop2 += 1
                if toks[k].tags.isEmpty { toks[k].role = .unknownTag } else { toks[k].role = .tag }
            }
            if bracket {
                toks[start].role = .sep
                if end < n { toks[end].role = .sep }
                i = end + 1
            } else {
                i = end
                if i < n {
                    toks[i].role = .sep
                    i += 1
                }
            }
            segments += 1
        }
        leadEnd = min(i, n)
    }

    /// "◉ AR MBC 1": a decoration, then an uppercase unambiguous locale code, then the title.
    private func isDecoratedLocaleCode(_ i: Int) -> Bool {
        guard i > 0, i + 1 < n else { return false }
        let prev = toks[i - 1]
        guard prev.kind == .separator, prev.decorated, prev.sep == 42 else { return false }
        let t = toks[i]
        guard t.isWord, t.wsAfter, t.isUpperText, t.length >= 2, t.length <= 3, t.strong,
              let loc = t.locale, !loc.ambiguous else { return false }
        let next = toks[i + 1]
        return next.isWord && !next.strong
    }

    private func gate(_ s: Int, _ e: Int, _ sepKind: LeadSep) -> Bool {
        let count = e - s
        let vod = kind.isVOD
        var loop3 = s
        while loop3 < e {
            let k = loop3
            loop3 += 1
            let t = toks[k]
            if t.kind == .flag { continue }
            let upper = t.upperish
            if !t.tags.isEmpty {
                let ambiguousOnly = !t.isTag(allowAmbiguous: false)
                // "Adult | Brazzers", "Adults: ..." are adult tags whatever their case.
                if t.classes == TagClass.adult && (sepKind == .pipe || sepKind == .colon || sepKind == .bracket) { continue }
                if !upper && !t.decorated {
                    if ambiguousOnly || (sepKind != .pipe && sepKind != .bracket) { return false }
                }
                if ambiguousOnly && vod && (sepKind == .colon || sepKind == .dash) && !corroborated(t) { return false }
                if sepKind == .colon && t.length > 3 && !t.decorated && !(t.isUpperText && t.length <= 4)
                    && !t.has(TagClass.kindWord) && kind != .category
                    && !t.has(TagClass.platform | TagClass.adult | TagClass.promo | TagClass.quality) {
                    return false
                }
                continue
            }
            // Unknown uppercase code before a pipe / in brackets ("SKY |", "[XYZ]").
            if upper && t.length >= 2 && t.length <= 5 && t.hasLetter && (sepKind == .pipe || sepKind == .bracket) && count <= 2 {
                continue
            }
            return false
        }
        return true
    }

    /// An ambiguous code before ':' / '-' in a VOD name needs the category to agree ("IT: ..." in an Italian category).
    private func corroborated(_ t: Token) -> Bool {
        guard let langs = t.locale?.languages, !langs.isEmpty, let catLangs = category?.languages else { return false }
        let loop4Items = langs
        var loop4 = 0
        while loop4 < loop4Items.count {
            let lang = loop4Items[loop4]
            loop4 += 1
            guard catLangs.contains(lang) else { continue }
            return true
        }
        return false
    }

    private func restHasTitle(_ restStart: Int, _ s: Int, _ e: Int) -> Bool {
        if kind == .category {
            var segHasKind = false
            var loop5 = s
            while loop5 < e {
                let k = loop5
                loop5 += 1
                guard toks[k].classes == TagClass.kindWord else { continue }
                segHasKind = true
            }
            if !segHasKind {
                var loop6 = restStart
                while loop6 < n {
                    let k = loop6
                    loop6 += 1
                    guard toks[k].isWord else { continue }
                    return true
                }
                return false
            }
            return hasTitleWord(after: restStart, excludeKind: true)
        }
        return hasTitleWord(after: restStart, excludeKind: false)
    }

    private func hasTitleWord(after start: Int, excludeKind: Bool) -> Bool {
        var k = start
        while k < n {
            let t = toks[k]
            if t.isWord {
                if excludeKind && t.has(TagClass.kindWord) && !t.strong {
                    k += 1
                    continue
                }
                if t.tags.isEmpty || !t.isTag(allowAmbiguous: false) || t.has(TagClass.year) { return true }
            }
            k += 1
        }
        return false
    }

    // MARK: 5b. Bracket groups after the leading zone

    private func bracketGroups() {
        var k = leadEnd
        while k < n {
            let t = toks[k]
            guard t.kind == .separator && Tokenizer.isOpen(t.sep) else { k += 1; continue }
            var j = k + 1
            var depth = 1
            while j < n {
                let u = toks[j]
                if u.kind == .separator {
                    if Tokenizer.isOpen(u.sep) {
                        depth += 1
                    } else if Tokenizer.isClose(u.sep) {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                j += 1
            }
            let innerEnd = min(j, n)
            let wordBefore = hasTitleWord(from: leadEnd, to: k)
            var allTagged = true
            var loop7 = (k + 1)
            while loop7 < innerEnd {
                let x = loop7
                loop7 += 1
                guard toks[x].isWord && toks[x].tags.isEmpty else { continue }
                allTagged = false; break
            }
            if !wordBefore && !allTagged {
                k = j + 1
                continue
            }
            if kind == .series && wordBefore && isSeriesCountrySuffix(k, innerEnd) {
                var loop8 = k
                while loop8 < min(j + 1, n) {
                    let x = loop8
                    loop8 += 1
                    toks[x].role = .keep
                }
                k = j + 1
                continue
            }
            var loop9 = k
            while loop9 < min(j + 1, n) {
                let x = loop9
                loop9 += 1
                let tx = toks[x]
                if tx.isWord && !tx.tags.isEmpty {
                    if tx.has(TagClass.seriesMarkers) && kind.isVOD { continue }
                    if let y = tx.yearValue, y >= Lexicon.minYear, y <= Lexicon.maxYear {
                        bracketYears.append(y)
                        tx.role = .year
                        if wordBefore && yearClose == nil { yearClose = min(j, n - 1) }
                    } else {
                        tx.role = .tag
                    }
                } else if tx.kind == .flag {
                    tx.role = .tag
                } else {
                    tx.role = .bracket
                }
            }
            k = j + 1
        }
    }

    /// "The Office (US)" / "Shameless (UK)": the country is part of the series' identity.
    private func isSeriesCountrySuffix(_ open: Int, _ innerEnd: Int) -> Bool {
        guard innerEnd == open + 2 else { return false }
        let t = toks[open + 1]
        guard t.isWord else { return false }
        switch t.key {
        case "US", "USA", "UK", "GB", "AU", "CA", "NZ", "IE": return true
        default: return false
        }
    }

    // MARK: 5c. Series / episode markers (VOD only)

    private func seriesMarkers() {
        var k = leadEnd
        while k < n {
            let t = toks[k]
            if t.role != .none || !t.isWord {
                k += 1
                continue
            }
            if let se = t.seasonEpisodeValue {
                season = se.season
                episode = se.episode
                t.role = .se
                titleEnd = k
                seriesFound = true
                return
            }
            if let s = t.seasonValue {
                t.role = .se
                season = s
                if let nx = nextWord(after: k) { episode = episodeAt(nx) }
                titleEnd = k
                seriesFound = true
                return
            }
            if kind == .series {
                if let e = t.episodeValue {
                    episode = e
                    t.role = .se
                    titleEnd = k
                    seriesFound = true
                    return
                }
                if t.has(TagClass.seasonWord | TagClass.episodeWord) && wordMarker(k) { return }
            }
            k += 1
        }
    }

    /// Episode right after a season marker: "E05", "Episode 5", "Bölüm 5", "3. Bölüm".
    private func episodeAt(_ nx: Int) -> Int? {
        let u = toks[nx]
        if let e = u.episodeValue {
            u.role = .se
            return e
        }
        if u.has(TagClass.episodeWord), let nn = nextWord(after: nx), toks[nn].isAllDigits, toks[nn].key.utf8.count <= 4,
           let e = Int(toks[nn].key) {
            u.role = .se
            toks[nn].role = .se
            return e
        }
        if u.isAllDigits, u.key.utf8.count <= 3, u.length <= u.key.utf8.count + 1, let nn = nextWord(after: nx),
           toks[nn].has(TagClass.episodeWord), let e = Int(u.key) {
            u.role = .se
            toks[nn].role = .se
            return e
        }
        return nil
    }

    /// "Season 1", "Sezon 1 Bölüm 2", "1. Sezon 3. Bölüm", "Bölüm 12", "245. Bölüm", "Episode 4".
    private func wordMarker(_ k: Int) -> Bool {
        let t = toks[k]
        let next = nextWord(after: k)
        let prev = previousTitleWord(before: k)
        var number: Int?
        var numberIndex = -1
        if let p = prev, toks[p].isOrdinal, let v = Int(toks[p].key) {
            number = v
            numberIndex = p
        } else if let x = next, toks[x].isAllDigits, toks[x].key.utf8.count <= 3, let v = Int(toks[x].key) {
            number = v
            numberIndex = x
        } else if let p = prev, toks[p].isAllDigits, toks[p].key.utf8.count <= 3, t.key == "SEZON" || t.key == "BOLUM",
                  let v = Int(toks[p].key) {
            number = v
            numberIndex = p
        }
        guard let value = number else { return false }
        t.role = .se
        toks[numberIndex].role = .se
        if t.has(TagClass.seasonWord) {
            season = value
            if let nx = nextWord(after: max(k, numberIndex)) { episode = episodeAt(nx) }
        } else {
            episode = value
        }
        titleEnd = min(k, numberIndex)
        seriesFound = true
        return true
    }

    private func nextWord(after k: Int) -> Int? {
        var x = k + 1
        while x < n {
            if toks[x].isWord { return x }
            x += 1
        }
        return nil
    }

    private func previousTitleWord(before k: Int) -> Int? {
        var x = k - 1
        while x >= leadEnd {
            if toks[x].isWord && toks[x].role == .none { return x }
            x -= 1
        }
        return nil
    }

    /// After an episode marker: technical tags and trailing tags are tags, the rest is the episode title.
    private func episodeZone() {
        guard seriesFound else { return }
        var loop10 = titleEnd
        while loop10 < n {
            let k = loop10
            loop10 += 1
            guard toks[k].role == .none else { continue }
            let t = toks[k]
            if t.kind == .flag || (t.isWord && isStrongAnywhere(t)) { t.role = .tag }
        }
        var k = n - 1
        var afterAudio = false
        while k >= titleEnd {
            let t = toks[k]
            if t.role != .none || t.isSeparator {
                k -= 1
                continue
            }
            if t.tags.isEmpty || t.has(TagClass.year | TagClass.seriesMarkers) { break }
            if trailingAccept(t, hasLower: true, afterAudio: afterAudio) {
                t.role = .tag
                afterAudio = t.has(TagClass.audio)
                k -= 1
                continue
            }
            break
        }
        var loop11 = titleEnd
        while loop11 < n {
            let k = loop11
            loop11 += 1
            guard toks[k].role == .none else { continue }
            toks[k].role = .epTitle
        }
    }

    /// Movies/series: everything between a bracketed year and the end of the title is metadata.
    private func afterYearPass() {
        guard let close = yearClose, close + 1 < titleEnd else { return }
        var loop12 = (close + 1)
        while loop12 < titleEnd {
            let k = loop12
            loop12 += 1
            guard toks[k].role == .none else { continue }
            let t = toks[k]
            if t.kind == .flag || !t.tags.isEmpty {
                t.role = .tag
            } else if t.isWord {
                t.role = .bracket
            } else {
                t.role = .sep
            }
        }
    }

    // MARK: 5d. Trailing zone (walk back from the end of the title)

    private func trailingZone() {
        var hasLower = false
        var k = leadEnd
        while k < titleEnd {
            let t = toks[k]
            if t.role == .none && t.isWord && t.hasLower {
                hasLower = true
                break
            }
            k += 1
        }
        var afterAudio = false
        k = titleEnd - 1
        while k >= leadEnd {
            let t = toks[k]
            if t.role != .none || t.isSeparator {
                k -= 1
                continue
            }
            if t.kind == .flag {
                t.role = .tag
                k -= 1
                continue
            }
            if t.tags.isEmpty { break }
            let remaining = hasTitleWord(from: leadEnd, to: k)
            if let y = t.yearValue {
                if kind.isVOD && bracketYears.isEmpty && bareYear == nil && y >= Lexicon.minYear && y <= Lexicon.maxYear
                    && remaining {
                    bareYear = y
                    t.role = .year
                    k -= 1
                    continue
                }
                break
            }
            if !remaining && kind != .category { break }
            if trailingAccept(t, hasLower: hasLower, afterAudio: afterAudio) {
                t.role = .tag
                afterAudio = t.has(TagClass.audio)
                k -= 1
                continue
            }
            break
        }
        trailStart = k + 1
    }

    private func hasTitleWord(from a: Int, to b: Int) -> Bool {
        var k = a
        while k < b {
            let t = toks[k]
            if t.role == .none && t.isWord { return true }
            k += 1
        }
        return false
    }

    /// Vocabulary + case gating of trailing tags (the IPTVnator rule of the reference, plus the fixes above).
    private func trailingAccept(_ t: Token, hasLower: Bool, afterAudio: Bool) -> Bool {
        let c = t.classes
        let ambiguousOnly = !t.isTag(allowAmbiguous: false)
        let upper = t.upperish
        let live = kind == .live
        var accept = false
        if c & TagClass.vocabulary != 0 {
            if !ambiguousOnly {
                accept = upper || c & TagClass.audio != 0 || (c & TagClass.quality != 0 && t.key != "HD" && t.key != "SD")
                    || t.decorated
                if !accept && (t.key == "HD" || t.key == "SD" || t.key == "FHD" || t.key == "UHD") && (upper || live) {
                    accept = true
                }
                if c & TagClass.source != 0 && !upper { accept = t.key.utf8.count >= 4 && t.hasStrong(TagClass.source) }
                if live && t.hasStrong(TagClass.timeshift | TagClass.backup) { accept = true }
                // "x264", "h265", "10bit": digit-bearing technical tags whatever their case.
                if t.hasDigit && t.hasStrong(TagClass.strongTech) { accept = true }
            } else {
                accept = upper
                    && (live || c & (TagClass.quality | TagClass.backup | TagClass.audio | TagClass.promo | TagClass.source) != 0)
                    && !(c == TagClass.promo && !live) && c & TagClass.adult == 0
                if c & TagClass.backup != 0 && !live { accept = false }
                if c & TagClass.source != 0 && live { accept = false }
            }
        }
        if !accept && c & TagClass.locale != 0 && kind != .category, let loc = t.locale {
            if upper && (hasLower || live) && (!loc.ambiguous || live) && !Lexicon.trailingLocaleExclusions.contains(t.key) {
                accept = true
            }
            if upper && live && (t.key == "US" || t.key == "UK" || t.key == "USA") { accept = true }
            if afterAudio && !loc.ambiguous { accept = true }
        }
        return accept
    }

    // MARK: 5e. Strong technical tags anywhere inside the title

    private func isStrongAnywhere(_ t: Token) -> Bool {
        guard t.classes & TagClass.strongTech != 0 else { return false }
        let loop13Items = t.tags
        var loop13 = 0
        while loop13 < loop13Items.count {
            let tag = loop13Items[loop13]
            loop13 += 1
            guard tag.cls & TagClass.strongTech != 0 && !tag.ambiguous else { continue }
            if t.decorated || t.isUpperText || t.hasDigit || t.forceUpper { return true }
            if tag.cls == TagClass.source && t.key.utf8.count >= 5 { return true }
        }
        return false
    }

    private func strongPass() {
        var k = leadEnd
        while k < trailStart {
            let t = toks[k]
            if t.role == .none {
                if t.kind == .flag {
                    t.role = .tag
                } else if t.isWord && isStrongAnywhere(t) && hasOtherTitleWord(k) {
                    t.role = .tag
                }
            }
            k += 1
        }
    }

    private func hasOtherTitleWord(_ k: Int) -> Bool {
        var x = leadEnd
        while x < trailStart {
            if x != k && toks[x].role == .none && toks[x].isWord { return true }
            x += 1
        }
        return false
    }

    // MARK: Category-only passes

    /// Categories: locale codes anywhere ("TURKISH MOVIES"), uppercase quality words ("HD MOVIES").
    func categoryPasses() {
        var firstWord = -1
        var lastWord = -1
        var loop14 = 0
        while loop14 < n {
            let k = loop14
            loop14 += 1
            guard toks[k].isWord && toks[k].role == .none else { continue }
            if firstWord < 0 { firstWord = k }
            lastWord = k
        }
        var titleWords = 0
        var loop15 = 0
        while loop15 < n {
            let k = loop15
            loop15 += 1
            guard toks[k].isWord && toks[k].role == .none else { continue }
            titleWords += 1
        }
        var loop16 = 0
        while loop16 < n {
            let k = loop16
            loop16 += 1
            guard toks[k].role == .none && toks[k].isWord && !toks[k].tags.isEmpty else { continue }
            let t = toks[k]
            guard titleWords > 1 else { break }
            var take = false
            if let loc = t.locale {
                take = !loc.ambiguous || (t.isUpperText && (k == firstWord || k == lastWord))
            }
            if t.has(TagClass.quality) && t.upperish { take = true }
            if take {
                t.role = .tag
                titleWords -= 1
            }
        }
    }

    // MARK: Fields

    func parsedName(original: String) -> ParsedName {
        let live = kind == .live
        var title = NameParse.render(toks, from: leadEnd, to: titleEnd, roles: .title)
        if title.isEmpty { title = original.tunaTrimmed }
        var result = ParsedName(original: original, title: title, key: "")

        if kind.isVOD {
            result.year = bracketYears.first ?? bareYear
            if kind == .series {
                result.season = season
                result.episode = episode
                if seriesFound {
                    let episodeTitle = NameParse.render(toks, from: titleEnd, to: n, roles: .episode)
                    result.episodeTitle = episodeTitle.isEmpty ? nil : episodeTitle
                }
            }
        }

        var languages: [String] = []
        var countries: [String] = []
        var regions: [String] = []
        var implied: [String] = []
        var hdrs: [HDRFormat] = []
        var dubbed = false, subtitled = false, multi = false, originalAudio = false
        var tags: [String] = []
        var hasARCode = false
        var k = 0
        while k < n {
            let t = toks[k]
            k += 1
            if t.isWord && t.classes & TagClass.adult != 0 && t.hasStrong(TagClass.adult) { result.isAdult = true }
            if live && t.isWord && t.classes & TagClass.event != 0 && t.hasStrong(TagClass.event) { result.isEvent = true }
            if t.role == .se { tags.append(t.key) }
            guard t.role == .tag else { continue }
            tags.append(t.key)
            if t.isWord && t.key == "AR" { hasARCode = true }
        }
        let argentina = hasARCode && argentinaContext()

        func addUnique(_ value: String, _ list: inout [String]) { if !list.contains(value) { list.append(value) } }
        func addAll(_ values: [String], _ list: inout [String]) {
            var i = 0
            while i < values.count {
                if !list.contains(values[i]) { list.append(values[i]) }
                i += 1
            }
        }

        k = 0
        while k < n {
            let t = toks[k]
            k += 1
            guard t.role == .tag else { continue }
            var j = 0
            while j < t.tags.count {
                let tag = t.tags[j]
                j += 1
                switch tag.value {
                case .quality(let q):
                    if q > result.quality { result.quality = q }
                case .source(let s):
                    if result.source == nil || (result.source == .bluray && s == .remux) { result.source = s }
                case .hdr(let h):
                    hdrs.append(h)
                case .codec(let c):
                    if result.codec == nil { result.codec = c }
                case .fps(let f):
                    if f >= 48 { result.highFrameRate = true }
                case .threeD:
                    result.is3D = true
                case .locale(let loc):
                    let effective = (argentina && t.isWord && t.key == "AR") ? Lexicon.argentina : loc
                    addAll(effective.languages, &languages)
                    addAll(effective.countries, &countries)
                    addAll(effective.regions, &regions)
                case .flag(let code):
                    let cc = code == "UK" ? "GB" : code
                    if cc != "EU" && cc != "UN" { addUnique(cc, &countries) }
                    if let lang = WorldDirectory.country(cc)?.languages.first { implied.append(lang) }
                case .audio(let mode, let lang):
                    switch mode {
                    case .dubbed: dubbed = true
                    case .subtitled: subtitled = true
                    case .multiAudio: multi = true
                    case .original: originalAudio = true
                    }
                    if let lang { implied.append(lang) }
                case .adult:
                    result.isAdult = true
                case .backup:
                    if live { result.isBackup = true }
                case .timeshift(let hours):
                    if live { result.timeshiftHours = hours }
                case .platform(let name):
                    if !live && result.platform == nil { result.platform = name }
                case .event:
                    if live { result.isEvent = true }
                default:
                    break
                }
            }
        }
        if !hdrs.isEmpty { result.hdr = hdrs.max { NameParse.hdrRank($0) < NameParse.hdrRank($1) } }
        if result.source == .dvd && result.quality == .unknown { result.quality = .sd }
        if languages.isEmpty { addAll(implied, &languages) }
        if (dubbed && subtitled) || multi {
            result.audio = .multiAudio
        } else if dubbed {
            result.audio = .dubbed
        } else if subtitled {
            result.audio = .subtitled
        } else if originalAudio {
            result.audio = .original
        }
        if live && !result.isBackup && backupIndex() >= 2 { result.isBackup = true }
        // Category context only fills what the name does not state.
        if let category {
            if languages.isEmpty {
                languages = category.languages
                if countries.isEmpty { countries = category.countries }
                if regions.isEmpty { regions = category.regions }
            }
            if category.isAdult { result.isAdult = true }
            if result.platform == nil && !live { result.platform = category.platform }
            if result.quality == .unknown { result.quality = category.quality }
        }
        if languages.isEmpty && !asciiName, let hint = ScriptDetector.languageHint(for: title) { languages = [hint] }
        result.languages = languages
        result.countries = countries
        result.regions = regions
        result.tags = tags
        var key = fastKey(live: live) ?? TitleKeyBuilder.make(title, live: live)
        if key.isEmpty { key = TitleKeyBuilder.make(original, live: live) }
        result.key = key
        return result
    }

    /// The title key straight from the title tokens when every title word is plain ASCII alphanumerics (the
    /// common case); nil sends the rendered title through the full `TitleKeyBuilder`. Same rules, same result.
    private func fastKey(live: Bool) -> String? {
        var words: [String] = []
        var wordsAtComma = -1
        var k = leadEnd
        while k < titleEnd {
            let t = toks[k]
            k += 1
            guard t.role == .none || t.role == .keep else { continue }
            if t.isWord {
                guard t.simple else { return nil }
                words.append(t.text.lowercased())
            } else if t.isSeparator {
                switch t.sep {
                case 38: words.append("and")
                case 44: wordsAtComma = words.count
                case 43: return nil
                default: break
                }
            } else {
                return nil
            }
        }
        return TitleKeyBuilder.assemble(words, live: live, inverted: wordsAtComma >= 0 && words.count == wordsAtComma + 1)
    }

    /// "AR" is Argentina when the name or its category is Latin American.
    private func argentinaContext() -> Bool {
        if let category {
            if category.regions.contains("LATAM") || category.languages.contains("es") || category.countries.contains("AR") {
                return true
            }
        }
        let loop17Items = toks
        var loop17 = 0
        while loop17 < loop17Items.count {
            let t = loop17Items[loop17]
            loop17 += 1
            guard t.role == .tag && !(t.isWord && t.key == "AR") else { continue }
            if t.kind == .flag && t.key == "AR" { return true }
            if let loc = t.locale, loc.regions.contains("LATAM") || loc.languages.contains("es") { return true }
        }
        return false
    }

    /// "BBC One (2)": a bracketed single digit numbers backup feeds.
    private func backupIndex() -> Int {
        var index = 0
        let loop18Items = toks
        var loop18 = 0
        while loop18 < loop18Items.count {
            let t = loop18Items[loop18]
            loop18 += 1
            guard t.role == .bracket && t.isWord && t.isAllDigits && t.key.utf8.count == 1 else { continue }
            index = Int(t.key) ?? 0
        }
        return index
    }

    static func hdrRank(_ h: HDRFormat) -> Int {
        switch h {
        case .hdr: return 1
        case .hlg: return 2
        case .hdr10: return 3
        case .hdr10Plus: return 4
        case .dolbyVision: return 5
        }
    }

    // MARK: Title rendering

    /// Joins title tokens: ": " / ", " / " - " / "&" / "/" / brackets as in the reference; attached "!" / "?" kept.
    /// Works on UTF-8 bytes (separators are ASCII), so non-Latin text passes through untouched.
    static func render(_ toks: [Token], from a: Int, to b: Int, roles: RenderRoles) -> String {
        var out = ""
        var endsWithSpace = false
        var previousWord = false
        var needsCleaning = false
        func rstrip() {
            if endsWithSpace {
                out.removeLast()
                endsWithSpace = false
            }
        }
        var k = a
        while k < b {
            let t = toks[k]
            k += 1
            guard t.kind != .flag, roles.includes(t.role) else { continue }
            if t.isSeparator {
                let wasWord = previousWord
                previousWord = false
                switch t.sep {
                case 58, 44:
                    if !out.isEmpty {
                        rstrip()
                        out += t.text
                        out += " "
                        endsWithSpace = true
                    }
                case 45:
                    rstrip()
                    out += " - "
                    endsWithSpace = true
                case 38:
                    out += "& "
                    endsWithSpace = true
                case 47:
                    rstrip()
                    out += "/"
                case 40, 91, 123:
                    out += t.text
                    endsWithSpace = false
                    needsCleaning = true
                case 41, 93, 125:
                    rstrip()
                    out += t.text
                    out += " "
                    endsWithSpace = true
                case 33, 63:
                    if wasWord && !t.wsBefore {
                        rstrip()
                        out += t.text
                        out += " "
                        endsWithSpace = true
                    }
                default:
                    break
                }
            } else {
                out += t.text
                out += " "
                endsWithSpace = true
                previousWord = true
                if t.merged { needsCleaning = true }
            }
        }
        if !needsCleaning, let first = out.utf8.first, let last = out.utf8.last {
            var trimmed = out
            if last == 32 { trimmed.removeLast() }
            if let l = trimmed.utf8.last, !isEdgeJunk(first), !isEdgeJunk(l) { return trimmed }
        }
        return cleanRendered(Array(out.utf8))
    }

    @inline(__always) private static func isEdgeJunk(_ c: UInt8) -> Bool {
        c == 32 || c == 45 || c == 58 || c == 124 || c == 44 || c == 47
    }

    /// Strips ' -:|,/' at both ends, removes empty brackets, collapses whitespace (one pass in the common case).
    private static func cleanRendered(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var bracketSeen = false
        var lastSpace = true
        var i = 0
        let count = bytes.count
        while i < count {
            let c = bytes[i]
            i += 1
            if c == 32 || c == 9 {
                if !lastSpace { out.append(32) }
                lastSpace = true
                continue
            }
            if c == 40 || c == 91 { bracketSeen = true }
            out.append(c)
            lastSpace = false
        }
        var lo = 0
        var hi = out.count
        while lo < hi && isEdgeJunk(out[lo]) { lo += 1 }
        while hi > lo && isEdgeJunk(out[hi - 1]) { hi -= 1 }
        if !bracketSeen {
            if lo == 0 && hi == out.count { return String(decoding: out, as: UTF8.self) }
            return String(decoding: out[lo..<hi], as: UTF8.self)
        }
        // Rare: drop empty "()" / "[]" and re-clean until stable.
        var s = Array(out[lo..<hi])
        var changed = true
        while changed {
            changed = false
            var next: [UInt8] = []
            next.reserveCapacity(s.count)
            var x = 0
            while x < s.count {
                let c = s[x]
                if c == 40 || c == 91 {
                    var j = x + 1
                    while j < s.count && s[j] == 32 { j += 1 }
                    if j < s.count && s[j] == (c == 40 ? 41 : 93) {
                        x = j + 1
                        changed = true
                        continue
                    }
                }
                next.append(c)
                x += 1
            }
            var collapsed: [UInt8] = []
            var space = true
            let loop19Items = next
            var loop19 = 0
            while loop19 < loop19Items.count {
                let c = loop19Items[loop19]
                loop19 += 1
                if c == 32 {
                    if !space { collapsed.append(32) }
                    space = true
                } else {
                    collapsed.append(c)
                    space = false
                }
            }
            var l = 0
            var h = collapsed.count
            while l < h && isEdgeJunk(collapsed[l]) { l += 1 }
            while h > l && isEdgeJunk(collapsed[h - 1]) { h -= 1 }
            s = Array(collapsed[l..<h])
        }
        return String(decoding: s, as: UTF8.self)
    }
}

extension Token {
    var seasonEpisodeValue: (season: Int, episode: Int)? {
        guard classes & TagClass.seasonEpisode != 0 else { return nil }
        let loop20Items = tags
        var loop20 = 0
        while loop20 < loop20Items.count {
            let tag = loop20Items[loop20]
            loop20 += 1
            if case .seasonEpisode(let s, let e) = tag.value { return (s, e) }
        }
        return nil
    }

    var seasonValue: Int? {
        guard classes & TagClass.season != 0 else { return nil }
        let loop21Items = tags
        var loop21 = 0
        while loop21 < loop21Items.count {
            let tag = loop21Items[loop21]
            loop21 += 1
            if case .season(let s) = tag.value { return s }
        }
        return nil
    }

    var episodeValue: Int? {
        guard classes & TagClass.episode != 0 else { return nil }
        let loop22Items = tags
        var loop22 = 0
        while loop22 < loop22Items.count {
            let tag = loop22Items[loop22]
            loop22 += 1
            if case .episode(let e) = tag.value { return e }
        }
        return nil
    }

    var yearValue: Int? {
        guard classes & TagClass.year != 0 else { return nil }
        let loop23Items = tags
        var loop23 = 0
        while loop23 < loop23Items.count {
            let tag = loop23Items[loop23]
            loop23 += 1
            if case .year(let y) = tag.value { return y }
        }
        return nil
    }

    /// "1." / "245." (Turkish ordinal before Sezon / Bölüm).
    var isOrdinal: Bool {
        isAllDigits && key.utf8.count <= 3 && length == key.utf8.count + 1 && text.unicodeScalars.last == "."
    }

    /// Has a non-ambiguous tag of one of the classes in `mask`.
    func hasStrong(_ mask: UInt32) -> Bool {
        guard classes & mask != 0 else { return false }
        var i = 0
        while i < tags.count {
            if tags[i].cls & mask != 0 && !tags[i].ambiguous { return true }
            i += 1
        }
        return false
    }
}

/// Which roles a render pass prints.
enum RenderRoles {
    case title, episode, tags

    func includes(_ role: Token.Role) -> Bool {
        switch (self, role) {
        case (.title, .none), (.title, .keep), (.episode, .epTitle), (.tags, .tag): return true
        default: return false
        }
    }
}

enum NameParserEngine {
    static func parse(_ name: String, kind: StreamKind, category: CategoryHints?) -> ParsedName {
        let parse = NameParse(name: name, kind: ParseKind(kind), category: category)
        parse.runZones()
        return parse.parsedName(original: name)
    }
}
