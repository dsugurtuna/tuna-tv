import Foundation

// =====================================================================================================
// Stages 1 + 2 of the tag grammar: PRE-FOLD (normalize separators, flags, superscripts, decorations)
// and SCAN (split into word / separator / flag tokens). Mirrors `prefold` and `scan` of the Python
// reference (research/11-parsing-ref.py), working on scalar values for speed.
// =====================================================================================================

/// Text facts of one word chunk, gathered in a single pass.
struct WordFacts {
    var text: String
    /// Folded uppercase lookup key (trailing dots dropped).
    var key: String
    var decorated: Bool
    var hasLetter: Bool
    var hasLower: Bool
    var hasDigit: Bool
    /// Scalar count of `text`.
    var length: Int
    /// Contains '-' (compound tags such as "4K-NF").
    var hasDash = false
    /// Only ASCII letters and digits (its lowercase key is already a title-key word).
    var simple = false
}

/// One lexical unit of a provider name. Everything but `role` is immutable and precomputed: debug builds pay
/// for every dynamic exclusivity check on a class `var`, and the zone passes read these fields constantly.
final class Token {
    enum Kind { case word, separator, flag }
    /// What a zone pass decided a token is. `keep` = part of the title that no later pass may strip.
    enum Role { case none, sep, tag, unknownTag, year, bracket, se, epTitle, keep }

    let kind: Kind
    /// Display text after pre-folding ("The", "4K", "|", "TR" for a flag).
    let text: String
    /// Folded uppercase lookup key (words), the separator itself, or the flag's country code.
    let key: String
    /// Separator scalar value (separators only, else 0).
    let sep: UInt32
    /// Produced from decoration (superscripts, circled letters, flags, emoji).
    let decorated: Bool
    let wsBefore: Bool
    let wsAfter: Bool
    let hasLetter: Bool
    let hasLower: Bool
    let hasDigit: Bool
    let length: Int
    let tags: [Tag]
    /// Union of the classes of `tags` (`TagClass` bits).
    let classes: UInt32
    /// Has at least one non-ambiguous tag.
    let strong: Bool
    /// Multi-word tags ("Dolby Vision") count as uppercase tags.
    let forceUpper: Bool
    /// Built by a bigram merge ("Dolby Vision"): its text contains a space.
    let merged: Bool
    /// Only ASCII letters and digits.
    let simple: Bool
    /// First word of a known bigram ("DOLBY" of "DOLBY VISION").
    let bigramHead: Bool
    /// Attached timeshift ("ITV+1"): scalar length of the channel part and the hours (0 = none).
    let attachedSplit: Int
    let attachedHours: Int
    let isWord: Bool
    let isSeparator: Bool
    /// Letters present and none lowercase.
    let isUpperText: Bool
    /// Uppercase for tag-gating purposes.
    let upperish: Bool
    var role: Role = .none

    /// Key made of ASCII digits only.
    var isAllDigits: Bool {
        guard isWord && hasDigit && !hasLetter && !key.isEmpty else { return false }
        let loop1Items = Array(key.utf8)
        var loop1 = 0
        while loop1 < loop1Items.count {
            let byte = loop1Items[loop1]
            loop1 += 1
            guard byte < 48 || byte > 57 else { continue }
            return false
        }
        return true
    }

    /// First locale payload, if any.
    var locale: LocaleTag? {
        guard classes & TagClass.locale != 0 else { return nil }
        let loop2Items = tags
        var loop2 = 0
        while loop2 < loop2Items.count {
            let tag = loop2Items[loop2]
            loop2 += 1
            if case .locale(let loc) = tag.value { return loc }
        }
        return nil
    }

