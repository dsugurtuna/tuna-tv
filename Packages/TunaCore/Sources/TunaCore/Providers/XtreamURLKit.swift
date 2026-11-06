import Foundation

/// Implementation behind `XtreamURLBuilder` (pure string/URL work, no I/O). Adapted from IPTVMac's `XtreamURLs`
/// (GPL-3.0): users paste whatever their provider showed them, so the server is normalized and credentials are
/// percent-encoded with the unreserved set.
enum XtreamURLKit {
    /// Endpoint tails stripped from a pasted server address (one of them, case-insensitive).
    private static let endpointTails = ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"]

    /// RFC 3986 unreserved characters: everything else in a credential or path segment is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Credentials are trimmed: a space or newline pasted along with them would make a correct login fail.
    static func credential(_ value: String) -> String {
        encode(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Normalization

    static func normalizeServer(_ input: String) -> String? {
        guard var components = components(from: input) else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.percentEncodedPath
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        while path.hasSuffix("/") { path.removeLast() }
        let lower = path.lowercased()
        for tail in endpointTails where lower.hasSuffix(tail) {
            path = String(path.dropLast(tail.count))
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard var result = components.string else { return nil }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Components of an http(s) address; "http://" is added when no scheme was typed. nil without a host.
    private static func components(from input: String) -> URLComponents? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if let range = text.range(of: "://") {
            let scheme = text[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            text = scheme + text[range.lowerBound...]
        } else {
            if text.hasPrefix("//") { text.removeFirst(2) }
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        if !host.contains(":") && !host.contains("[") && host != host.lowercased() { components.host = host.lowercased() }
        return components
    }

    // MARK: - Full links

    static func parseFullLink(_ input: String) -> (server: String, username: String, password: String)? {
        guard let components = components(from: input), let server = normalizeServer(input) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            var name = item.name.lowercased()
            if name.hasPrefix("amp;") { name.removeFirst(4) }   // "&amp;" copied out of a web page
            if values[name] == nil, let value = item.value { values[name] = value }
        }
        if let username = values["username"]?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            let password = (values["password"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (server, username, password)
        }
        return streamPathCredentials(components)
    }

    /// "http://host:8080[/sub]/live/<user>/<pass>/<id>.ts" (also /movie/, /series/, /timeshift/) -> credentials.
    private static func streamPathCredentials(_ components: URLComponents) -> (server: String, username: String, password: String)? {
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = segments.lastIndex(where: { ["live", "movie", "series", "timeshift"].contains($0.lowercased()) }),
              segments.count >= index + 4 else { return nil }
        guard let username = segments[index + 1].removingPercentEncoding, let password = segments[index + 2].removingPercentEncoding,
              !username.isEmpty else { return nil }
        var base = components
        base.query = nil
        base.fragment = nil
        base.user = nil
        base.password = nil
        base.percentEncodedPath = segments[..<index].isEmpty ? "" : "/" + segments[..<index].joined(separator: "/")
        guard let server = base.string.flatMap(normalizeServer) else { return nil }
        return (server, username, password)
    }

    // MARK: - Building

    static func apiURL(server: String, username: String, password: String, action: String?, params: [String: String]) -> URL? {
        guard let base = normalizeServer(server) else { return nil }
        var query = "username=\(credential(username))&password=\(credential(password))"
        if let action, !action.isEmpty { query += "&action=\(encode(action))" }
        for (key, value) in params.sorted(by: { $0.key < $1.key }) { query += "&\(encode(key))=\(encode(value))" }
        return URL(string: "\(base)/player_api.php?\(query)")
    }

    static func xmltvURL(server: String, username: String, password: String) -> URL? {
        guard let base = normalizeServer(server) else { return nil }
        return URL(string: "\(base)/xmltv.php?username=\(credential(username))&password=\(credential(password))")
    }

    /// Credential-free panel guide address (for display / `ProviderCatalog.guideURL`; never fetched as is).
    static func publicXMLTVAddress(server: String) -> String? {
        normalizeServer(server).map { "\($0)/xmltv.php" }
    }

    /// `{base}/{kind}/{user}/{pass}/{id}.{ext}`.
    static func streamURL(kind: String, server: String, username: String, password: String, id: String, ext: String?,
                          defaultExt: String) -> URL? {
        guard let base = normalizeServer(server) else { return nil }
        let streamID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamID.isEmpty else { return nil }
        let fileExt = cleanExtension(ext) ?? defaultExt
        return URL(string: "\(base)/\(kind)/\(credential(username))/\(credential(password))/\(encode(streamID)).\(fileExt)")
    }

    /// "mkv", ".MKV" -> "mkv"; anything that is not a short alphanumeric token -> nil.
    static func cleanExtension(_ raw: String?) -> String? {
        guard var ext = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard !ext.isEmpty, ext.utf8.count <= 8, ext.utf8.allSatisfy(ProviderTextKit.isAlphanumericASCII) else { return nil }
        return ext
    }

    static func catchupURL(server: String, username: String, password: String, streamID: String, start: Date,
                           durationMinutes: Int, serverTimeZone: TimeZone) -> URL? {
        guard let base = normalizeServer(server) else { return nil }
        let id = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let stamp = timeshiftStamp(start, timeZone: serverTimeZone)
        let minutes = max(1, durationMinutes)
        return URL(string: "\(base)/timeshift/\(credential(username))/\(credential(password))/\(minutes)/\(stamp)/\(encode(id)).ts")
    }

    /// "yyyy-MM-dd:HH-mm" wall-clock time of `date` in `timeZone` (Gregorian, independent of the user's locale).
    static func timeshiftStamp(_ date: Date, timeZone: TimeZone) -> String {
        let local = Int((date.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: date))).rounded(.down))
        let days = Int((Double(local) / 86_400).rounded(.down))
        let secondsOfDay = local - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)):\(pad(secondsOfDay / 3600, 2))-\(pad((secondsOfDay % 3600) / 60, 2))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// Inverse of `ProviderTextKit.daysFromCivil` (H. Hinnant's algorithm).
    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
