import Foundation
import TunaCore

/// Display strings and artwork for a title, merging TMDB/TVMaze metadata over the provider's own data.
struct TitleDisplay {
    let title: Title
    let metadata: MediaMetadata?

    init(_ title: Title, _ metadata: MediaMetadata?) {
        self.title = title
        self.metadata = metadata
    }

    var name: String { metadata?.title.nonEmpty ?? title.name }
    var posterURL: String? { metadata?.posterURL ?? title.posterURL }
    var backdropURL: String? { metadata?.backdropURL ?? metadata?.backdrops.first ?? title.backdropURL }
    var logoURL: String? { metadata?.logoURL }
    var overview: String? { metadata?.overview?.nonEmpty ?? title.plot?.nonEmpty }
    var year: Int? { title.year ?? metadata?.year }
    var genres: [String] { metadata.map { $0.genres }.flatMap { $0.isEmpty ? nil : $0 } ?? title.genres }
    var tmdbRating: Double? {
        guard let value = metadata?.voteAverage, value > 0 else { return nil }
        return value
    }
    var imdbRating: Double? {
        guard let value = metadata?.imdbRating, value > 0 else { return nil }
        return value
    }
    var providerRating: Double? {
        guard let value = title.providerRating, value > 0 else { return nil }
        return value
    }
    var hdr: HDRFormat? { title.hdr ?? title.defaultVariant?.parsed.hdr }

    /// "2023 · Drama, Thriller · 2 h 14 min · PG-13" / "2019 · 3 Seasons".
    var metaLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        let shownGenres = genres.prefix(2)
        if !shownGenres.isEmpty { parts.append(shownGenres.joined(separator: ", ")) }
        if title.kind == .movie, let minutes = metadata?.runtimeMinutes, minutes > 0 {
            parts.append(TitleDisplay.runtime(minutes: minutes))
        }
        if title.kind == .series, let seasons = metadata?.seasonCount, seasons > 0 {
            parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
        }
        if let certification = metadata?.certification?.nonEmpty { parts.append(certification) }
        return parts.joined(separator: "  ·  ")
    }

    /// Year + first genre for small card captions.
    var caption: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let genre = genres.first { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    static func runtime(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 { return rest > 0 ? "\(hours) h \(rest) min" : "\(hours) h" }
        return "\(rest) min"
    }
}

enum TVFormat {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// "12 min left" / "1 h 4 min left".
    static func remaining(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return TitleDisplay.runtime(minutes: minutes) + " left"
    }

    static func episodeCode(season: Int?, episode: Int?) -> String? {
        guard let season, let episode else { return nil }
        return "S\(season) · E\(episode)"
    }
}
