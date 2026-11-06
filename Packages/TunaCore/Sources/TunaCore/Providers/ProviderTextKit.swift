import Foundation

/// Text, number and date helpers shared by the provider parsers. Everything a provider sends is untrusted input:
/// text is cleaned (no control or bidi-override characters, capped), links are http(s) only, dates are sanity-checked.
/// Internal and prefixed so it cannot clash with helpers of other modules in the same target.
enum ProviderTextKit {
    // MARK: - Text

    /// Single-line text: control characters become spaces, bidi overrides/isolates are dropped, trimmed and capped.
    /// nil when nothing is left.
    static func line(_ raw: String?, max: Int = 1000) -> String? {
        guard let raw else { return nil }
        var text = raw
        if needsCleaning(raw) {
            var out = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                if isBidiControl(scalar) { continue }
                if scalar.properties.generalCategory == .control { out.append(" "); continue }
                out.append(scalar)
            }
            text = String(out)
        }
        return capped(text.trimmingCharacters(in: .whitespacesAndNewlines), max: max)
    }

    /// Multi-line text (plots, descriptions): CRLF/CR become LF, other control and bidi characters are dropped,
    /// runs of blank lines are shortened, trimmed and capped. nil when nothing is left.
    static func paragraph(_ raw: String?, max: Int = 8000) -> String? {
        guard let raw else { return nil }
        var text = raw
        if needsCleaning(raw) {
            var out = String.UnicodeScalarView()
            var previousWasCR = false
            for scalar in raw.unicodeScalars {
                defer { previousWasCR = scalar == "\r" }
                switch scalar.value {
                case 0x0A: if !previousWasCR { out.append("\n") }
                case 0x0D, 0x2028, 0x2029: out.append("\n")
                case 0x09: out.append(" ")
                default:
                    if isBidiControl(scalar) || scalar.properties.generalCategory == .control { continue }
                    out.append(scalar)
                }
            }
            text = String(out)
            while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        }
        return capped(text.trimmingCharacters(in: .whitespacesAndNewlines), max: max)
    }

    private static func needsCleaning(_ text: String) -> Bool {
        // ASCII control bytes, C1 controls (0xC2 0x80-0x9F) and the U+2000 block (bidi controls live there).
        for byte in text.utf8 where byte < 0x20 || byte == 0x7F || byte == 0xC2 || byte == 0xE2 { return true }
        return false
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    private static func capped(_ text: String, max: Int) -> String? {
        if text.isEmpty { return nil }
        guard text.count > max else { return text }
        return String(text.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Links

    /// An http(s) link the app may fetch later (logos, posters). Other schemes (`file:`, `data:`, `javascript:`) and
    /// absurdly long values are dropped; spaces are percent-encoded.
    static func httpURLString(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 2048 else { return nil }
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        if text.contains(" ") { text = text.replacingOccurrences(of: " ", with: "%20") }
        guard text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }), URL(string: text)?.host != nil else { return nil }
        return text
    }

    // MARK: - Base64 (Xtream EPG titles and descriptions)

    /// Decoded UTF-8 text when `raw` is base64 (standard or URL-safe, padding optional), else nil.
    static func base64Text(_ raw: String) -> String? {
        var compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.contains(where: { $0 == "\n" || $0 == "\r" }) { compact.removeAll { $0 == "\n" || $0 == "\r" } }
        guard !compact.isEmpty else { return nil }
        var sawPadding = false
        for byte in compact.utf8 {
            switch byte {
            case UInt8(ascii: "="): sawPadding = true
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                if sawPadding { return nil }
            default: return nil
            }
        }
        var standard = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard), let text = String(data: data, encoding: .utf8) else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control {
            if scalar != "\n" && scalar != "\r" && scalar != "\t" { return nil }
        }
        return text
    }

    // MARK: - Live markers

    /// True when a programme title marks itself as live ("LIVE", "Live:", "(Live)", "🔴").
    static func looksLive(_ title: String) -> Bool {
        if title.contains("🔴") { return true }
        let lower = title.lowercased()
        for prefix in ["live:", "live -", "live |", "live!"] where lower.hasPrefix(prefix) { return true }
        if lower.contains("(live)") || lower.contains("[live]") { return true }
        return title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("LIVE")
    }

    // MARK: - Numbers

    /// The first decimal number in `text` ("7.5/10" -> 7.5, "7,5" -> 7.5, "105 min" -> 105).
    static func firstNumber(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if isDigit(bytes[index]) {
                var end = index
                while end < bytes.count && isDigit(bytes[end]) { end += 1 }
                if end + 1 < bytes.count && (bytes[end] == UInt8(ascii: ".") || bytes[end] == UInt8(ascii: ",")) && isDigit(bytes[end + 1]) {
                    end += 1
                    while end < bytes.count && isDigit(bytes[end]) { end += 1 }
                }
                let negative = index > 0 && bytes[index - 1] == UInt8(ascii: "-")
                let literal = String(decoding: bytes[index..<end], as: UTF8.self).replacingOccurrences(of: ",", with: ".")
                guard let value = Double(literal) else { return nil }
                return negative ? -value : value
            }
            index += 1
        }
        return nil
    }

    /// Minutes from "01:45:00", "105 min", "1h 45m", "1h45", or a bare number (above 600 it is seconds).
    /// nil outside 0.5 min ... 24 h (a broken value).
    static func minutes(fromDuration raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        func valid(_ minutes: Double) -> Double? { minutes.isFinite && minutes >= 0.5 && minutes <= 1440 ? minutes : nil }
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 || parts.count == 3, !parts.contains(where: { $0 == nil }) else { return nil }
            let values = parts.compactMap { $0 }
            return valid(values[0] * 60 + values[1] + (values.count == 3 ? values[2] / 60 : 0))
        }
        if let hIndex = text.firstIndex(of: "h"), let hours = firstNumber(String(text[..<hIndex])) {
            let rest = String(text[text.index(after: hIndex)...])
            return valid(hours * 60 + (firstNumber(rest) ?? 0))
        }
        guard let number = firstNumber(text) else { return nil }
        if text.contains("sec") || text.hasSuffix("s") && !text.contains("min") { return valid(number / 60) }
        return valid(number > 600 ? number / 60 : number)
    }

    // MARK: - YouTube trailers

    /// A bare YouTube video id, or one taken from a youtube.com / youtu.be link. Anything else is nil.
    static func youTubeID(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 300 else { return nil }
        if isVideoID(text) { return text }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased() else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        var candidate: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            candidate = path.first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com":
            if path.first == "watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if path.count >= 2, ["embed", "shorts", "v", "live"].contains(path[0]) {
                candidate = path[1]
            }
        default:
            candidate = nil
        }
        guard let id = candidate, isVideoID(id) else { return nil }
        return id
    }

    private static func isVideoID(_ text: String) -> Bool {
        guard (6...20).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { isAlphanumericASCII($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
    }

    // MARK: - Dates

    /// Plausible Unix time (seconds; millisecond values are scaled). nil for 0, negatives and "never" values (>= 2100).
    static func unixDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        guard seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm; no Calendar, thread-safe).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Seconds since 1970 for a wall-clock time in UTC, or nil when a field is out of range.
    static func utcSeconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day), (0...24).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
    }

    /// XMLTV date: "YYYYMMDDhhmmss +hhmm" (offset optional = UTC; seconds/minutes may be missing; "+hh:mm", "Z" accepted).
    static func xmltvDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count && bytes[index] == UInt8(ascii: " ") { index += 1 }
        var digits: [Int] = []
        while index < bytes.count && isDigit(bytes[index]) {
            if digits.count < 14 { digits.append(Int(bytes[index] - 48)) }
            index += 1
        }
        guard digits.count >= 8 else { return nil }
        func number(_ from: Int, _ count: Int) -> Int {
            guard from + count <= digits.count else { return 0 }
            return digits[from..<(from + count)].reduce(0) { $0 * 10 + $1 }
        }
        guard let local = utcSeconds(year: number(0, 4), month: number(4, 2), day: number(6, 2),
                                     hour: number(8, 2), minute: number(10, 2), second: number(12, 2)) else { return nil }
        while index < bytes.count && bytes[index] == UInt8(ascii: " ") { index += 1 }
        var offset = 0
        if index < bytes.count && (bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")) {
            let sign = bytes[index] == UInt8(ascii: "-") ? -1 : 1
            index += 1
            var tz: [Int] = []
            while index < bytes.count && tz.count < 4 && (isDigit(bytes[index]) || bytes[index] == UInt8(ascii: ":")) {
                if isDigit(bytes[index]) { tz.append(Int(bytes[index] - 48)) }
                index += 1
            }
            guard tz.count == 4 || tz.count == 2 else { return nil }
            let hours = tz[0] * 10 + tz[1]
            let minutes = tz.count == 4 ? tz[2] * 10 + tz[3] : 0
            guard hours <= 14, minutes <= 59 else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        }
        return Date(timeIntervalSince1970: TimeInterval(local - offset))
    }

    /// "2026-11-06 20:30:00" style panel timestamps (also "T" separator, seconds optional), read in `timeZone`
    /// (UTC when nil).
    static func panelDateTime(_ text: String, timeZone: TimeZone?) -> Date? {
        var fields: [Int] = []
        var current = 0
        var inNumber = false
        for byte in text.utf8 {
            if isDigit(byte) {
                current = current * 10 + Int(byte - 48)
                inNumber = true
            } else if inNumber {
                fields.append(current)
                current = 0
                inNumber = false
                if fields.count == 6 { break }
            }
        }
        if inNumber && fields.count < 6 { fields.append(current) }
        guard fields.count >= 3, fields[0] >= 1900 else { return nil }
        func field(_ index: Int) -> Int { index < fields.count ? fields[index] : 0 }
        guard let naive = utcSeconds(year: fields[0], month: fields[1], day: fields[2], hour: field(3), minute: field(4),
                                     second: field(5)) else { return nil }
        guard let timeZone else { return Date(timeIntervalSince1970: TimeInterval(naive)) }
        let guess = Date(timeIntervalSince1970: TimeInterval(naive))
        let firstOffset = timeZone.secondsFromGMT(for: guess)
        let refinedOffset = timeZone.secondsFromGMT(for: guess.addingTimeInterval(TimeInterval(-firstOffset)))
        return Date(timeIntervalSince1970: TimeInterval(naive - refinedOffset))
    }

    /// The first plausible year (1900...2100) in `text` that is not part of a longer number ("2019-05-24" -> 2019).
    static func year(in text: String) -> Int? {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            guard isDigit(bytes[index]) else { index += 1; continue }
            var end = index
            while end < bytes.count && isDigit(bytes[end]) { end += 1 }
            if end - index == 4 {
                let value = bytes[index..<end].reduce(0) { $0 * 10 + Int($1 - 48) }
                if (1900...2100).contains(value) { return value }
            }
            index = end
        }
        return nil
    }

    // MARK: - Episode markers in names ("Show S01E02 - Title", "Show S1 E2", "Show 1x02")

    struct EpisodeMarker: Hashable, Sendable {
        /// Text before the marker, separators trimmed (may be empty).
        var show: String
        var season: Int
        var episode: Int
        /// Text after the marker, separators trimmed.
        var title: String?
    }

    static func episodeMarker(in name: String) -> EpisodeMarker? {
        let scalars = Array(name.unicodeScalars)
        let count = scalars.count
        func isDigitAt(_ i: Int) -> Bool { i >= 0 && i < count && scalars[i].value >= 48 && scalars[i].value <= 57 }
        func isAlnumAt(_ i: Int) -> Bool { i >= 0 && i < count && (isDigitAt(i) || scalars[i].properties.isAlphabetic) }
        func readNumber(_ i: inout Int, maxDigits: Int) -> Int? {
            var value = 0
            var digits = 0
            while isDigitAt(i) && digits < maxDigits {
                value = value * 10 + Int(scalars[i].value - 48)
                i += 1
                digits += 1
            }
            return digits > 0 && !isDigitAt(i) ? value : nil
        }
        func marker(start: Int, end: Int, season: Int, episode: Int) -> EpisodeMarker {
            let show = trimSeparators(String(String.UnicodeScalarView(scalars[0..<start])))
            let title = trimSeparators(String(String.UnicodeScalarView(scalars[end..<count])))
            return EpisodeMarker(show: show, season: season, episode: episode, title: title.isEmpty ? nil : title)
        }
        var i = 0
        while i < count {
            let scalar = scalars[i]
            if (scalar == "S" || scalar == "s") && !isAlnumAt(i - 1) {
                var j = i + 1
                if let season = readNumber(&j, maxDigits: 3) {
                    var k = j
                    var separators = 0
                    while k < count && separators < 2 && [" ", ".", "_", "-"].contains(scalars[k]) { k += 1; separators += 1 }
                    if k < count && (scalars[k] == "E" || scalars[k] == "e") {
                        var m = k + 1
                        if m < count && (scalars[m] == "p" || scalars[m] == "P") { m += 1 }
                        if let episode = readNumber(&m, maxDigits: 4) {
                            return marker(start: i, end: m, season: season, episode: episode)
                        }
                    }
                }
            } else if isDigitAt(i) && !isAlnumAt(i - 1) {
                var j = i
                if let season = readNumber(&j, maxDigits: 2), j < count, scalars[j] == "x" || scalars[j] == "X" {
                    var m = j + 1
                    let episodeStart = m
                    if let episode = readNumber(&m, maxDigits: 3), m - episodeStart >= 2, !isAlnumAt(m) {
                        return marker(start: i, end: m, season: season, episode: episode)
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static let separatorScalars: Set<Unicode.Scalar> = [" ", "-", "|", ":", ".", "_", "–", "—", "(", ")", "[", "]", ",", "\t"]

    static func trimSeparators(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, separatorScalars.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, separatorScalars.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    // MARK: - Bytes

    @inline(__always) static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    @inline(__always) static func isAlphanumericASCII(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}
