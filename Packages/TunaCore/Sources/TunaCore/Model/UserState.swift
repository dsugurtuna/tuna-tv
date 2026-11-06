import Foundation

/// Resume point for one title (movie) or one episode.
public struct WatchProgress: Codable, Hashable, Sendable {
    public var titleID: String
    public var variantID: String
    /// Set for series episodes.
    public var episodeRef: StreamRef?
    public var season: Int?
    public var episode: Int?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(titleID: String, variantID: String, episodeRef: StreamRef? = nil, season: Int? = nil, episode: Int? = nil,
                position: Double, duration: Double, updatedAt: Date = Date()) {
        self.titleID = titleID
        self.variantID = variantID
        self.episodeRef = episodeRef
        self.season = season
        self.episode = episode
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    /// Finished when 92% watched or less than 3 minutes left.
    public var isFinished: Bool { duration > 0 && (fraction >= 0.92 || duration - position < 180) }
    public var remaining: Double { max(0, duration - position) }
}

public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case title, channel }
    public var kind: Kind
    /// Title id or channel id.
    public var itemID: String
    public var watchedAt: Date
    public var secondsWatched: Double
    public var id: String { "\(kind.rawValue):\(itemID):\(Int(watchedAt.timeIntervalSince1970))" }

    public init(kind: Kind, itemID: String, watchedAt: Date = Date(), secondsWatched: Double = 0) {
        self.kind = kind
        self.itemID = itemID
        self.watchedAt = watchedAt
        self.secondsWatched = secondsWatched
    }
}

/// Everything personal: My List, progress, history, favourites, thumbs. Persisted as JSON.
public struct UserState: Codable, Hashable, Sendable {
    /// Title ids, newest first.
    public var myList: [String]
    /// Keyed by title id (movies) or episode ref id (episodes).
    public var progress: [String: WatchProgress]
    /// Newest first, capped at 500.
    public var history: [HistoryEntry]
    public var favoriteChannels: [String]
    /// Channel ids, newest first, capped at 30.
    public var recentChannels: [String]
    /// Title id -> +1 (thumbs up) / -1 (thumbs down).
    public var ratings: [String: Int]
    /// Variant id -> quality observed during playback (verifies "4K" claims).
    public var verifiedQualities: [String: Int]
    /// Variant ids that failed to play repeatedly (demoted in version order).
    public var failingVariants: [String: Int]

    public init(myList: [String] = [], progress: [String: WatchProgress] = [:], history: [HistoryEntry] = [],
                favoriteChannels: [String] = [], recentChannels: [String] = [], ratings: [String: Int] = [:],
                verifiedQualities: [String: Int] = [:], failingVariants: [String: Int] = [:]) {
        self.myList = myList
        self.progress = progress
        self.history = history
        self.favoriteChannels = favoriteChannels
        self.recentChannels = recentChannels
        self.ratings = ratings
        self.verifiedQualities = verifiedQualities
        self.failingVariants = failingVariants
    }

    public func isInMyList(_ titleID: String) -> Bool { myList.contains(titleID) }

    public mutating func toggleMyList(_ titleID: String) {
        if let index = myList.firstIndex(of: titleID) { myList.remove(at: index) } else { myList.insert(titleID, at: 0) }
    }

    public mutating func recordChannel(_ channelID: String) {
        recentChannels.removeAll { $0 == channelID }
        recentChannels.insert(channelID, at: 0)
        if recentChannels.count > 30 { recentChannels.removeLast(recentChannels.count - 30) }
    }

    public mutating func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    /// In-progress items for "Continue Watching", newest first.
    public var continueWatching: [WatchProgress] {
        progress.values.filter { !$0.isFinished && $0.position > 30 }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