    init(kind: Kind, facts: WordFacts, sep: UInt32 = 0, wsBefore: Bool, wsAfter: Bool, tags: [Tag], forceUpper: Bool = false,
         merged: Bool = false, bigramHead: Bool = false, attachedSplit: Int = 0, attachedHours: Int = 0) {
        self.merged = merged
        simple = facts.simple && !merged
        self.kind = kind
        text = facts.text
        key = facts.key
        self.sep = sep
        decorated = facts.decorated
        self.wsBefore = wsBefore
        self.wsAfter = wsAfter
        hasLetter = facts.hasLetter
        hasLower = facts.hasLower
        hasDigit = facts.hasDigit
        length = facts.length
        self.tags = tags
        var mask: UInt32 = 0
        var anyStrong = false
        var i = 0
        let tagCount = tags.count
        while i < tagCount {
            let tag = tags[i]
            mask |= tag.cls
            if !tag.ambiguous { anyStrong = true }
            i += 1
        }
        classes = mask
        strong = anyStrong
        self.forceUpper = forceUpper
        self.bigramHead = bigramHead
        self.attachedSplit = attachedSplit
        self.attachedHours = attachedHours
        isWord = kind == .word
        isSeparator = kind == .separator
        isUpperText = facts.hasLetter && !facts.hasLower
        upperish = facts.decorated || forceUpper || (facts.hasLetter && !facts.hasLower)
    }

    @inline(__always) func has(_ mask: UInt32) -> Bool { classes & mask != 0 }

    /// `is_tag` of the reference: tagged and (decorated, a flag, unambiguous, or ambiguity allowed).
    func isTag(allowAmbiguous: Bool) -> Bool {
        if tags.isEmpty { return false }
        return decorated || kind == .flag || strong || allowAmbiguous
    }
}

enum Prefold {
    /// Wraps a flag's country code in the folded text: " \u{1}TR\u{1} ".
    static let flagMarker: UInt32 = 1

