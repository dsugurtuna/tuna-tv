import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// Xtream Codes compatible panel (`player_api.php`).
    case xtream
    /// Plain M3U / M3U8 playlist URL.
    case m3u
}

/// HTTP User-Agent presets. The SAME value is sent for API calls, images on the panel host and streams,
/// because a UA that changes between requests is a classic anti-flood trigger.
public enum UserAgentPreset: Codable, Hashable, Sendable {
    case vlc
    case tivimate
    case smarters
    case kodi
    case safari
    case tunaTV
    case custom(String)

    public static let `default`: UserAgentPreset = .vlc
    public static let presets: [UserAgentPreset] = [.vlc, .tivimate, .smarters, .kodi, .safari, .tunaTV]

    public var value: String {
        switch self {
        case .vlc: return "VLC/3.0.20 LibVLC/3.0.20"
        case .tivimate: return "TiviMate/5.1.6 (Android 13)"
        case .smarters: return "IPTV Smarters Pro/4.0 (Macintosh; macOS)"
        case .kodi: return "Kodi/21.1 (Macintosh; Intel Mac OS X 10_15_7) App_Bitness/64 Version/21.1"
        case .safari: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        case .tunaTV: return "TunaTV/2.0 (Macintosh; macOS)"
        case .custom(let value): return value.isEmpty ? UserAgentPreset.vlc.value : value
        }
    }

    public var label: String {
        switch self {
        case .vlc: return "VLC (recommended)"
        case .tivimate: return "TiviMate"
        case .smarters: return "IPTV Smarters"
        case .kodi: return "Kodi"
        case .safari: return "Safari"
        case .tunaTV: return "Tuna TV"
        case .custom: return "Custom"
        }
    }
}

/// How gently Tuna TV talks to the provider's API. Exactly one request is ever in flight;
/// this only controls the minimum spacing between request starts.
public enum PacingProfile: String, Codable, Sendable, CaseIterable {
    case gentle
    case balanced
    case brisk

    /// Minimum seconds between two provider request starts (jitter is added on top).
    public var minInterval: TimeInterval {
        switch self {
        case .gentle: return 3.0
        case .balanced: return 1.5
        case .brisk: return 1.0
        }
    }

    public var label: String {
        switch self {
        case .gentle: return "Gentle (1 request / 3 s)"
        case .balanced: return "Balanced (1 request / 1.5 s)"
        case .brisk: return "Brisk (1 request / s)"
        }
    }
}

/// Container to request for live channels on Xtream panels.
public enum LiveStreamFormat: String, Codable, Sendable, CaseIterable {
    /// Prefer MPEG-TS, fall back to HLS if the account does not allow `ts`.
    case auto
    case ts
    case m3u8
}

/// A configured IPTV source. The password is NOT stored here; it lives in the keychain (`SecretStore`).
public struct ProviderConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: ProviderID
    public var name: String
    public var kind: ProviderKind
    /// Xtream: normalized base URL `scheme://host[:port][/path]` (no `player_api.php`).
    /// M3U: the playlist URL.
    public var serverURL: String
    /// Xtream username (empty for M3U).
    public var username: String
    /// Optional XMLTV guide URL that overrides the provider's own `xmltv.php`.
    public var epgURL: String?
    public var userAgent: UserAgentPreset
    public var pacing: PacingProfile
    /// User cap on simultaneous streams. The effective cap is `min(maxStreams, account.maxConnections)`.
    public var maxStreams: Int
    public var liveFormat: LiveStreamFormat
    /// Minimum time between automatic catalog syncs (seconds). Default 24 h; never below 6 h.
    public var syncInterval: TimeInterval
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: ProviderID = UUID().uuidString,
        name: String,
        kind: ProviderKind,
        serverURL: String,
        username: String = "",
        epgURL: String? = nil,
        userAgent: UserAgentPreset = .default,
        pacing: PacingProfile = .balanced,
        maxStreams: Int = 1,
        liveFormat: LiveStreamFormat = .auto,
        syncInterval: TimeInterval = 24 * 3600,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.username = username
        self.epgURL = epgURL
        self.userAgent = userAgent
        self.pacing = pacing
        self.maxStreams = max(1, maxStreams)
        self.liveFormat = liveFormat
        self.syncInterval = max(6 * 3600, syncInterval)
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Effective simultaneous stream cap for this provider.
    public func effectiveMaxStreams(account: AccountInfo?) -> Int {
        guard let limit = account?.maxConnections, limit > 0 else { return max(1, maxStreams) }
        return max(1, min(maxStreams, limit))
    }
}

/// `user_info` + `server_info` from an Xtream panel, normalized.
public struct AccountInfo: Codable, Hashable, Sendable {
    public var isAuthorized: Bool
    /// "Active", "Banned", "Disabled", "Expired" ... as reported by the panel.
    public var status: String?
    public var expiresAt: Date?
    public var createdAt: Date?
    public var isTrial: Bool
    public var activeConnections: Int?
    public var maxConnections: Int?
    public var allowedOutputFormats: [String]
    public var serverTimezone: String?
    public var serverTimeNow: Date?
    public var serverMessage: String?
    public var fetchedAt: Date

    public init(
        isAuthorized: Bool,
        status: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date? = nil,
        isTrial: Bool = false,
        activeConnections: Int? = nil,
        maxConnections: Int? = nil,
        allowedOutputFormats: [String] = [],
        serverTimezone: String? = nil,
        serverTimeNow: Date? = nil,
        serverMessage: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.isAuthorized = isAuthorized
        self.status = status
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.isTrial = isTrial
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.serverTimezone = serverTimezone
        self.serverTimeNow = serverTimeNow
        self.serverMessage = serverMessage
        self.fetchedAt = fetchedAt
    }

    /// True when the panel says the account is usable right now.
    public var isUsable: Bool {
        guard isAuthorized else { return false }
        let s = (status ?? "active").lowercased()
        if s.contains("ban") || s.contains("disab") || s.contains("expir") { return false }
        if let exp = expiresAt, exp < Date() { return false }
        return true
    }

    /// True when every allowed connection is already in use (another device is watching).
    public var isAtConnectionLimit: Bool {
        guard let active = activeConnections, let max = maxConnections, max > 0 else { return false }
        return active >= max
    }
}
