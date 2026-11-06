import Foundation

/// The JSON dialect of every file Tuna TV writes (`FileStore.write`, `AppStateStore`, `CacheStore` sidecars):
/// sorted keys (stable diffs, deterministic bytes), unescaped slashes (readable URLs) and ISO 8601 dates in UTC
/// with millisecond precision ("2027-01-15T08:00:00.250Z").
///
/// Decoding is tolerant about dates: ISO 8601 with or without fractional seconds, and plain numbers (Foundation's
/// default `timeIntervalSinceReferenceDate` encoding), so files written by other encoders still load.
public enum TunaJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = date(from: text) { return date }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        return decoder
    }

    /// "2027-01-15T08:00:00.250Z".
    public static func string(from date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// Parses ISO 8601 internet date-times with or without fractional seconds, "Z" or a numeric UTC offset.
    public static func date(from string: String) -> Date? {
        let text = string.tunaTrimmed
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        // Fallback for spellings the format styles reject on some platforms (e.g. "+03:00" offsets).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