    private static let pipes: Set<UInt32> = scalarSet("|¦│┃❘∣⏐⎪︱︳丨｜║▕▐")
    private static let dashes: Set<UInt32> = scalarSet("‐‑‒–—―−﹣－─━═")
    private static let colons: Set<UInt32> = scalarSet("：﹕꞉")
    private static let apostrophes: Set<UInt32> = scalarSet("’‘ʼ´`")
    private static let doubleQuotes: Set<UInt32> = scalarSet("“”„‟″")
    private static let openMap: [UInt32: UInt32] = scalarMap("【[〔[［[「[『[〈[《[（(")
    private static let closeMap: [UInt32: UInt32] = scalarMap("】]〕]］]」]』]〉]》]）)")
    private static let decor: Set<UInt32> = scalarSet("★☆✪✯✰⭐◉●○◎◆◇■□▶►▷▸▪▫♦♠♣♥❤✔✓✦✧❖➤➜→⇒«»•‣⁃✿❀✸✹✺✶✷✵⚡⚽🏆🔥🎬📺🎥🍿💎👑🌟✨")
    private static let drops: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x200E, 0x200F, 0x202A, 0x202B,
                                             0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFE0E, 0xFE0F]
    private static let squaredWords: [UInt32: String] = [0x1F195: "NEW", 0x1F193: "FREE", 0x1F197: "OK", 0x1F199: "UP",
                                                         0x1F192: "COOL", 0x1F196: "NG", 0x1F19A: "VS"]
    /// Superscript / modifier letters that providers use for tags ("ᴴᴰ", "⁴ᴷ", "⁶⁰ᶠᵖˢ"). Others fall back to NFKC.
    private static let superscripts: [UInt32: UInt32] = {
        let pairs = "ᴬA ᴮB ᴰD ᴱE ᴳG ᴴH ᴵI ᴶJ ᴷK ᴸL ᴹM ᴺN ᴼO ᴾP ᴿR ᵀT ᵁU ᵂW ⱽV ᵃa ᵇb ᶜc ᵈd ᵉe ᶠf ᵍg ʰh ⁱi ʲj ᵏk ˡl "
            + "ᵐm ⁿn ᵒo ᵖp ʳr ˢs ᵗt ᵘu ᵛv ʷw ˣx ʸy ᶻz ⁰0 ¹1 ²2 ³3 ⁴4 ⁵5 ⁶6 ⁷7 ⁸8 ⁹9 ⁺+ ⁻- ₀0 ₁1 ₂2 ₃3 ₄4 ₅5 ₆6 "
            + "₇7 ₈8 ₉9 ₊+ ₋- ₐa ₑe ₒo ₓx ₕh ₖk ₗl ₘm ₙn ₚp ₛs ₜt ᵢi ᵣr ᵤu ᵥv"
        var map: [UInt32: UInt32] = [:]
        for pair in pairs.split(separator: " ") {
            let scalars = Array(pair.unicodeScalars)
            if scalars.count == 2 { map[scalars[0].value] = scalars[1].value }
        }
        return map
    }()

    private static func scalarSet(_ s: String) -> Set<UInt32> { Set(s.unicodeScalars.map { $0.value }) }

    private static func scalarMap(_ s: String) -> [UInt32: UInt32] {
        let scalars = Array(s.unicodeScalars)
        var map: [UInt32: UInt32] = [:]
        var i = 0
        while i + 1 < scalars.count {
            map[scalars[i].value] = scalars[i + 1].value
            i += 2
        }
        return map
    }

    private static func isSuperOrModifier(_ cp: UInt32) -> Bool {
        cp == 0xB2 || cp == 0xB3 || cp == 0xB9 || (cp >= 0x2B0 && cp <= 0x2FF) || (cp >= 0x1D2C && cp <= 0x1D6A)
            || cp == 0x1D78 || (cp >= 0x1D9B && cp <= 0x1DBF) || (cp >= 0x2070 && cp <= 0x209F)
            || (cp >= 0x2C7C && cp <= 0x2C7D) || (cp >= 0xA69C && cp <= 0xA69D) || cp == 0xA770
            || (cp >= 0xA7F8 && cp <= 0xA7F9) || (cp >= 0xAB5C && cp <= 0xAB5F)
    }

    @inline(__always) static func isSpace(_ cp: UInt32) -> Bool { cp == 32 || (cp >= 9 && cp <= 13) }

    /// Returns the folded scalar values and, per value, whether it came from decoration. For pure-ASCII names the
    /// UTF-8 bytes are returned too (word strings are then sliced from them without per-character work).
    static func run(_ text: String) -> (values: [UInt32], decorated: [Bool], ascii: [UInt8]?) {
        var bytes = Array(text.utf8)
        var values: [UInt32] = []
        values.reserveCapacity(bytes.count + 2)
        var ascii = true
        var b = 0
        let byteCount = bytes.count
        while b < byteCount {
            let byte = bytes[b]
            if byte >= 0x80 { ascii = false; break }
            values.append(UInt32(byte))
            b += 1
        }
        if ascii {
            let (start, end) = trimmedBounds(values)
            if start != 0 || end != values.count {
                values = Array(values[start..<end])
                bytes = Array(bytes[start..<end])
            }
            // No decoration in ASCII names: `decorated` stays empty (scan treats empty as all-false).
            return (values, [], bytes)
        }
        values.removeAll(keepingCapacity: true)
        var dec: [Bool] = []
        dec.reserveCapacity(values.capacity)
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var i = 0
        @inline(__always) func put(_ cp: UInt32, _ decorated: Bool) { values.append(cp); dec.append(decorated) }
        func putString(_ s: String, _ decorated: Bool) { for u in s.unicodeScalars { put(u.value, decorated) } }
        while i < n {
            let scalar = scalars[i]
            let cp = scalar.value
            if cp < 0x80 { put(cp, false); i += 1; continue }
            // Regional-indicator pair -> FLAG token.
            if cp >= 0x1F1E6 && cp <= 0x1F1FF {
                if i + 1 < n, scalars[i + 1].value >= 0x1F1E6 && scalars[i + 1].value <= 0x1F1FF {
                    let a = 65 + cp - 0x1F1E6
                    let b = 65 + scalars[i + 1].value - 0x1F1E6
                    for v in [32, flagMarker, a, b, flagMarker, 32] { put(v, true) }
                    i += 2
                } else {
                    put(42, true)
                    i += 1
                }
                continue
            }
            // Subdivision flag (black flag + tag characters), e.g. England / Scotland / Wales -> GB.
            if cp == 0x1F3F4, i + 1 < n, scalars[i + 1].value >= 0xE0020 && scalars[i + 1].value <= 0xE007F {
                var j = i + 1
                while j < n && scalars[j].value >= 0xE0020 && scalars[j].value <= 0xE007F { j += 1 }
                for v in [32, flagMarker, 71, 66, flagMarker, 32] { put(v, true) }
                i = j
                continue
            }
            i += 1
            if drops.contains(cp) || (cp >= 0xE0000 && cp <= 0xE007F) || (cp >= 0x1F3FB && cp <= 0x1F3FF)
                || (cp >= 0x20DD && cp <= 0x20E4) {
                continue
            }
            if pipes.contains(cp) || (cp >= 0x258A && cp <= 0x258F) { put(124, false); continue }
            if dashes.contains(cp) { put(45, false); continue }
            if colons.contains(cp) { put(58, false); continue }
            if let open = openMap[cp] { put(open, false); continue }
            if let close = closeMap[cp] { put(close, false); continue }
            if apostrophes.contains(cp) { put(39, false); continue }
            if doubleQuotes.contains(cp) { put(34, false); continue }
            if cp == 0x2026 { put(46, false); put(46, false); put(46, false); continue }
            if cp == 0xB7 {
                // Middle dot: part of a word between letters ("WALL·E"), a separator otherwise.
                let between = i >= 2 && i < n && TextFold.isLetter(scalars[i - 2]) && TextFold.isLetter(scalars[i])
                if between { put(cp, false) } else { put(42, true) }
                continue
            }
            if cp == 0x1F51E { putString(" 18+ ", true); continue }
            if let word = squaredWords[cp] { putString(" " + word + " ", true); continue }
            if cp >= 0x1F150 && cp <= 0x1F169 { put(65 + cp - 0x1F150, true); continue }
            if cp >= 0x1F170 && cp <= 0x1F189 { put(65 + cp - 0x1F170, true); continue }
            if cp >= 0x1F130 && cp <= 0x1F149 { put(65 + cp - 0x1F130, true); continue }
            if cp >= 0x24B6 && cp <= 0x24CF { put(65 + cp - 0x24B6, true); continue }
            if cp >= 0x24D0 && cp <= 0x24E9 { put(97 + cp - 0x24D0, true); continue }
            if cp >= 0xFF01 && cp <= 0xFF5E { put(cp - 0xFEE0, false); continue }
            if isSuperOrModifier(cp) || (cp >= 0x1D400 && cp <= 0x1D7FF) {
                if let mapped = superscripts[cp] {
                    put(mapped, true)
                } else {
                    putString(String(Character(scalar)).precomposedStringWithCompatibilityMapping, true)
                }
                continue
            }
            if cp >= 0x2500 && cp <= 0x259F {
                put(42, true)
                continue
            }
            if decor.contains(cp) || (cp >= 0x2190 && cp <= 0x21FF) || (cp >= 0x2600 && cp <= 0x27BF)
                || (cp >= 0x2B00 && cp <= 0x2BFF) {
                put(42, true)
                continue
            }
            let scalarFlags = TextFold.flags(scalar)
            if scalarFlags & TextFold.flagSymbol != 0 { put(42, true); continue }
            if scalarFlags & TextFold.flagSpace != 0 {
                put(32, false)
                continue
            }
            put(cp, false)
        }
        let (start, end) = trimmedBounds(values)
        if start != 0 || end != values.count {
            values = Array(values[start..<end])
            dec = Array(dec[start..<end])
        }
        return (values, dec, nil)
    }

    private static func trimmedBounds(_ values: [UInt32]) -> (Int, Int) {
        var end = values.count
        while end > 0 && isSpace(values[end - 1]) { end -= 1 }
        var start = 0
        while start < end && isSpace(values[start]) { start += 1 }
        return (start, end)
    }
}

