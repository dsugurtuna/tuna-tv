import Foundation

/// Canonical dedupe key (stage 7 of the reference: `fold_letters` + `canonical_key`), hand-scanned:
/// folded case and diacritics (Turkish ı/İ -> i, ß -> ss, Arabic alef/yeh/teh-marbuta variants unified,
/// harakat/niqqud/tatweel dropped), "Matrix, The" inversion, "l'" elision, "+" -> "plus"/"and", "&" -> "and",
/// apostrophes joined, punctuation -> space, leading article dropped, roman numerals II..X -> digits,
/// "Part One" -> "part 1", whitespace collapsed. Live channels keep articles and numerals ("La 1", "Das Erste").
enum TitleKeyBuilder {
    static let articles: Set<String> = ["the", "a", "an", "der", "die", "das", "le", "la", "les", "el", "los", "il"]
    /// Multi-letter numerals convert anywhere but the first word ("Rocky II").
    static let romans: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]
    /// Single letters convert after a part word ("Part I") or as the last word ("Rocky V", "Fast X").
    static let romanSingles: [String: String] = ["i": "1", "v": "5", "x": "10"]
    static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                                                "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
    static let partWords: Set<String> = ["part", "chapter", "episode", "vol", "volume", "book", "season", "phase", "chapitre",
                                         "teil", "parte", "capitulo", "bolum", "kisim"]
    private static let arabicFold: [UInt32: UInt32] = [0x623: 0x627, 0x625: 0x627, 0x622: 0x627, 0x671: 0x627, 0x649: 0x64A,
                                                       0x629: 0x647, 0x624: 0x648, 0x626: 0x64A]

    static func make(_ title: String, live: Bool) -> String {
        let s = fold(title)
        let count = s.count
        // One boundary pass. Literal tokens: "plus" / "and". Apostrophes join words ("schindler's").
        var tokens: [String] = []
        var start = -1
        var apostrophe = false
        var lastComma = -1
        var tokensAtComma = 0
        func flush(_ end: Int) {
            guard start >= 0 else { return }
            if apostrophe {
                var bytes: [UInt8] = []
                var k = start
                while k < end {
                    if s[k] != 39 { bytes.append(s[k]) }
                    k += 1
                }
                tokens.append(String(decoding: bytes, as: UTF8.self))
            } else {
                tokens.append(String(decoding: s[start..<end], as: UTF8.self))
            }
            start = -1
            apostrophe = false
        }
        var i = 0
        while i < count {
            let c = s[i]
            if c >= 0x80 || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
                if start < 0 { start = i }
            } else if c == 39 {
                // "l'odyssée" / "d'artagnan" at the very start: the elided article goes.
                if start == 0 && i == 1 && (s[0] == 108 || s[0] == 100) && tokens.isEmpty && i + 1 < count
                    && isWordByte(s[i + 1]) {
                    start = -1
                } else if start >= 0 {
                    apostrophe = true
                }
            } else {
                flush(i)
                if c == 43 {  // '+'
                    let previousWord = i > 0 && isWordByte(s[i - 1])
                    let nextIsBoundary = i + 1 >= count || s[i + 1] == 32
                    if previousWord && nextIsBoundary {
                        tokens.append("plus")
                    } else if i > 0 && s[i - 1] == 32 && i + 1 < count && s[i + 1] == 32 {
                        tokens.append("and")
                    }
                } else if c == 38 {
                    tokens.append("and")
                } else if c == 44 {
                    lastComma = i
                    tokensAtComma = tokens.count
                }
            }
            i += 1
        }
        flush(count)
        return assemble(tokens, live: live, inverted: lastComma >= 0 && tokens.count == tokensAtComma + 1)
    }

    /// Article inversion/drop, numerals and "Part One" over folded words, joined with single spaces.
    static func assemble(_ words: [String], live: Bool, inverted: Bool) -> String {
        var tokens = words
        // "Matrix, The" -> "matrix"
        if inverted, let last = tokens.last, articles.contains(last) { tokens.removeLast() }
        if !live && tokens.count >= 2 && articles.contains(tokens[0]) { tokens.removeFirst() }
        if !live {
            let last = tokens.count - 1
            var index = 1
            while index <= last {
                let token = tokens[index]
                if token.utf8.count <= 5 {
                    if let digit = romans[token] {
                        tokens[index] = digit
                    } else if let digit = romanSingles[token],
                              partWords.contains(tokens[index - 1]) || (token != "i" && index == last) {
                        tokens[index] = digit
                    } else if let digit = numberWords[token], partWords.contains(tokens[index - 1]) {
                        tokens[index] = digit
                    }
                }
                index += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    @inline(__always) private static func isWordByte(_ c: UInt8) -> Bool {
        c >= 0x80 || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
    }

    /// Lowercase, diacritic-free UTF-8 (see type doc). Non-ASCII punctuation/symbols become spaces, so every
    /// byte >= 0x80 in the result belongs to a word.
    private static func fold(_ title: String) -> [UInt8] {
        let lower = title.lowercased()
        var out = Array(lower.utf8)
        var ascii = true
        var k = 0
        while k < out.count {
            if out[k] >= 0x80 { ascii = false; break }
            k += 1
        }
        if ascii { return out }
        out.removeAll(keepingCapacity: true)
        func put(_ scalar: Unicode.Scalar) { out.append(contentsOf: String(Character(scalar)).utf8) }
        func putString(_ text: String) { out.append(contentsOf: text.utf8) }
        var previousLatinLike = false
        let loop1Items = Array(title.unicodeScalars)
        var loop1 = 0
        while loop1 < loop1Items.count {
            let scalar = loop1Items[loop1]
            loop1 += 1
            let cp = scalar.value
            if cp < 0x80 {
                let c = UInt8(cp)
                out.append(c >= 65 && c <= 90 ? c + 32 : c)
                previousLatinLike = TextFold.isASCIILetter(cp)
                continue
            }
            if cp == 0x640 { continue }  // tatweel
            let scalarFlags = TextFold.flags(scalar)
            if scalarFlags & TextFold.flagMark != 0 {
                if previousLatinLike { continue }
                if (cp >= 0x64B && cp <= 0x65F) || cp == 0x670 || (cp >= 0x591 && cp <= 0x5C7) { continue }
                put(scalar)
                continue
            }
            if let entry = TextFold.tableEntry(cp, upper: false) {
                putString(entry)
                previousLatinLike = true
                continue
            }
            previousLatinLike = false
            if let mapped = arabicFold[cp], let arabic = Unicode.Scalar(mapped) {
                put(arabic)
            } else if cp == 0x2019 || cp == 0x2018 || cp == 0x2BC || cp == 0xB4 {
                out.append(39)
            } else if cp >= 0xFF01 && cp <= 0xFF5E {
                let c = UInt8(cp - 0xFEE0)
                out.append(c >= 65 && c <= 90 ? c + 32 : c)
            } else if scalarFlags & TextFold.flagAlnumOrMark == 0 {
                out.append(32)
            } else if scalarFlags & TextFold.flagLetter != 0 && scalar.properties.changesWhenLowercased {
                putString(scalar.properties.lowercaseMapping)
            } else {
                put(scalar)
            }
        }
        return out
    }
}

/// Dominant-script language hint (stage 6 of the reference).
enum ScriptDetection {
    private enum Script: Int, CaseIterable {
        case latin, arabic, cyrillic, greek, hebrew, kana, hangul, han, devanagari, bengali, tamil, telugu, thai, georgian,
             armenian, gurmukhi, gujarati, kannada, malayalam, sinhala, ethiopic, khmer, lao, myanmar, other
    }

    private static let persian: Set<UInt32> = [0x67E, 0x686, 0x698, 0x6AF, 0x6A9, 0x6CC]
    private static let urdu: Set<UInt32> = [0x6D2, 0x679, 0x688, 0x691, 0x6BA]
    private static let ukrainian: Set<UInt32> = Set("іїєґІЇЄҐ".unicodeScalars.map { $0.value })
    private static let serbian: Set<UInt32> = Set("ђјљњћџЂЈЉЊЋЏ".unicodeScalars.map { $0.value })
    private static let macedonian: Set<UInt32> = Set("ѓќѕЃЌЅ".unicodeScalars.map { $0.value })
    private static let kazakh: Set<UInt32> = Set("әғқңөұүһӘҒҚҢӨҰҮҺ".unicodeScalars.map { $0.value })
    private static let turkish: Set<UInt32> = Set("ğĞıİşŞ".unicodeScalars.map { $0.value })
    private static let romanian: Set<UInt32> = Set("ăĂțȚșȘţŢ".unicodeScalars.map { $0.value })

    static func hint(_ text: String) -> String? {
        let scriptCount = Script.allCases.count
        var counts = [Int](repeating: 0, count: scriptCount)
        var firstSeen = [Int](repeating: Int.max, count: scriptCount)
        var fa = false, ur = false, uk = false, sr = false, mk = false, kk = false, be = false
        var tr = false, ro = false, az = false
        var position = 0
        let loop2Items = Array(text.unicodeScalars)
        var loop2 = 0
        while loop2 < loop2Items.count {
            let scalar = loop2Items[loop2]
            loop2 += 1
            let cp = scalar.value
            let script: Script
            if cp < 0x80 {
                guard TextFold.isASCIILetter(cp) else { continue }
                script = .latin
            } else {
                guard TextFold.flags(scalar) & TextFold.flagLetterCategory != 0 else { continue }
                script = classify(cp)
                switch script {
                case .arabic:
                    if persian.contains(cp) { fa = true }
                    if urdu.contains(cp) { ur = true }
                case .cyrillic:
                    if ukrainian.contains(cp) { uk = true }
                    if serbian.contains(cp) { sr = true }
                    if macedonian.contains(cp) { mk = true }
                    if kazakh.contains(cp) { kk = true }
                    if cp == 0x45E || cp == 0x40E { be = true }
                case .latin:
                    if turkish.contains(cp) { tr = true }
                    if romanian.contains(cp) { ro = true }
                    if cp == 0x259 || cp == 0x18F { az = true }
                default:
                    break
                }
            }
            counts[script.rawValue] += 1
            if firstSeen[script.rawValue] == Int.max { firstSeen[script.rawValue] = position }
            position += 1
        }
        var best = -1
        var loop3 = 0
        while loop3 < scriptCount {
            let index = loop3
            loop3 += 1
            guard counts[index] > 0 else { continue }
            if best < 0 || counts[index] > counts[best] || (counts[index] == counts[best] && firstSeen[index] < firstSeen[best]) {
                best = index
            }
        }
        guard best >= 0, let dominant = Script(rawValue: best) else { return nil }
        switch dominant {
        case .kana: return "ja"
        case .han: return counts[Script.kana.rawValue] > 0 ? "ja" : "zh"
        case .arabic: return ur ? "ur" : (fa ? "fa" : "ar")
        case .cyrillic:
            if uk { return "uk" }
            if sr { return "sr" }
            if mk { return "mk" }
            if kk { return "kk" }
            if be { return "be" }
            return "ru"
        case .latin:
            if az { return "az" }
            return tr && !ro ? "tr" : nil
        case .greek: return "el"
        case .hebrew: return "he"
        case .hangul: return "ko"
        case .devanagari: return "hi"
        case .bengali: return "bn"
        case .tamil: return "ta"
        case .telugu: return "te"
        case .thai: return "th"
        case .georgian: return "ka"
        case .armenian: return "hy"
        case .gurmukhi: return "pa"
        case .gujarati: return "gu"
        case .kannada: return "kn"
        case .malayalam: return "ml"
        case .sinhala: return "si"
        case .ethiopic: return "am"
        case .khmer: return "km"
        case .lao: return "lo"
        case .myanmar: return "my"
        case .other: return nil
        }
    }

    private static func classify(_ cp: UInt32) -> Script {
        switch cp {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0400...0x052F: return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0590...0x05FF: return .hebrew
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF: return .han
        case 0x0900...0x097F: return .devanagari
        case 0x0980...0x09FF: return .bengali
        case 0x0A00...0x0A7F: return .gurmukhi
        case 0x0A80...0x0AFF: return .gujarati
        case 0x0B80...0x0BFF: return .tamil
        case 0x0C00...0x0C7F: return .telugu
        case 0x0C80...0x0CFF: return .kannada
        case 0x0D00...0x0D7F: return .malayalam
        case 0x0D80...0x0DFF: return .sinhala
        case 0x0E00...0x0E7F: return .thai
        case 0x0E80...0x0EFF: return .lao
        case 0x1000...0x109F: return .myanmar
        case 0x10A0...0x10FF: return .georgian
        case 0x0530...0x058F: return .armenian
        case 0x1200...0x137F: return .ethiopic
        case 0x1780...0x17FF: return .khmer
        case 0x0000...0x024F, 0x1E00...0x1EFF: return .latin
        default: return .other
        }
    }
}
