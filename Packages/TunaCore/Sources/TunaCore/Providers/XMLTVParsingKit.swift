import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Implementation behind `XMLTVParser`: a SAX (`XMLParser`) pass that keeps only the programmes the caller asked
/// for, so a 100+ MB guide never becomes a DOM. Undeclared entities (`&nbsp;` …), which would abort `XMLParser`,
/// are repaired first.
enum XMLTVParsingKit {
    static func parse(_ data: Data, channels: Set<String>?, window: DateInterval) -> [Program] {
        guard !isGzip(data) else { return [] }
        let input = repairEntities(data) ?? data
        let delegate = XMLTVDelegate(channels: channels, window: window)
        let parser = XMLParser(data: input)
        configure(parser, delegate)
        _ = parser.parse()
        return delegate.finish()
    }

    static func parse(fileURL: URL, channels: Set<String>?, window: DateInterval) -> [Program] {
        // A memory-mapped look first: gzip is not parseable, and broken entities must be repaired in memory.
        if let mapped = try? Data(contentsOf: fileURL, options: .alwaysMapped) {
            if isGzip(mapped) { return [] }
            if let repaired = repairEntities(mapped) { return parse(repaired, channels: channels, window: window) }
        }
        guard let stream = InputStream(url: fileURL) else { return [] }
        let delegate = XMLTVDelegate(channels: channels, window: window)
        let parser = XMLParser(stream: stream)
        configure(parser, delegate)
        _ = parser.parse()
        return delegate.finish()
    }

    private static func configure(_ parser: XMLParser, _ delegate: XMLTVDelegate) {
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Replaces `&` that does not start a predefined XML entity or a character reference with `&amp;`.
    /// nil when the data needs no repair (the common case, no copy made).
    static func repairEntities(_ data: Data) -> Data? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Data? in
            let count = bytes.count
            func isValidReference(at index: Int) -> Bool {
                var cursor = index + 1
                guard cursor < count else { return false }
                if bytes[cursor] == UInt8(ascii: "#") {
                    cursor += 1
                    var hex = false
                    if cursor < count && (bytes[cursor] == UInt8(ascii: "x") || bytes[cursor] == UInt8(ascii: "X")) { hex = true; cursor += 1 }
                    let digitsStart = cursor
                    while cursor < count && cursor - digitsStart < 8 {
                        let byte = bytes[cursor]
                        let isHexDigit = ProviderTextKit.isDigit(byte) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
                        guard hex ? isHexDigit : ProviderTextKit.isDigit(byte) else { break }
                        cursor += 1
                    }
                    return cursor > digitsStart && cursor < count && bytes[cursor] == UInt8(ascii: ";")
                }
                let nameStart = cursor
                while cursor < count && cursor - nameStart < 5 && ProviderTextKit.isAlphanumericASCII(bytes[cursor]) { cursor += 1 }
                guard cursor < count, bytes[cursor] == UInt8(ascii: ";") else { return false }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[nameStart..<cursor]), as: UTF8.self)
                return ["amp", "lt", "gt", "quot", "apos"].contains(name)
            }
            var firstBad: Int?
            var index = 0
            while index < count {
                if bytes[index] == UInt8(ascii: "&") && !isValidReference(at: index) { firstBad = index; break }
                index += 1
            }
            guard let firstBad else { return nil }
            var output = Data(capacity: count + 1024)
            output.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<firstBad]))
            var cursor = firstBad
            let ampersand: [UInt8] = Array("&amp;".utf8)
            while cursor < count {
                let byte = bytes[cursor]
                if byte == UInt8(ascii: "&") && !isValidReference(at: cursor) {
                    output.append(contentsOf: ampersand)
                } else {
                    output.append(byte)
                }
                cursor += 1
            }
            return output
        }
    }
}

