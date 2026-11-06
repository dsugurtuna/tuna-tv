import Foundation

/// Picture quality tier parsed from names/categories (or verified from playback).
public enum Quality: Int, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case unknown = 0
    case sd = 1
    case hd = 2
    case fhd = 3
    case uhd = 4

    public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .unknown: return "—"
        case .sd: return "SD"
        case .hd: return "HD"
        case .fhd: return "Full HD"
        case .uhd: return "4K"
        }
    }

    /// Quality implied by a pixel height reported by the player/provider.
    public static func from(height: Int) -> Quality {
        if height >= 1800 { return .uhd }
        if height >= 1000 { return .fhd }
        if height >= 700 { return .hd }
        if height > 0 { return .sd }
        return .unknown
    }
}

/// Where the file came from, when the name says so.
public enum SourceTag: String, Codable, Sendable, CaseIterable, Hashable {
    case remux
    case bluray
    case webdl
    case webrip
    case hdtv
    case dvd
    case cam
    case telesync
    case screener

    /// Pirate-grade captures that should never be in the showcase.
    public var isLowGrade: Bool { self == .cam || self == .telesync || self == .screener }
    /// Disc-sourced files (shown on the Vault's "Blu-ray & Disc" shelf when not showcase-eligible).
    public var isDisc: Bool { self == .bluray || self == .remux || self == .dvd }

    public var label: String {
        switch self {
        case .remux: return "REMUX"
        case .bluray: return "Blu-ray"
        case .webdl: return "WEB-DL"
        case .webrip: return "WEBRip"
        case .hdtv: return "HDTV"
        case .dvd: return "DVD"
        case .cam: return "CAM"
        case .telesync: return "TS"
        case .screener: return "SCR"
        }
    }
}

public enum HDRFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case hdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg

    public var label: String {
        switch self {
        case .hdr: return "HDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }
}

public enum VideoCodec: String, Codable, Sendable, CaseIterable, Hashable {
    case hevc
    case h264
    case av1

    public var label: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .av1: return "AV1"
        }
    }
}

public enum AudioMarker: String, Codable, Sendable, CaseIterable, Hashable {
    case dubbed
    case subtitled
    case multiAudio
    case original

    public var label: String {
        switch self {
        case .dubbed: return "Dubbed"
        case .subtitled: return "Subtitled"
        case .multiAudio: return "Multi-audio"
        case .original: return "Original"
        }
    }
}

/// Result of parsing one messy provider name. Produced by `NameParser`.
public struct ParsedName: Codable, Hashable, Sendable {
    /// The untouched input.
    public var original: String
    /// Clean display title ("The Matrix"), episode/quality/language garbage removed.
    public var title: String
    /// Normalized dedupe key ("matrix") — see `TitleKey.make`.
    public var key: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// Episode title when the name carries one ("S01E02 - The Bridge").
    public var episodeTitle: String?
    public var quality: Quality
    public var source: SourceTag?
    public var hdr: HDRFormat?
    public var codec: VideoCodec?
    public var highFrameRate: Bool
    public var is3D: Bool
    /// ISO 639-1 codes, most specific first.
    public var languages: [String]
    /// ISO 3166-1 alpha-2 codes.
    public var countries: [String]
    /// Region codes such as "LATAM", "EXYU", "ARAB", "AFRICA", "CARIB", "NORDIC", "BALTIC".
    public var regions: [String]
    public var audio: AudioMarker?
    /// Streaming platform tag ("Netflix", "Disney+", "Exxen" ...), shown as a text chip.
    public var platform: String?
    public var isAdult: Bool
    /// "Backup", "(B)", "Alt" feeds of a live channel.
    public var isBackup: Bool
    /// "+1" style timeshift channels.
    public var timeshiftHours: Int?
    /// PPV / event channels.
    public var isEvent: Bool
    /// Every recognized tag, uppercased, in input order (for debugging and badges).
    public var tags: [String]

    public init(original: String, title: String, key: String, year: Int? = nil, season: Int? = nil,
                episode: Int? = nil, episodeTitle: String? = nil, quality: Quality = .unknown,
                source: SourceTag? = nil, hdr: HDRFormat? = nil, codec: VideoCodec? = nil,
                highFrameRate: Bool = false, is3D: Bool = false, languages: [String] = [],
                countries: [String] = [], regions: [String] = [], audio: AudioMarker? = nil,
                platform: String? = nil, isAdult: Bool = false, isBackup: Bool = false,
                timeshiftHours: Int? = nil, isEvent: Bool = false, tags: [String] = []) {
        self.original = original
        self.title = title
        self.key = key
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.quality = quality
        self.source = source
        self.hdr = hdr
        self.codec = codec
        self.highFrameRate = highFrameRate
        self.is3D = is3D
        self.languages = languages
        self.countries = countries
        self.regions = regions
        self.audio = audio
        self.platform = platform
        self.isAdult = isAdult
        self.isBackup = isBackup
        self.timeshiftHours = timeshiftHours
        self.isEvent = isEvent
        self.tags = tags
    }

    /// Short badge text for a version picker, e.g. "4K · HDR10 · HEVC · EN".
    public var badgeLine: String {
        var parts: [String] = []
        if quality != .unknown { parts.append(quality.label) }
        if let hdr { parts.append(hdr.label) }
        if let source, source != .webdl { parts.append(source.label) }
        if let codec, codec != .h264 { parts.append(codec.label) }
        if highFrameRate { parts.append("60fps") }
        if is3D { parts.append("3D") }
        if let audio, audio != .original { parts.append(audio.label) }
        if let lang = languages.first { parts.append(lang.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

/// What a provider category name tells us. Produced by `CategoryParser`.
public struct CategoryHints: Codable, Hashable, Sendable {
    /// Category name with language/quality tags removed ("Movies 2023").
    public var cleanName: String
    public var languages: [String]
    public var countries: [String]
    public var regions: [String]
    public var quality: Quality
    public var isAdult: Bool
    public var platform: String?
    /// A genre the category implies ("Action", "Kids", "Documentary" ...), if any.
    public var genre: String?
    /// Live channel category implied ("sports", "news" ...), if any. Raw values of `ChannelCategory`.
    public var channelCategory: String?

    public init(cleanName: String, languages: [String] = [], countries: [String] = [], regions: [String] = [],
                quality: Quality = .unknown, isAdult: Bool = false, platform: String? = nil,
                genre: String? = nil, channelCategory: String? = nil) {
        self.cleanName = cleanName
        self.languages = languages
        self.countries = countries
        self.regions = regions
        self.quality = quality
        self.isAdult = isAdult
        self.platform = platform
        self.genre = genre
        self.channelCategory = channelCategory
    }
}
