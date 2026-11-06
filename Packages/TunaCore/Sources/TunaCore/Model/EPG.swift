import Foundation

/// One programme in the TV guide.
public struct Program: Codable, Hashable, Sendable, Identifiable {
    /// The guide's channel key (XMLTV `channel` attribute / Xtream `epg_channel_id`).
    public var channelKey: String
    public var start: Date
    public var end: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    /// XMLTV categories ("Sports", "News", "Movie" ...).
    public var categories: [String]
    public var iconURL: String?
    /// "S2 E5" style, when the guide has it.
    public var episodeLabel: String?
    public var isNew: Bool
    /// True when the guide or title marks it as live ("LIVE", "Live:", "🔴").
    public var isLive: Bool
    /// True when a catch-up recording exists for it (Xtream `has_archive`).
    public var hasArchive: Bool

    public var id: String { "\(channelKey)@\(Int(start.timeIntervalSince1970))" }

    public init(channelKey: String, start: Date, end: Date, title: String, subtitle: String? = nil, summary: String? = nil,
                categories: [String] = [], iconURL: String? = nil, episodeLabel: String? = nil, isNew: Bool = false,
                isLive: Bool = false, hasArchive: Bool = false) {
        self.channelKey = channelKey
        self.start = start
        self.end = end
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.categories = categories
        self.iconURL = iconURL
        self.episodeLabel = episodeLabel
        self.isNew = isNew
        self.isLive = isLive
        self.hasArchive = hasArchive
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    /// 0...1 progress at `date` (clamped).
    public func progress(at date: Date) -> Double {
        let total = duration
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }
}