enum Tokenizer {
    /// Separators that always split: | : ( ) [ ] { } , * & ! ? " ;
    @inline(__always) static func isSeparatorChar(_ c: UInt32) -> Bool {
        switch c {
        case 124, 58, 40, 41, 91, 93, 123, 125, 44, 42, 38, 33, 63, 34, 59: return true
        default: return false
        }
    }

    /// Characters next to which a '-' is a separator: | : ( ) [ ] { } *
    @inline(__always) static func isDashNeighbor(_ c: UInt32) -> Bool {
        switch c {
        case 124, 58, 40, 41, 91, 93, 123, 125, 42: return true
        default: return false
        }
    }

    @inline(__always) static func isOpen(_ c: UInt32) -> Bool { c == 40 || c == 91 || c == 123 }
    @inline(__always) static func isClose(_ c: UInt32) -> Bool { c == 41 || c == 93 || c == 125 }

    static func scan(_ v: [UInt32], _ dec: [Bool], ascii: [UInt8]? = nil, kind: ParseKind) -> [Token] {
        let n = v.count
        var toks: [Token] = []
        toks.reserveCapacity(n / 3 + 2)
        var hasSpace = false
        var dots = 0
        var x = 0
        while x < n {
            let c = v[x]
            if c == 32 { hasSpace = true } else if c == 46 { dots += 1 }
            x += 1
        }
        let scene = !hasSpace && dots >= 2
        let anyDecoration = !dec.isEmpty
        var pendingWS = false
        var i = 0
        while i < n {
            let c = v[i]
            if c == Prefold.flagMarker {
                var j = i + 1
                while j < n && v[j] != Prefold.flagMarker { j += 1 }
                let code = makeString(v, i + 1, j)
                let facts = WordFacts(text: code, key: code, decorated: true, hasLetter: true, hasLower: false, hasDigit: false,
                                      length: j - i - 1)
                toks.append(Token(kind: .flag, facts: facts, wsBefore: pendingWS, wsAfter: isGap(v, j + 1, scene),
                                  tags: [Tag(.flag(code))]))
                pendingWS = false
                i = j + 1
                continue
            }
            if Prefold.isSpace(c) || c == 95 || (scene && c == 46 && !keepsDot(v, i)) {
                pendingWS = true
                var j = i
                while j < n && (Prefold.isSpace(v[j]) || v[j] == 95 || (scene && v[j] == 46)) { j += 1 }
                i = j
                continue
            }
            if c == 45, let end = negativeTimeshiftEnd(v, i) {
                toks.append(Classifier.word(makeWord(v, dec, i, end, ascii: ascii), kind: kind, wsBefore: pendingWS,
                                            wsAfter: isGap(v, end, scene)))
                pendingWS = false
                i = end
                continue
            }
            let dashSep = c == 45 && (i == 0 || i == n - 1 || Prefold.isSpace(v[i - 1]) || Prefold.isSpace(v[i + 1])
                || isDashNeighbor(v[i - 1]) || isDashNeighbor(v[i + 1]))
            if isSeparatorChar(c) || dashSep || (c == 47 && !(digit(v, i - 1) && digit(v, i + 1))) {
                toks.append(makeSeparator(c, anyDecoration && dec[i], wsBefore: pendingWS, wsAfter: isGap(v, i + 1, scene)))
                pendingWS = false
                i += 1
                continue
            }
            // Word chunk.
            var j = i
            while j < n {
                let cj = v[j]
                if Prefold.isSpace(cj) || cj == 95 || cj == Prefold.flagMarker || isSeparatorChar(cj) { break }
                if scene && cj == 46 && !keepsDot(v, j) { break }
                if cj == 47 && !(digit(v, j - 1) && digit(v, j + 1)) { break }
                if cj == 45 && (j + 1 >= n || Prefold.isSpace(v[j + 1]) || isDashNeighbor(v[j + 1])) { break }
                // Superscript/decorated runs are separate tokens: "TVᴴᴰ" -> "TV" + "HD".
                if anyDecoration && j > i && dec[j] != dec[j - 1] { break }
                j += 1
            }
            if j == i {
                toks.append(makeSeparator(c, anyDecoration && dec[i], wsBefore: pendingWS, wsAfter: isGap(v, i + 1, scene)))
                pendingWS = false
                i += 1
                continue
            }
            if isDecorativeRun(v, i, j) {
                toks.append(makeSeparator(42, true, wsBefore: pendingWS, wsAfter: isGap(v, j, scene)))
            } else {
                toks.append(Classifier.word(makeWord(v, dec, i, j, ascii: ascii), kind: kind, wsBefore: pendingWS,
                                            wsAfter: isGap(v, j, scene)))
            }
            pendingWS = false
            i = j
        }
        return toks
    }