/// SAX state for one parse. Not shared between threads.
private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    private let exact: Set<String>?
    private let folded: [String: String]
    private let window: DateInterval
    /// Programmes without `stop` get it from the next programme of the channel (bounded), see `finish`.
    private static let missingStopHorizon: TimeInterval = 12 * 3600

    private var programs: [Program] = []
    private var openEnded: Set<Int> = []

    private struct Building {
        var channelKey: String
        var start: Date
        var stop: Date?
        var title: String?
        var subtitle: String?
        var summary: String?
        var categories: [String] = []
        var icon: String?
        var episodeXMLTV: String?
        var episodeOnscreen: String?
        var isNew = false
        var isLive = false
    }

    private var current: Building?
    private var skipping = false
    private var field: String?
    private var episodeSystem: String?
    private var text = ""

    init(channels: Set<String>?, window: DateInterval) {
        self.exact = channels
        var folded: [String: String] = [:]
        for key in channels ?? [] { folded[key.lowercased()] = folded[key.lowercased()] ?? key }
        self.folded = folded
        self.window = window
    }

    private func requestedKey(for channel: String) -> String? {
        guard let exact else { return channel }
        if exact.contains(channel) { return channel }
        return folded[channel.lowercased()]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "programme" {
            current = nil
            skipping = true
            guard let channel = attributeDict["channel"]?.trimmingCharacters(in: .whitespaces), !channel.isEmpty,
                  let key = requestedKey(for: channel),
                  let start = attributeDict["start"].flatMap(ProviderTextKit.xmltvDate) else { return }
            let stop = attributeDict["stop"].flatMap(ProviderTextKit.xmltvDate)
            if let stop {
                guard stop > start, start < window.end, stop > window.start else { return }
            } else {
                guard start < window.end, start.addingTimeInterval(Self.missingStopHorizon) > window.start else { return }
            }
            current = Building(channelKey: key, start: start, stop: stop)
            skipping = false
            return
        }
        guard current != nil, !skipping else { return }
        switch elementName {
        case "title", "sub-title", "desc", "category":
            field = elementName
            text = ""
        case "episode-num":
            field = elementName
            episodeSystem = attributeDict["system"]?.lowercased()
            text = ""
        case "icon":
            if current?.icon == nil { current?.icon = ProviderTextKit.httpURLString(attributeDict["src"]) }
        case "new", "premiere":
            if elementName == "new" { current?.isNew = true }
        case "live":
            current?.isLive = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if field != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            if let building = current, !skipping { commit(building) }
            current = nil
            skipping = false
            field = nil
            return
        }
        guard current != nil, let open = field, open == elementName else { return }
        field = nil
        switch elementName {
        case "title":
            if current?.title == nil { current?.title = ProviderTextKit.line(text, max: 500) }
        case "sub-title":
            if current?.subtitle == nil { current?.subtitle = ProviderTextKit.line(text, max: 500) }
        case "desc":
            if current?.summary == nil { current?.summary = ProviderTextKit.paragraph(text, max: 4000) }
        case "category":
            if let category = ProviderTextKit.line(text, max: 100), current?.categories.contains(category) == false {
                current?.categories.append(category)
            }
        case "episode-num":
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if episodeSystem == "xmltv_ns" { current?.episodeXMLTV = value } else if episodeSystem == "onscreen" { current?.episodeOnscreen = value }
        default:
            break
        }
        text = ""
    }

    private func commit(_ building: Building) {
        guard let title = building.title ?? building.subtitle else { return }
        let end = building.stop ?? building.start.addingTimeInterval(1800)
        if building.stop == nil { openEnded.insert(programs.count) }
        programs.append(Program(
            channelKey: building.channelKey, start: building.start, end: end, title: title,
            subtitle: building.title == nil ? nil : building.subtitle, summary: building.summary,
            categories: building.categories, iconURL: building.icon,
            episodeLabel: XMLTVDelegate.episodeLabel(xmltv: building.episodeXMLTV, onscreen: building.episodeOnscreen),
            isNew: building.isNew, isLive: building.isLive || ProviderTextKit.looksLive(title)))
    }

    /// Sorted (channel, start), duplicates (same channel and start) dropped, missing `stop` filled from the next
    /// programme of the channel, programmes outside the window dropped.
    func finish() -> [Program] {
        var indexed = programs.enumerated().map { (index: $0.offset, program: $0.element) }
        indexed.sort { ($0.program.channelKey, $0.program.start, $0.index) < ($1.program.channelKey, $1.program.start, $1.index) }
        var result: [Program] = []
        result.reserveCapacity(indexed.count)
        var position = 0
        while position < indexed.count {
            var program = indexed[position].program
            if let last = result.last, last.channelKey == program.channelKey, last.start == program.start {
                position += 1
                continue
            }
            if openEnded.contains(indexed[position].index) {
                var next = position + 1
                while next < indexed.count && indexed[next].program.channelKey == program.channelKey
                        && indexed[next].program.start == program.start { next += 1 }
                if next < indexed.count, indexed[next].program.channelKey == program.channelKey,
                   indexed[next].program.start.timeIntervalSince(program.start) <= Self.missingStopHorizon {
                    program.end = indexed[next].program.start
                }
            }
            if program.start < window.end && program.end > window.start { result.append(program) }
            position += 1
        }
        return result
    }

    /// "S2 E5" from xmltv_ns ("1.4.0/1", zero-based) or an onscreen "S02E05" / free text.
    static func episodeLabel(xmltv: String?, onscreen: String?) -> String? {
        if let xmltv {
            let parts = xmltv.split(separator: ".", omittingEmptySubsequences: false).map {
                $0.split(separator: "/").first.map { Int($0.trimmingCharacters(in: .whitespaces)) } ?? nil
            }
            let season = parts.count > 0 ? parts[0].map { $0 + 1 } : nil
            let episode = parts.count > 1 ? parts[1].map { $0 + 1 } : nil
            switch (season, episode) {
            case let (season?, episode?): return "S\(season) E\(episode)"
            case let (nil, episode?): return "E\(episode)"
            case let (season?, nil): return "S\(season)"
            default: break
            }
        }
        guard let onscreen = ProviderTextKit.line(onscreen, max: 40) else { return nil }
        if let marker = ProviderTextKit.episodeMarker(in: onscreen) { return "S\(marker.season) E\(marker.episode)" }
        return onscreen
    }
}
