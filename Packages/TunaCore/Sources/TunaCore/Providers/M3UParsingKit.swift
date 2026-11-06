import Foundation

/// Implementation behind `M3UParser`. Adapted from IPTVMac's `M3U.swift` (GPL-3.0) and extended with the edge cases
/// seen in iptvnator / Hypnotix: BOM, CRLF/CR, quote-aware attributes (commas and apostrophes inside values),
/// unquoted and single-quoted values, `#EXTGRP`, `#EXTVLCOPT` / `#KODIPROP` / `#EXTHTTP` / `url|Header=…` request
/// headers, `url-tvg` / `x-tvg-url` guide links, CP1252 lines. A linear byte scanner (no regex), so very long lines
/// cost linear time. URLs without a preceding `#EXTINF` are ignored.
enum M3UParsingKit {
    // MARK: - Parsing

    static func parse(_ data: Data) -> M3UPlaylist {
        var state = ParseState()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let count = bytes.count
            var start = 0
            if count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { start = 3 }
            var index = start
            while index < count {
                let byte = bytes[index]
                if byte == 0x0A || byte == 0x0D {
                    if index > start { state.handle(decodeLine(UnsafeRawBufferPointer(rebasing: bytes[start..<index]))) }
                    start = index + 1
                }
                index += 1
            }
            if count > start { state.handle(decodeLine(UnsafeRawBufferPointer(rebasing: bytes[start..<count]))) }
        }
        return M3UPlaylist(entries: state.entries, guideURLs: state.guideURLs)
    }

    /// True when the body is a playlist (starts with `#EXTM3U` after BOM/whitespace, or has an `#EXTINF` early on).
    static func looksLikePlaylist(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(65_536), as: UTF8.self)
        let trimmed = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        return trimmed.uppercased().hasPrefix("#EXTM3U") || head.uppercased().contains("#EXTINF")
    }

    /// UTF-8, falling back to Windows-1252 for lines that are not valid UTF-8 (older Windows-made playlists).
    private static func decodeLine(_ bytes: UnsafeRawBufferPointer) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.contains("\u{FFFD}"), String(bytes: bytes, encoding: .utf8) == nil,
           let legacy = String(bytes: bytes, encoding: .windowsCP1252) {
            return legacy
        }
        return text
    }

    private struct PendingInfo {
        var duration: Int
        var attributes: [String: String]
        var name: String
    }

    /// Request options collected since the previous URL line; they apply to the next entry.
    private struct PendingOptions {
        var group: String?
        var userAgent: String?
        var referrer: String?
        var extra: [String: String] = [:]
    }

    private struct ParseState {
        var entries: [M3UEntry] = []
        var guideURLs: [String] = []
        var pending: PendingInfo?
        var options = PendingOptions()

        mutating func handle(_ rawLine: String) {
            var line = Substring(rawLine)
            while let first = line.first, first == "\u{FEFF}" || first == " " || first == "\t" { line.removeFirst() }
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            guard !line.isEmpty else { return }
            if line.first == "#" { directive(String(line)); return }
            url(String(line))
        }

        private mutating func directive(_ line: String) {
            let head = line.prefix(12).uppercased()
            if head.hasPrefix("#EXTINF:") {
                pending = M3UParsingKit.parseExtinf(Array(line.utf8.dropFirst(8)))
            } else if head.hasPrefix("#EXTM3U") {
                let attributes = M3UParsingKit.parseAttributes(Array(line.utf8.dropFirst(7))[...])
                for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                    for link in M3UParsingKit.guideLinks(attributes[key]) where !guideURLs.contains(link) { guideURLs.append(link) }
                }
            } else if head.hasPrefix("#EXTGRP:") {
                options.group = ProviderTextKit.line(String(line.dropFirst(8)), max: 300)
            } else if head.hasPrefix("#EXTVLCOPT:") {
                let (key, value) = M3UParsingKit.keyValue(String(line.dropFirst(11)))
                switch key {
                case "http-user-agent": options.userAgent = value
                case "http-referrer", "http-referer": options.referrer = value
                default: break
                }
            } else if head.hasPrefix("#KODIPROP:") {
                let (key, value) = M3UParsingKit.keyValue(String(line.dropFirst(10)))
                guard !key.isEmpty, let value else { return }
                options.extra["kodiprop:" + key] = value
                if key.hasSuffix("stream_headers") || key.hasSuffix("common_headers") || key.hasSuffix("manifest_headers") {
                    applyHeaders(M3UParsingKit.headerList(value))
                }
            } else if head.hasPrefix("#EXTHTTP:") {
                let json = Data(line.dropFirst(9).utf8)
                if let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
                    var headers: [String: String] = [:]
                    for (key, value) in object { if let text = value as? String { headers[key.lowercased()] = text } }
                    applyHeaders(headers)
                }
            }
        }

        private mutating func applyHeaders(_ headers: [String: String]) {
            if options.userAgent == nil, let agent = headers["user-agent"]?.nonEmpty { options.userAgent = agent }
            if options.referrer == nil, let referrer = (headers["referer"] ?? headers["referrer"])?.nonEmpty { options.referrer = referrer }
        }

        private mutating func url(_ line: String) {
            defer { pending = nil; options = PendingOptions() }
            guard let info = pending else { return }     // a URL without #EXTINF is ignored
            var location = line
            if let bar = location.firstIndex(of: "|") {
                let suffix = String(location[location.index(after: bar)...])
                if suffix.contains("=") {
                    applyHeaders(M3UParsingKit.headerList(suffix))
                    location = String(location[..<bar]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard location.contains("://") else { return }
            var attributes = info.attributes
            for (key, value) in options.extra where attributes[key] == nil { attributes[key] = value }
            if options.userAgent == nil, let agent = attributes["user-agent"] ?? attributes["http-user-agent"] { options.userAgent = agent }
            if options.referrer == nil, let referrer = attributes["referer"] ?? attributes["referrer"] ?? attributes["http-referrer"] {
                options.referrer = referrer
            }
            let name = ProviderTextKit.line(info.name, max: 500)
                ?? ProviderTextKit.line(attributes["tvg-name"], max: 500)
                ?? M3UParsingKit.fallbackName(location)
            let group = ProviderTextKit.line(attributes["group-title"], max: 300) ?? options.group
            entries.append(M3UEntry(name: name, url: location, attributes: attributes, groupTitle: group, duration: info.duration,
                                    userAgent: ProviderTextKit.line(options.userAgent, max: 500),
                                    referrer: ProviderTextKit.line(options.referrer, max: 2048)))
        }
    }

    /// `#EXTINF:<duration> key="value" …,<name>` (bytes after the colon).
    private static func parseExtinf(_ body: [UInt8]) -> PendingInfo {
        let count = body.count
        var durationEnd = 0
        while durationEnd < count && body[durationEnd] != Byte.space && body[durationEnd] != Byte.tab && body[durationEnd] != Byte.comma {
            durationEnd += 1
        }
        let durationText = String(decoding: body[0..<durationEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let duration = Double(durationText).flatMap { $0.isFinite && abs($0) < 1e9 ? Int($0) : nil } ?? -1

        // The name starts after the first comma outside quotes; with unbalanced quotes fall back to the last comma.
        var inDouble = false
        var inSingle = false
        var comma: Int?
        var index = durationEnd
        while index < count {
            let byte = body[index]
            if byte == Byte.quote && !inSingle {
                inDouble.toggle()
            } else if byte == Byte.apostrophe && !inDouble && (inSingle || (index > 0 && body[index - 1] == Byte.equals)) {
                inSingle.toggle()
            } else if byte == Byte.comma && !inDouble && !inSingle {
                comma = index
                break
            }
            index += 1
        }
        if comma == nil, let last = body.lastIndex(of: Byte.comma), last >= durationEnd { comma = last }
        let headEnd = comma ?? count
        let attributes = parseAttributes(durationEnd < headEnd ? body[durationEnd..<headEnd] : [])
        let name = comma.map { String(decoding: body[($0 + 1)..<count], as: UTF8.self) } ?? ""
        return PendingInfo(duration: duration, attributes: attributes, name: name.trimmingCharacters(in: .whitespaces))
    }

    /// `key="value"`, `key='value'` and `key=value` pairs. Keys are lowercased; the first occurrence wins; empty
    /// values are dropped.
    static func parseAttributes(_ bytes: ArraySlice<UInt8>) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = bytes.startIndex
        let end = bytes.endIndex
        func isSpace(_ byte: UInt8) -> Bool { byte == Byte.space || byte == Byte.tab }
        while index < end {
            while index < end && isSpace(bytes[index]) { index += 1 }
            let keyStart = index
            while index < end && !isSpace(bytes[index]) && bytes[index] != Byte.equals && bytes[index] != Byte.quote
                    && bytes[index] != Byte.apostrophe {
                index += 1
            }
            let key = String(decoding: bytes[keyStart..<index], as: UTF8.self).lowercased()
            guard index < end, bytes[index] == Byte.equals else {
                if index == keyStart { index += 1 }   // stray quote: skip it
                continue
            }
            index += 1
            var value: String
            if index < end && (bytes[index] == Byte.quote || bytes[index] == Byte.apostrophe) {
                let quote = bytes[index]
                index += 1
                let valueStart = index
                while index < end && bytes[index] != quote { index += 1 }
                value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                if index < end { index += 1 }
            } else {
                let valueStart = index
                while index < end && !isSpace(bytes[index]) { index += 1 }
                value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !value.isEmpty && attributes[key] == nil { attributes[key] = value }
        }
        return attributes
    }

    /// `key=value` of `#EXTVLCOPT:` / `#KODIPROP:` (key lowercased, value unquoted).
    private static func keyValue(_ text: String) -> (key: String, value: String?) {
        guard let equals = text.firstIndex(of: "=") else { return (text.trimmingCharacters(in: .whitespaces).lowercased(), nil) }
        let key = text[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        var value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value.isEmpty ? nil : value)
    }

    /// "User-Agent=Mozilla%2F5.0&Referer=https%3A%2F%2Fexample.com" (Kodi header lists, also after `url|`).
    private static func headerList(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for pair in text.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let value = raw.removingPercentEncoding ?? raw
            if !key.isEmpty && !value.isEmpty { headers[key] = value }
        }
        return headers
    }

    private static func guideLinks(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .compactMap { ProviderTextKit.httpURLString(String($0)) }
    }

    /// Never the URL itself (it carries the account's credentials): its last path component, or a neutral label.
    static func fallbackName(_ url: String) -> String {
        let withoutQuery = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let last = withoutQuery.split(separator: "/").last.map(String.init) ?? ""
        let decoded = last.removingPercentEncoding ?? last
        if decoded.isEmpty || decoded.contains("://") || withoutQuery.hasSuffix("://" + last) { return "Untitled" }
        return ProviderTextKit.line(decoded, max: 200) ?? "Untitled"
    }

    private enum Byte {
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let comma = UInt8(ascii: ",")
        static let quote = UInt8(ascii: "\"")
        static let apostrophe = UInt8(ascii: "'")
        static let equals = UInt8(ascii: "=")
    }

    // MARK: - Classification

    /// Result of turning a playlist into a catalog, plus what the session needs to resolve refs without network.
    struct Classification: Sendable {
        var catalog: ProviderCatalog
        /// Every playable entry (live, movie, episode) by stream id.
        var entries: [String: M3UEntry]
        /// Episodes of each M3U series record (keyed by the series stream id), sorted by season and episode.
        var episodes: [String: [RawEpisode]]
    }

    /// Schemes a playlist may hand the player. `file:`, `edl:`, `fd:` … are never accepted from an untrusted list.
    static let playableSchemes: Set<String> = ["http", "https", "rtmp", "rtmps", "rtmpe", "rtmpt", "rtsp", "rtsps", "udp", "rtp",
                                               "mms", "mmsh", "srt"]
    private static let vodExtensions: Set<String> = ["mkv", "mp4", "avi", "m4v", "mov", "wmv", "mpg", "mpeg"]

    static func isPlayable(_ url: String) -> Bool {
        guard let range = url.range(of: "://") else { return false }
        let scheme = url[..<range.lowerBound].lowercased()
        return playableSchemes.contains(scheme) && url[range.upperBound...].contains(where: { $0 != "/" })
    }

    static func classify(_ playlist: M3UPlaylist, providerID: ProviderID) -> Classification {
        var items: [RawItem] = []
        var categories: [RawCategory] = []
        var categoryKeys = Set<String>()
        var entries: [String: M3UEntry] = [:]
        var seenURLs = Set<String>()
        var seriesIndex: [String: Int] = [:]
        var episodes: [String: [RawEpisode]] = [:]

        func addCategory(_ group: String?, _ kind: StreamKind) {
            guard let group, categoryKeys.insert("\(kind.rawValue)|\(group)").inserted else { return }
            categories.append(RawCategory(id: group, name: group, kind: kind))
        }

        for entry in playlist.entries {
            guard isPlayable(entry.url), seenURLs.insert(entry.url).inserted else { continue }
            let streamID = fnv1a64Hex(entry.url)
            let path = lowercasedPath(entry.url)
            let ext = pathExtension(path)
            let marker = ProviderTextKit.episodeMarker(in: entry.name)
            let group = entry.groupTitle
            let attributes = entry.attributes
            let logo = ProviderTextKit.httpURLString(attributes["tvg-logo"] ?? attributes["logo"])
            entries[streamID] = entry

            if path.contains("/movie/") || (marker == nil && !path.contains("/series/")
                                            && (ext.map(vodExtensions.contains) == true || hasVODToken(group))) {
                addCategory(group, .movie)
                items.append(RawItem(
                    ref: StreamRef(providerID: providerID, kind: .movie, streamID: streamID), name: entry.name,
                    categoryID: group, categoryName: group, iconURL: logo,
                    containerExtension: XtreamURLKit.cleanExtension(ext), directURL: entry.url,
                    tvgCountry: attributes["tvg-country"], tvgLanguage: attributes["tvg-language"],
                    userAgentOverride: entry.userAgent, referrerOverride: entry.referrer))
            } else if path.contains("/series/") || marker != nil {
                let show = marker.flatMap { $0.show.isEmpty ? nil : $0.show } ?? (marker == nil ? entry.name : group ?? entry.name)
                let key = show.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let seriesID = fnv1a64Hex("series|" + key)
                if seriesIndex[key] == nil {
                    seriesIndex[key] = items.count
                    addCategory(group, .series)
                    items.append(RawItem(
                        ref: StreamRef(providerID: providerID, kind: .series, streamID: seriesID), name: show,
                        categoryID: group, categoryName: group, iconURL: logo,
                        tvgCountry: attributes["tvg-country"], tvgLanguage: attributes["tvg-language"],
                        userAgentOverride: entry.userAgent, referrerOverride: entry.referrer))
                } else if let index = seriesIndex[key], items[index].iconURL == nil {
                    items[index].iconURL = logo
                }
                let number = marker?.episode ?? ((episodes[seriesID]?.count ?? 0) + 1)
                episodes[seriesID, default: []].append(RawEpisode(
                    ref: StreamRef(providerID: providerID, kind: .episode, streamID: streamID),
                    season: marker?.season ?? 1, episode: number,
                    title: marker?.title ?? "Episode \(number)",
                    containerExtension: XtreamURLKit.cleanExtension(ext),
                    durationSeconds: entry.duration > 0 ? entry.duration : nil,
                    stillURL: logo))
            } else {
                addCategory(group, .live)
                items.append(RawItem(
                    ref: StreamRef(providerID: providerID, kind: .live, streamID: streamID), name: entry.name,
                    categoryID: group, categoryName: group, iconURL: logo, directURL: entry.url,
                    channelNumber: attributes["tvg-chno"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                    epgChannelID: ProviderTextKit.line(attributes["tvg-id"], max: 200),
                    catchupDays: catchupDays(attributes),
                    tvgCountry: attributes["tvg-country"], tvgLanguage: attributes["tvg-language"],
                    userAgentOverride: entry.userAgent, referrerOverride: entry.referrer))
            }
        }
        for key in episodes.keys {
            episodes[key]?.sort { ($0.season, $0.episode, $0.title) < ($1.season, $1.episode, $1.title) }
        }
        let catalog = ProviderCatalog(providerID: providerID, categories: categories, items: items, guideURL: playlist.guideURLs.first)
        return Classification(catalog: catalog, entries: entries, episodes: episodes)
    }

    private static func hasVODToken(_ group: String?) -> Bool {
        guard let group else { return false }
        return group.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("vod")
    }

    /// Lowercased path of a URL string (no scheme, host, query or fragment).
    private static func lowercasedPath(_ url: String) -> String {
        var rest = Substring(url.lowercased())
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        var path = rest[slash...]
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<cut] }
        return String(path)
    }

    private static func pathExtension(_ path: String) -> String? {
        guard let last = path.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return nil }
        let ext = last[last.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return String(ext)
    }

    /// Catch-up days from `catchup-days`, `timeshift` or `tvg-rec`.
    static func catchupDays(_ attributes: [String: String]) -> Int? {
        for key in ["catchup-days", "timeshift", "tvg-rec"] {
            if let days = attributes[key].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), days > 0 { return min(days, 365) }
        }
        return nil
    }

    /// FNV-1a 64-bit hash, 16 lowercase hex digits: a stable id for an M3U entry (its URL) across launches.
    private static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    // MARK: - Catch-up (M3U `catchup*` attributes)

    /// Catch-up URL for an M3U channel: `catchup-source` templates (`{utc}`, `${start}`, `{utcend}`, `{lutc}`,
    /// `{duration[:N]}`, `{offset[:N]}`, `{Y}{m}{d}{H}{M}{S}`; relative sources are appended), `shift` (the default:
    /// `?utc=&lutc=`), `flussonic` and `xc`. nil when the channel has no archive.
    static func catchupURL(for entry: M3UEntry, start: Date, end: Date, now: Date) -> URL? {
        let attributes = entry.attributes
        let type = (attributes["catchup"] ?? attributes["catchup-type"] ?? "").lowercased()
        let source = attributes["catchup-source"]?.trimmingCharacters(in: .whitespaces)
        guard catchupDays(attributes) != nil || source?.isEmpty == false || !type.isEmpty else { return nil }
        let utc = Int(start.timeIntervalSince1970)
        let utcEnd = max(utc + 60, Int(end.timeIntervalSince1970))
        let lutc = Int(now.timeIntervalSince1970)

        if let source, !source.isEmpty {
            let expanded = substitute(source, utc: utc, utcEnd: utcEnd, lutc: lutc)
            let lower = expanded.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                guard expanded == source else { return URL(string: expanded) }
                return withQuery(expanded, utc: utc, lutc: lutc)    // a source without placeholders: iptvnator style
            }
            return URL(string: entry.url + expanded)
        }
        switch type {
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            return flussonic(entry.url, utc: utc, duration: utcEnd - utc)
        case "xc":
            return xtreamStyle(entry.url, start: start, minutes: (utcEnd - utc + 59) / 60)
        default:
            return withQuery(entry.url, utc: utc, lutc: lutc)
        }
    }

    private static func withQuery(_ url: String, utc: Int, lutc: Int) -> URL? {
        guard var components = URLComponents(string: url) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "utc" && $0.name != "lutc" }
        items.append(URLQueryItem(name: "utc", value: String(utc)))
        items.append(URLQueryItem(name: "lutc", value: String(lutc)))
        components.queryItems = items
        return components.url
    }

    private static func substitute(_ template: String, utc: Int, utcEnd: Int, lutc: Int) -> String {
        let duration = utcEnd - utc
        let offset = max(0, lutc - utc)
        let days = Int((Double(utc) / 86_400).rounded(.down))
        let (year, month, day) = XtreamURLKit.civil(fromDays: days)
        let secondsOfDay = utc - days * 86_400
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        var text = template
        let simple: [(String, String)] = [
            ("${start}", "\(utc)"), ("{utc}", "\(utc)"), ("{start}", "\(utc)"), ("${timestamp}", "\(lutc)"), ("{timestamp}", "\(lutc)"),
            ("${end}", "\(utcEnd)"), ("{utcend}", "\(utcEnd)"), ("{end}", "\(utcEnd)"), ("${now}", "\(lutc)"), ("{lutc}", "\(lutc)"),
            ("{now}", "\(lutc)"), ("${duration}", "\(duration)"), ("{duration}", "\(duration)"), ("${offset}", "\(offset)"),
            ("{offset}", "\(offset)"), ("{Y}", "\(year)"), ("{m}", two(month)), ("{d}", two(day)),
            ("{H}", two(secondsOfDay / 3600)), ("{M}", two((secondsOfDay % 3600) / 60)), ("{S}", two(secondsOfDay % 60)),
        ]
        for (placeholder, value) in simple where text.contains(placeholder) {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        // {duration:60} / {offset:1}: the value divided by N.
        for (name, value) in [("duration", duration), ("offset", offset)] {
            while let range = text.range(of: "{\(name):") {
                guard let close = text[range.upperBound...].firstIndex(of: "}") else { break }
                let divisor = Int(text[range.upperBound..<close]) ?? 1
                text.replaceSubrange(range.lowerBound...close, with: "\(value / max(1, divisor))")
            }
        }
        return text
    }

    private static func flussonic(_ url: String, utc: Int, duration: Int) -> URL? {
        guard var components = URLComponents(string: url) else { return nil }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = segments.last, !last.isEmpty else { return nil }
        if last.lowercased() == "mpegts" {
            segments[segments.count - 1] = "timeshift_abs-\(utc).ts"
        } else if last.lowercased().hasSuffix(".m3u8") {
            segments[segments.count - 1] = "\(last.dropLast(5))-\(utc)-\(duration).m3u8"
        } else {
            return nil
        }
        components.percentEncodedPath = segments.joined(separator: "/")
        return components.url
    }

    /// `http://host:port/[live/]user/pass/id[.ext]` -> `/timeshift/user/pass/<min>/<Y-m-d:H-M>/id.ts` (UTC).
    private static func xtreamStyle(_ url: String, start: Date, minutes: Int) -> URL? {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.first?.lowercased() == "live" { segments.removeFirst() }
        guard segments.count >= 3 else { return nil }
        let id = segments[segments.count - 1].split(separator: ".").first.map(String.init) ?? segments[segments.count - 1]
        let server = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        return XtreamURLKit.catchupURL(server: server, username: segments[segments.count - 3], password: segments[segments.count - 2],
                                       streamID: id, start: start, durationMinutes: minutes,
                                       serverTimeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }
}