    @inline(__always) private static func digit(_ v: [UInt32], _ k: Int) -> Bool {
        k >= 0 && k < v.count && TextFold.isASCIIDigit(v[k])
    }

    /// Scene-style names keep dots between short digit runs ("5.1", "DD5.1") and in "H.264"; "1994.1080p" splits.
    private static func keepsDot(_ v: [UInt32], _ k: Int) -> Bool {
        if digit(v, k - 1) && digit(v, k + 1) {
            var run = 0
            var x = k - 1
            while x >= 0 && TextFold.isASCIIDigit(v[x]) { run += 1; x -= 1 }
            return run <= 2
        }
        return k > 0 && (v[k - 1] == 72 || v[k - 1] == 104) && digit(v, k + 1)
    }

    /// Whitespace (or a scene dot) at `k`: the previous token has whitespace after it.
    private static func isGap(_ v: [UInt32], _ k: Int, _ scene: Bool) -> Bool {
        guard k < v.count else { return false }
        let c = v[k]
        return Prefold.isSpace(c) || c == 95 || (scene && c == 46 && !keepsDot(v, k))
    }

    /// "-1h" style negative timeshift: '-' after whitespace/start, 1-2 digits, 'h', then a boundary.
    private static func negativeTimeshiftEnd(_ v: [UInt32], _ i: Int) -> Int? {
        let n = v.count
        if i > 0 && !Prefold.isSpace(v[i - 1]) { return nil }
        var j = i + 1
        while j < n && j - i <= 2 && TextFold.isASCIIDigit(v[j]) { j += 1 }
        let digits = j - i - 1
        guard digits >= 1 && digits <= 2, j < n, v[j] == 72 || v[j] == 104 else { return nil }
        j += 1
        if j < n && !(Prefold.isSpace(v[j]) || isSeparatorChar(v[j])) { return nil }
        return j
    }

