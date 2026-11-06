import Foundation

/// Tolerant readers over `JSONSerialization` output. Xtream panels are loosely typed: ids and numbers arrive as
/// strings or numbers, empty values as `null`, `""`, `false` or `[]`, lists sometimes as objects keyed by index.
enum XtreamJSONKit {
    /// Hard cap for one provider response we are willing to parse (a bigger one is broken or hostile).
    static let maxResponseBytes = 300_000_000

    /// Parses a response body. An empty or whitespace-only body is `NSNull` (panels answer that for "nothing").
    /// HTML (an error page from the panel or Cloudflare) and other non-JSON bodies throw `TunaError.decoding`.
    static func parse(_ data: Data) throws -> Any {
        guard data.count <= maxResponseBytes else { throw TunaError.decoding("The response is too large.") }
        guard let first = data.firstIndex(where: { !isWhitespace($0) }) else { return NSNull() }
        var body = data
        if data.count >= 3 && data[data.startIndex] == 0xEF && data[data.startIndex + 1] == 0xBB && data[data.startIndex + 2] == 0xBF {
            body = data.subdata(in: (data.startIndex + 3)..<data.endIndex)
            if !body.contains(where: { !isWhitespace($0) }) { return NSNull() }
        }
        if data[first] == UInt8(ascii: "<") { throw TunaError.decoding(describeMarkup(data)) }
        do {
            return try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw TunaError.decoding("The provider did not send valid JSON.")
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// A short, credential-free description of an HTML body for error messages and logs.
    static func describeMarkup(_ data: Data) -> String {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if head.contains("cloudflare") { return "The provider sent a Cloudflare error page instead of data." }
        return "The provider sent a web page instead of data."
    }

    // MARK: - Booleans vs numbers

    /// True for JSON `true`/`false`. On every platform `JSONSerialization` returns booleans as NSNumber, and on Linux
    /// even `1 as? Bool` succeeds, so the boolean is recognised by its type encoding / CF type instead.
    static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let encoding = number.objCType
        return encoding[0] == 0x63 && encoding[1] == 0   // "c"
        #endif
    }

    // MARK: - Scalars

    /// Text value: strings are trimmed; numbers become their decimal text; `null`, `false`, `""`, "null" are nil.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "null" { return nil }
            return trimmed
        case let number as NSNumber:
            if isBoolean(number) { return nil }
            let double = number.doubleValue
            if double.isFinite, double == double.rounded(), abs(double) < 9e15 { return String(Int64(double)) }
            return number.stringValue
        default:
            return nil
        }
    }

    /// Integer value from a number or a numeric string ("12", " 12 ", "12.0"). Booleans are not integers.
    static func int(_ value: Any?) -> Int? {
        guard let double = double(value), double.isFinite, abs(double) < 9e15 else { return nil }
        return Int(double)
    }

    /// Floating value from a number or a numeric string ("7.5", "7,5"). Booleans are not numbers.
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            if isBoolean(number) { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let direct = Double(trimmed) { return direct.isFinite ? direct : nil }
            if let comma = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { return comma.isFinite ? comma : nil }
            return nil
        default:
            return nil
        }
    }

    /// Flag value: true/false, 1/0, "1"/"0", "true"/"false", "yes"/"no". nil when absent or unreadable.
    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return isBoolean(number) ? number.boolValue : number.doubleValue != 0
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on": return true
            case "0", "false", "no", "n", "off", "": return false
            default: return double(text).map { $0 != 0 }
            }
        default:
            return nil
        }
    }

    // MARK: - Containers

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    /// Array elements; an object keyed by indexes ({"0": …, "1": …}) is read in key order; `null`/`false` are empty.
    static func array(_ value: Any?) -> [Any] {
        if let list = value as? [Any] { return list }
        if let object = value as? [String: Any] {
            return object.keys.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }.compactMap { object[$0] }
        }
        return []
    }

    /// Objects of a list (non-object elements are skipped).
    static func rows(_ value: Any?) -> [[String: Any]] {
        array(value).compactMap { $0 as? [String: Any] }
    }

    /// True for the shapes panels use to say "nothing": `null`, `false`, `""`, `[]`, `{}`.
    static func isEmptyValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return true
        case let number as NSNumber: return isBoolean(number) && !number.boolValue
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let list as [Any]: return list.isEmpty
        case let object as [String: Any]: return object.isEmpty
        default: return false
        }
    }

    // MARK: - Field pickers

    /// First non-empty text among `keys`.
    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys { if let value = string(object[key]) { return value } }
        return nil
    }

    static func firstInt(_ object: [String: Any], _ keys: [String]) -> Int? {
        for key in keys { if let value = int(object[key]) { return value } }
        return nil
    }

    /// Text values of a field that may be a string, a number, or an array of them.
    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.prefix(50).compactMap { string($0) } }
        return string(value).map { [$0] } ?? []
    }
}
