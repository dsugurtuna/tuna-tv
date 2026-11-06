import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Internal helpers of the metadata module. Everything lives inside this namespace so nothing clashes with
/// internals of other TunaCore areas (there is deliberately no dependency on `Util/Similarity.swift`).
enum MetadataSupport {
    static let logCategory = "metadata"

    // MARK: - HTTP

    /// Sends every metadata request through the shared `HostLimiter` (never straight to the network).
    struct Fetcher: Sendable {
        let http: HTTPClient
        let limiter: HostLimiter

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let http = self.http
            do {
                return try await limiter.run(host: request.hostKey) { try await http.send(request) }
            } catch let error as TunaError {
                throw error
            } catch is CancellationError {
                throw TunaError.cancelled
            } catch {
                // Never echo URLs: TMDB v3 keys and OMDb keys travel as query items.
                throw TunaError.network(TunaLog.shared.redact(error.localizedDescription))
            }
        }
    }

    /// RFC 3986 unreserved characters plus ",", the only ones left unescaped in query names and values.
    static let queryAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,")
        return set
    }()

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    /// `base + path + ?name=value&...` with strict escaping (so "+", "&", "[]" in values are always encoded).
    static func makeURL(_ base: String, path: String, query: [(String, String)]) -> URL? {
        var text = base + path
        if !query.isEmpty {
            text += "?" + query.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
        }
        return URL(string: text)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let text = String(describing: error)
            throw TunaError.decoding("\(context): \(text.count > 240 ? String(text.prefix(240)) + "…" : text)")
        }
    }

    // MARK: - Tolerant decoding

    /// An array that drops elements failing to decode instead of failing as a whole. A non-array value
    /// decodes as an empty list.
    struct Lossy<Element: Decodable>: Decodable {
        var values: [Element]

        init(_ values: [Element]) { self.values = values }

        init(from decoder: Decoder) throws {
            values = ((try? [Attempt](from: decoder)) ?? []).compactMap { $0.value }
        }

        private struct Attempt: Decodable {
            let value: Element?
            init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ string: String) {
            stringValue = string
            intValue = nil
        }

        init?(stringValue: String) { self.init(stringValue) }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    /// Reads a loosely typed JSON object: wrong types become nil/empty instead of failing the decode.
    struct LooseObject {
        let container: KeyedDecodingContainer<AnyKey>

        init(_ decoder: Decoder) throws { container = try decoder.container(keyedBy: AnyKey.self) }

        func string(_ key: String) -> String? {
            let codingKey = AnyKey(key)
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) { return value.nonEmpty }
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) { return String(value) }
            return nil
        }

        /// A JSON array of strings, or one string with `;` separators (the iptv-org CSV convention).
        func strings(_ key: String) -> [String] {
            let codingKey = AnyKey(key)
            if let list = try? container.decodeIfPresent([String?].self, forKey: codingKey) {
                return list.compactMap { $0?.nonEmpty }
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                return value.split(separator: ";").compactMap { String($0).nonEmpty }
            }
            return []
        }

        func bool(_ key: String) -> Bool? {
            let codingKey = AnyKey(key)
            if let value = try? container.decodeIfPresent(Bool.self, forKey: codingKey) { return value }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                switch value.tunaTrimmed.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: return nil
                }
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) { return value != 0 }
            return nil
        }

        func int(_ key: String) -> Int? {
            let codingKey = AnyKey(key)
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) { return value }
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return value.isFinite && abs(value) < 1e15 ? Int(value) : nil
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey) { return Int(value.tunaTrimmed) }
            return nil
        }

        func double(_ key: String) -> Double? {
            let codingKey = AnyKey(key)
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) { return value.isFinite ? value : nil }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey), let number = Double(value.tunaTrimmed) {
                return number.isFinite ? number : nil
            }
            return nil
        }

        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil
        }
    }

    // MARK: - Concurrency

    /// Async semaphore with two lanes: waiting `.userInitiated` work is always resumed before `.background` work.
    actor Gate {
        private let limit: Int
        private var active = 0
        private var urgent: [CheckedContinuation<Void, Never>] = []
        private var normal: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = max(1, limit) }

        func run<T: Sendable>(_ priority: RequestPriority, _ operation: @Sendable () async throws -> T) async throws -> T {
            await acquire(priority)
            defer { release() }
            return try await operation()
        }

        private func acquire(_ priority: RequestPriority) async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if priority == .userInitiated { urgent.append(continuation) } else { normal.append(continuation) }
            }
        }

        private func release() {
            if !urgent.isEmpty {
                urgent.removeFirst().resume()
            } else if !normal.isEmpty {
                normal.removeFirst().resume()
            } else {
                active = max(0, active - 1)
            }
        }
    }

    // MARK: - Values

    static func year(from date: String?) -> Int? {
        guard let date = date?.tunaTrimmed, date.count >= 4, let year = Int(date.prefix(4)), (1870...2200).contains(year) else {
            return nil
        }
        return year
    }

    static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// FNV-1a 64-bit. Stable across launches and platforms (unlike `hashValue`).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Text

    /// Plain text from the small HTML fragments TVMaze uses for summaries.
    static func stripHTML(_ html: String) -> String {
        var output = ""
        var tag = ""
        var inTag = false
        for character in html {
            if inTag {
                if character == ">" {
                    inTag = false
                    let name = tag.lowercased().trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("br") {
                        output.append("\n")
                    } else if name == "/p" || name == "/div" || name.hasPrefix("p ") || name == "p" || name == "/li" {
                        output.append("\n\n")
                    }
                    tag = ""
                } else {
                    tag.append(character)
                }
            } else if character == "<" {
                inTag = true
            } else {
                output.append(character)
            }
        }
        let decoded = decodeEntities(output)
        var lines: [String] = []
        var blank = false
        for rawLine in decoded.components(separatedBy: "\n") {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
            if line.isEmpty {
                if !lines.isEmpty && !blank { lines.append("") }
                blank = true
            } else {
                lines.append(line)
                blank = false
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
                                       "rdquo": "”", "ldquo": "“"]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index)..<semicolon])
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map { $0.value } }

    /// Jaro-Winkler similarity (0...1), prefix scale 0.1, prefix length up to 4.
    static func jaroWinkler(_ a: [UInt32], _ b: [UInt32]) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let window = max(0, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in 0..<a.count {
            let low = max(0, i - window)
            let high = min(b.count - 1, i + window)
            guard low <= high else { continue }
            for j in low...high where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0
        var k = 0
        for i in 0..<a.count where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) {
            guard a[i] == b[i] else { break }
            prefix += 1
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    static func levenshtein(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