    /// ASCII decoration-only chunks ("#####", "===", "~~", "--") act like a '*' separator.
    private static func isDecorativeRun(_ v: [UInt32], _ a: Int, _ b: Int) -> Bool {
        var k = a
        while k < b {
            switch v[k] {
            case 35, 61, 126, 94, 60, 62, 45, 46: k += 1
            default: return false
            }
        }
        return true
    }

    static func makeString(_ v: [UInt32], _ a: Int, _ b: Int) -> String {
        var view = String.UnicodeScalarView()
        var k = a
        while k < b {
            if let s = Unicode.Scalar(v[k]) { view.append(s) }
            k += 1
        }
        return String(view)
    }

    /// One-character strings for ASCII separators (no per-token string building).
    private static let asciiStrings: [String] = (0..<128).map { String(UnicodeScalar(UInt8($0))) }

    private static func makeSeparator(_ c: UInt32, _ decorated: Bool, wsBefore: Bool, wsAfter: Bool) -> Token {
        let s = c < 128 ? asciiStrings[Int(c)] : (Unicode.Scalar(c).map { String(Character($0)) } ?? "*")
        let facts = WordFacts(text: s, key: s, decorated: decorated, hasLetter: false, hasLower: false, hasDigit: false,
                              length: 1)
        return Token(kind: .separator, facts: facts, sep: c, wsBefore: wsBefore, wsAfter: wsAfter, tags: [])
    }

