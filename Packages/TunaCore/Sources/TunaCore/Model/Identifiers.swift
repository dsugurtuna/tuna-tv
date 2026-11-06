import Foundation

/// Stable identifier of a configured provider (a UUID string).
public typealias ProviderID = String

/// What a provider record is.
public enum StreamKind: String, Codable, Sendable, CaseIterable, Hashable {
    case live
    case movie
    case series
    case episode
}

/// Whether a curated title is a film or a show.
public enum TitleKind: String, Codable, Sendable, CaseIterable, Hashable {
    case movie
    case series

    public var streamKind: StreamKind { self == .movie ? .movie : .series }
}

/// A pointer to exactly one record on one provider (a live channel, a movie, a series or an episode).
public struct StreamRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var providerID: ProviderID
    public var kind: StreamKind
    /// The provider's own id (Xtream `stream_id` / `series_id` / episode `id`, or a hash for M3U entries).
    public var streamID: String

    public init(providerID: ProviderID, kind: StreamKind, streamID: String) {
        self.providerID = providerID
        self.kind = kind
        self.streamID = streamID
    }

    /// Globally unique, stable string form: `providerID|kind|streamID`.
    public var id: String { "\(providerID)|\(kind.rawValue)|\(streamID)" }
    public var description: String { id }
}
