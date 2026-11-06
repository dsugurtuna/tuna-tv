import Foundation

/// The user's "worlds": which languages and countries their main experience is about.
/// Default: English. Adding Turkey brings Turkish content (and Turkish dubs) into the showcase.
public struct WorldSelection: Codable, Hashable, Sendable {
    /// ISO 639-1 codes in preference order. The first one is the primary audio language.
    public var languages: [String]
    /// ISO 3166-1 alpha-2 codes.
    public var countries: [String]

    public init(languages: [String] = ["en"], countries: [String] = ["US", "GB", "CA", "AU", "IE", "NZ"]) {
        self.languages = languages.isEmpty ? ["en"] : languages.map { $0.lowercased() }
        self.countries = countries.map { $0.uppercased() }
    }

    public static let english = WorldSelection()

    public func includes(language: String) -> Bool { languages.contains(language.lowercased()) }
    public func includes(country: String) -> Bool { countries.contains(country.uppercased()) }

    /// Adds a country and its primary language, e.g. `adding(country: "TR", language: "tr")`.
    public func adding(country: String, language: String?) -> WorldSelection {
        var copy = self
        if !copy.countries.contains(country.uppercased()) { copy.countries.append(country.uppercased()) }
        if let language, !copy.languages.contains(language.lowercased()) { copy.languages.append(language.lowercased()) }
        return copy
    }
}

/// What qualifies for the showcase. Everything else goes to The Vault.
public enum ShowcaseQuality: String, Codable, Sendable, CaseIterable {
    /// 4K / UHD only (default).
    case ultraOnly
    /// Full HD and better.
    case fullHDPlus
    /// No quality filter (language/world filtering still applies).
    case everything

    public var minimum: Quality {
        switch self {
        case .ultraOnly: return .uhd
        case .fullHDPlus: return .fhd
        case .everything: return .unknown
        }
    }

    public var label: String {
        switch self {
        case .ultraOnly: return "4K only"
        case .fullHDPlus: return "Full HD and up"
        case .everything: return "Everything"
        }
    }
}

public struct ContentPreferences: Codable, Hashable, Sendable {
    public var worlds: WorldSelection
    public var showcaseQuality: ShowcaseQuality
    /// When a section would be nearly empty at the chosen quality, let the next tier in (and tell the user).
    public var autoRelaxShowcase: Bool
    /// Below this many showcase titles per kind, auto-relax kicks in.
    public var relaxThreshold: Int
    public var hideAdult: Bool
    /// SHA-256 hex of the adult PIN (nil = no PIN set).
    public var adultPINHash: String?
    public var preferredAudioLanguages: [String]
    public var preferredSubtitleLanguages: [String]
    /// Show CAM/screener copies at all (in the Vault).
    public var showLowQuality: Bool

    public init(worlds: WorldSelection = .english, showcaseQuality: ShowcaseQuality = .ultraOnly,
                autoRelaxShowcase: Bool = true, relaxThreshold: Int = 40, hideAdult: Bool = true,
                adultPINHash: String? = nil, preferredAudioLanguages: [String] = ["en"],
                preferredSubtitleLanguages: [String] = [], showLowQuality: Bool = true) {
        self.worlds = worlds
        self.showcaseQuality = showcaseQuality
        self.autoRelaxShowcase = autoRelaxShowcase
        self.relaxThreshold = relaxThreshold
        self.hideAdult = hideAdult
        self.adultPINHash = adultPINHash
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.showLowQuality = showLowQuality
    }
}

public struct PlaybackPreferences: Codable, Hashable, Sendable {
    /// Seconds a channel selection must be stable before a stream opens (zapping debounce).
    public var zapDebounce: TimeInterval
    public var autoplayNextEpisode: Bool
    public var upNextCountdown: Int
    public var liveTimeshiftMinutes: Int
    /// Muted trailer in the home hero after a few idle seconds (trailers come from YouTube, never the provider).
    public var heroTrailers: Bool
    public var resumeThresholdSeconds: Double

    public init(zapDebounce: TimeInterval = 0.6, autoplayNextEpisode: Bool = true, upNextCountdown: Int = 10,
                liveTimeshiftMinutes: Int = 30, heroTrailers: Bool = true, resumeThresholdSeconds: Double = 60) {
        self.zapDebounce = zapDebounce
        self.autoplayNextEpisode = autoplayNextEpisode
        self.upNextCountdown = upNextCountdown
        self.liveTimeshiftMinutes = liveTimeshiftMinutes
        self.heroTrailers = heroTrailers
        self.resumeThresholdSeconds = resumeThresholdSeconds
    }
}

/// Everything the user can set, persisted as one JSON document.
public struct AppSettings: Codable, Hashable, Sendable {
    public var content: ContentPreferences
    public var playback: PlaybackPreferences
    public var hasCompletedOnboarding: Bool
    /// Whether the app may look up metadata on TMDB/TVMaze/OMDb/iptv-org (never the IPTV provider in bulk).
    public var onlineMetadata: Bool
    public var reduceMotion: Bool

    public init(content: ContentPreferences = ContentPreferences(), playback: PlaybackPreferences = PlaybackPreferences(),
                hasCompletedOnboarding: Bool = false, onlineMetadata: Bool = true, reduceMotion: Bool = false) {
        self.content = content
        self.playback = playback
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.onlineMetadata = onlineMetadata
        self.reduceMotion = reduceMotion
    }
}