    static func makeWord(_ v: [UInt32], _ dec: [Bool], _ a: Int, _ b: Int, ascii bytes: [UInt8]? = nil) -> WordFacts {
        var keyEnd = b
        while keyEnd - a > 1 && v[keyEnd - 1] == 46 { keyEnd -= 1 }
        var hasLetter = false
        var hasLower = false
        var hasDigit = false
        var decorated = false
        var hasDash = false
        if let bytes {
            // Pure-ASCII name: never decorated; strings are slices of the original bytes.
            var simple = true
            var k = a
            while k < b {
                let c = bytes[k]
                if c >= 97 && c <= 122 {
                    hasLower = true
                } else if c >= 65 && c <= 90 {
                    hasLetter = true
                } else if c >= 48 && c <= 57 {
                    hasDigit = true
                } else {
                    simple = false
                    if c == 45 { hasDash = true }
                }
                k += 1
            }
            if hasLower { hasLetter = true }
            let text = String(decoding: bytes[a..<b], as: UTF8.self)
            var key = hasLower ? text.uppercased() : text
            if keyEnd != b { key = String(decoding: Array(key.utf8)[0..<(keyEnd - a)], as: UTF8.self) }
            return WordFacts(text: text, key: key, decorated: false, hasLetter: hasLetter, hasLower: hasLower,
                             hasDigit: hasDigit, length: b - a, hasDash: hasDash, simple: simple)
        }
        var ascii = true
        var k0 = a
        while k0 < b {
            if v[k0] >= 0x80 { ascii = false; break }
            k0 += 1
        }
        if ascii {
            var text = [UInt8](repeating: 0, count: b - a)
            var k = a
            while k < b {
                let c = UInt8(truncatingIfNeeded: v[k])
                if dec[k] { decorated = true }
                text[k - a] = c
                if c >= 97 && c <= 122 {
                    hasLetter = true
                    hasLower = true
                } else if c >= 65 && c <= 90 {
                    hasLetter = true
                } else if c >= 48 && c <= 57 {
                    hasDigit = true
                } else if c == 45 {
                    hasDash = true
                }
                k += 1
            }
            let textString = String(decoding: text, as: UTF8.self)
            var keyString = hasLower ? textString.uppercased() : textString
            if keyEnd != b { keyString = String(decoding: Array(keyString.utf8)[0..<(keyEnd - a)], as: UTF8.self) }
            return WordFacts(text: textString, key: keyString, decorated: decorated, hasLetter: hasLetter, hasLower: hasLower,
                             hasDigit: hasDigit, length: b - a, hasDash: hasDash)
        }
        var text = String.UnicodeScalarView()
        var key = String.UnicodeScalarView()
        var k = a
        while k < b {
            let cp = v[k]
            if dec[k] { decorated = true }
            guard let s = Unicode.Scalar(cp) else { k += 1; continue }
            text.append(s)
            if cp == 45 { hasDash = true }
            if cp < 0x80 {
                if cp >= 97 && cp <= 122 {
                    hasLetter = true
                    hasLower = true
                    if k < keyEnd, let up = Unicode.Scalar(cp - 32) { key.append(up) }
                } else {
                    if cp >= 65 && cp <= 90 { hasLetter = true } else if cp >= 48 && cp <= 57 { hasDigit = true }
                    if k < keyEnd { key.append(s) }
                }
            } else {
                let f = TextFold.flags(s)
                if f & TextFold.flagLetter != 0 {
                    hasLetter = true
                    if f & TextFold.flagLower != 0 { hasLower = true }
                } else if f & TextFold.flagNumeric != 0 {
                    hasDigit = true
                }
                if k < keyEnd { TextFold.appendUpper(s, to: &key) }
            }
            k += 1
        }
        return WordFacts(text: String(text), key: String(key), decorated: decorated, hasLetter: hasLetter,
                         hasLower: hasLower, hasDigit: hasDigit, length: b - a, hasDash: hasDash)
    }
}
