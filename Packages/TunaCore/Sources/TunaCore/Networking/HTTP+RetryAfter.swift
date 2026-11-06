import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension HTTPResponse {
    /// How long the server asked us to wait, measured from `now`: `Retry-After` as delta-seconds or as an
    /// HTTP-date (RFC 9110 IMF-fixdate, plus the obsolete RFC 850 and asctime forms). nil when absent or invalid;
    /// a date in the past yields 0.
    public func retryAfterDelay(now: Date) -> TimeInterval? {
        guard let raw = header("Retry-After")?.tunaTrimmed, !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        guard let date = HTTPDate.parse(raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Parser for HTTP-date header values.
private enum HTTPDate {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
        "EEEE, dd-MMM-yy HH:mm:ss zzz", // RFC 850:     Sunday, 06-Nov-94 08:49:37 GMT
        "EEE MMM d HH:mm:ss yyyy", // asctime:     Sun Nov  6 08:49:37 1994
    ]

    static func parse(_ value: String) -> Date? {
        let text = value.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.calendar = Calendar(identifier: .gregorian)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
