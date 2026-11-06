import Foundation

/// Credential-free one-line descriptions of provider URLs, for the request log and diagnostics.
///
/// The summary keeps the path and the Xtream `action` only ("/player_api.php?action=get_vod_info"):
/// - no scheme, host or port, and no query item other than `action`;
/// - every path segment equal to the value of a `username` / `password` (or `user` / `pass` / `pwd` / `token`)
///   query item is replaced by `RequestRedaction.mask`;
/// - the two segments after `live|movie|series|timeshift` in Xtream stream paths (`/live/<user>/<pass>/1.ts`)
///   are masked even when the URL has no query;
/// - finally every secret registered with `TunaLog.shared.registerSecret` is masked as well.
public enum RequestRedaction {
    public static let mask = "•••"

    static let credentialNames: Set<String> = ["username", "password", "user", "pass", "pwd", "passwd", "token"]
    static let xtreamStreamRoots: Set<String> = ["live", "movie", "series", "timeshift"]

    /// Redacted "path + action" summary of `url`; non-GET methods are prefixed ("POST /player_api.php").
    public static func summary(for url: URL, method: String = "GET") -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var secrets: Set<String> = []
        var action: String?
        for item in components?.queryItems ?? [] {
            let name = item.name.lowercased()
            guard let value = item.value, !value.isEmpty else { continue }
            if credentialNames.contains(name) { secrets.insert(value) }
            if name == "action", action == nil { action = value }
        }

        let encodedPath = components?.percentEncodedPath ?? url.path
        let rawSegments = encodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var segments = rawSegments.map { $0.removingPercentEncoding ?? $0 }
        for index in segments.indices where secrets.contains(segments[index]) || secrets.contains(rawSegments[index]) {
            segments[index] = mask
        }
        if let root = segments.firstIndex(where: { xtreamStreamRoots.contains($0.lowercased()) }), segments.count - root >= 4 {
            segments[root + 1] = mask
            segments[root + 2] = mask
        }

        var summary = "/" + segments.joined(separator: "/")
        if let action { summary += "?action=" + (secrets.contains(action) ? mask : action) }
        summary = TunaLog.shared.redact(summary)
        let verb = method.uppercased()
        return verb == "GET" || verb.isEmpty ? summary : "\(verb) \(summary)"
    }
}
