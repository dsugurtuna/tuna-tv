import Foundation

/// Scalar-level case and diacritic folding shared by the tokenizer, `TitleKey`, the lexicon and the category
/// prettifier. Latin, Greek and Cyrillic letters go through two tables computed once with Foundation; ASCII is
/// handled arithmetically and everything else through stdlib scalar properties, so the hot path never calls
/// Foundation per name.
enum TextFold {
    private static let tableLow: UInt32 = 0xC0
    private static let tableHigh: UInt32 = 0x1FFF

    /// Letters Foundation's diacritic folding does not reduce (or reduces differently than we want).
    private static let special: [UInt32: String] = [
        0x131: "i", 0x130: "i", 0xDF: "ss", 0x1E9E: "ss", 0xE6: "ae", 0xC6: "ae", 0x153: "oe", 0x152: "oe",
        0xF8: "o", 0xD8: "o", 0x111: "d", 0x110: "d", 0x142: "l", 0x141: "l", 0xFE: "th", 0xDE: "th",
        0xF0: "d", 0xD0: "d", 0x127: "h", 0x126: "h", 0x140: "l", 0x13F: "l", 0x3C2: "σ",
    ]

    /// Folded lowercase (diacritics removed) per scalar of the covered ranges; nil = not covered.
    static let lowerTable: [String?] = buildTable(upper: false)
    /// Folded uppercase per scalar of the covered ranges; nil = not covered.
    static let upperTable: [String?] = buildTable(upper: true)

    private static func covered(_ cp: UInt32) -> Bool {
        (cp >= 0xC0 && cp <= 0x24F) || (cp >= 0x370 && cp <= 0x4FF) || (cp >= 0x1E00 && cp <= 0x1FFF)
    }

    private static func buildTable(upper: Bool) -> [String?] {
        var table = [String?](repeating: nil, count: Int(tableHigh - tableLow + 1))
        for cp in tableLow...tableHigh where covered(cp) {
            guard let scalar = Unicode.Scalar(cp) else { continue }
            var folded: String
            if let fixed = special[cp] {
                folded = fixed
            } else {
                guard scalar.properties.isAlphabetic else { continue }
                folded = String(Character(scalar)).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            }
            if upper { folded = folded.uppercased() }
            table[Int(cp - tableLow)] = folded
        }
        return table
    }

    @inline(__always) static func tableEntry(_ cp: UInt32, upper: Bool) -> String? {
        guard cp >= tableLow && cp <= tableHigh else { return nil }
        return upper ? upperTable[Int(cp - tableLow)] : lowerTable[Int(cp - tableLow)]
    }

    /// Appends the folded uppercase form of `scalar` (the lexicon key alphabet): ASCII uppercased, Latin/Greek/
    /// Cyrillic diacritics removed, nonspacing marks dropped, other scripts uppercased when they have case.
    static func appendUpper(_ scalar: Unicode.Scalar, to out: inout String.UnicodeScalarView) {
        let cp = scalar.value
        if cp < 0x80 {
            if cp >= 97 && cp <= 122, let up = Unicode.Scalar(cp - 32) { out.append(up) } else { out.append(scalar) }
            return
        }
        if let entry = tableEntry(cp, upper: true) {
            out.append(contentsOf: entry.unicodeScalars)
            return
        }
        if flags(scalar) & flagMark != 0 { return }
        let props = scalar.properties
        if props.changesWhenUppercased {
            out.append(contentsOf: props.uppercaseMapping.unicodeScalars)
        } else {
            out.append(scalar)
        }
    }

    /// Folded uppercase key of a whole string (used to build lexicon keys the same way tokens are keyed).
    static func upperKey(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let loop1Items = Array(text.unicodeScalars)
        var loop1 = 0
        while loop1 < loop1Items.count {
            let scalar = loop1Items[loop1]
            loop1 += 1
            appendUpper(scalar, to: &out)
        }
        return String(out)
    }

    // MARK: Scalar flags (precomputed for U+0000..U+30FF, stdlib properties beyond)

    static let flagLetter: UInt8 = 1        // alphabetic, not a combining mark
    static let flagLower: UInt8 = 2
    static let flagMark: UInt8 = 4          // nonspacing or enclosing mark
    static let flagNumeric: UInt8 = 8
    static let flagSymbol: UInt8 = 16       // other symbol (So)
    static let flagSpace: UInt8 = 32        // Zs / Zl / Zp
    static let flagAlnumOrMark: UInt8 = 64  // L*, N*, Mn, Mc (title-key word characters)
    static let flagLetterCategory: UInt8 = 128  // Lu Ll Lt Lm Lo

    private static let flagTableSize: UInt32 = 0x3100
    private static let flagTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: Int(flagTableSize))
        var cp: UInt32 = 0
        while cp < flagTableSize {
            if let scalar = Unicode.Scalar(cp) { table[Int(cp)] = computeFlags(scalar) }
            cp += 1
        }
        return table
    }()

    private static func computeFlags(_ scalar: Unicode.Scalar) -> UInt8 {
        let props = scalar.properties
        let category = props.generalCategory
        var f: UInt8 = 0
        let mark = category == .nonspacingMark || category == .enclosingMark
        if props.isAlphabetic && !mark && category != .spacingMark { f |= flagLetter }
        if props.isLowercase { f |= flagLower }
        if mark { f |= flagMark }
        if props.numericType != nil { f |= flagNumeric }
        switch category {
        case .otherSymbol: f |= flagSymbol
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: f |= flagSpace
        default: break
        }
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            f |= flagAlnumOrMark | flagLetterCategory
        case .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark:
            f |= flagAlnumOrMark
        default:
            break
        }
        return f
    }

    /// Character-class flags of a scalar (table lookup for the scripts IPTV names use).
    @inline(__always) static func flags(_ scalar: Unicode.Scalar) -> UInt8 {
        let cp = scalar.value
        if cp < flagTableSize { return flagTable[Int(cp)] }
        return computeFlags(scalar)
    }

    @inline(__always) static func isASCIIDigit(_ cp: UInt32) -> Bool { cp >= 48 && cp <= 57 }
    @inline(__always) static func isASCIILetter(_ cp: UInt32) -> Bool { (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) }

    /// Letter test that is cheap for ASCII.
    @inline(__always) static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        if cp < 0x80 { return isASCIILetter(cp) }
        return flags(scalar) & flagLetter != 0
    }

    @inline(__always) static func isLowercase(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        if cp < 0x80 { return cp >= 97 && cp <= 122 }
        return flags(scalar) & flagLower != 0
    }

    /// Title-cases one all-caps word with Turkish-safe lowering ("FİLMLER" -> "Filmler", "ÇOCUK" -> "Çocuk").
    static func capitalizeWord(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        var first = true
        let loop2Items = Array(word.unicodeScalars)
        var loop2 = 0
        while loop2 < loop2Items.count {
            let scalar = loop2Items[loop2]
            loop2 += 1
            if first {
                out.append(scalar)
                if isLetter(scalar) { first = false }
                continue
            }
            let cp = scalar.value
            if cp == 0x130 { out.append("i"); continue }
            if cp < 0x80 {
                if cp >= 65 && cp <= 90, let low = Unicode.Scalar(cp + 32) { out.append(low) } else { out.append(scalar) }
                continue
            }
            if scalar.properties.changesWhenLowercased {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
