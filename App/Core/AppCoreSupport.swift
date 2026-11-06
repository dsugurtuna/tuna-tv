import Foundation
import CryptoKit
import TunaCore

// Pure helpers for AppModel (owner: app-core). Top-level and nonisolated on purpose: they run inside
// `Task.detached` (curation, rails, search) and never touch main-actor state.

enum CorePaths {
    /// ~/Library/Application Support/TunaTV2
    static func applicationSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("TunaTV2", isDirectory: true)
    }
}

enum CoreHash {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum CoreLocale {
    private static let fallbackRegions: [String: String] = [
        "en": "US", "tr": "TR", "de": "DE", "es": "ES", "fr": "FR", "it": "IT", "pt": "BR", "nl": "NL",
        "pl": "PL", "ru": "RU", "ar": "SA", "el": "GR", "sv": "SE", "da": "DK", "no": "NO", "nb": "NO",
        "fi": "FI", "ja": "JP", "ko": "KR", "zh": "CN", "hi": "IN", "he": "IL", "ro": "RO", "hu": "HU",
        "cs": "CZ", "sr": "RS", "hr": "HR", "bg": "BG", "uk": "UA", "fa": "IR", "ur": "PK", "th": "TH",
        "vi": "VN", "id": "ID", "ms": "MY", "sq": "AL", "bs": "BA", "mk": "MK", "sl": "SI", "sk": "SK",
    ]

    /// TMDB `language` for the user's worlds: primary language + a matching world country ("tr-TR").
    static func metadataLanguage(for worlds: WorldSelection) -> String {
        let language = (worlds.languages.first ?? "en").lowercased()
        let matching = worlds.countries.first { code in
            WorldDirectory.country(code)?.languages.first?.lowercased() == language
        }
        let region = matching ?? fallbackRegions[language] ?? worlds.countries.first ?? "US"
        return "\(language)-\(region.uppercased())"
    }
}

enum CoreHosts {
    /// Host keys of a provider panel: "host" and, with an explicit port, "host:port".
    static func keys(for config: ProviderConfig) -> [String] {
        guard let url = URL(string: config.serverURL), let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        if let port = url.port { return [host, "\(host):\(port)"] }
        return [host]
    }

    static func displayName(for config: ProviderConfig) -> String {
        URL(string: config.serverURL)?.host ?? "My Provider"
    }

    /// Registers every credential-like value with the log redactor.
    static func registerSecrets(for config: ProviderConfig, password: String) {
        TunaLog.shared.registerSecret(password)
        TunaLog.shared.registerSecret(config.username)
        guard let components = URLComponents(string: config.serverURL) else { return }
        let names: Set<String> = ["username", "password", "token", "key", "auth", "user", "pass"]
        for item in components.queryItems ?? [] where names.contains(item.name.lowercased()) {
            if let value = item.value { TunaLog.shared.registerSecret(value) }
        }
    }

    /// Xtream: normalized panel URL. M3U: trimmed playlist URL with a scheme.
    static func normalizedServer(kind: ProviderKind, input: String) throws -> String {
        let trimmed = input.tunaTrimmed
        guard !trimmed.isEmpty else { throw TunaError.invalidInput("Enter your provider's server address.") }
        switch kind {
        case .xtream:
            guard let normalized = XtreamURLBuilder.normalizeServer(trimmed) else {
                throw TunaError.invalidInput("That server address doesn't look right. It usually looks like http://example.com:8080")
            }
            return normalized
        case .m3u:
            var candidate = trimmed
            let lower = candidate.lowercased()
            if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { candidate = "http://" + candidate }
            guard let url = URL(string: candidate), url.host?.isEmpty == false else {
                throw TunaError.invalidInput("That playlist link doesn't look right.")
            }
            return candidate
        }
    }
}

enum CoreErrors {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let tuna = error as? TunaError, tuna == .cancelled { return true }
        return false
    }

    static func message(for error: Error) -> String {
        if let tuna = error as? TunaError { return tuna.userMessage }
        if error is CancellationError { return TunaError.cancelled.userMessage }
        return error.localizedDescription
    }
}

/// iptv-org artwork and ids for a curated channel (preferred over panel-hosted logos).
struct CoreChannelArt: Sendable, Hashable {
    var logoURL: String?
    var iptvOrgID: String?
    var categories: [ChannelCategory]

    static func apply(_ art: CoreChannelArt?, to channel: Channel) -> Channel {
        guard let art else { return channel }
        var copy = channel
        if let logo = art.logoURL { copy.logoURL = logo }
        if copy.iptvOrgID == nil { copy.iptvOrgID = art.iptvOrgID }
        let vague = copy.categories.isEmpty || copy.categories == [.general] || copy.categories == [.other]
        if vague && !art.categories.isEmpty { copy.categories = art.categories }
        return copy
    }

    static func build(channels: [Channel], matcher: ChannelMatcher, providerHosts: Set<String>) -> [String: CoreChannelArt] {
        var result: [String: CoreChannelArt] = [:]
        for channel in channels {
            guard let match = matcher.match(name: channel.name, countries: channel.countries, epgID: channel.epgChannelID) else { continue }
            let logoHost = channel.logoURL.flatMap { URL(string: $0)?.host?.lowercased() }
            let wantsLogo = logoHost.map { providerHosts.contains($0) } ?? true
            let logo = wantsLogo ? match.logoURL : nil
            let categories = match.categories.compactMap { ChannelCategory(rawValue: $0.lowercased()) }
            if logo == nil && channel.iptvOrgID != nil && categories.isEmpty { continue }
            result[channel.id] = CoreChannelArt(logoURL: logo, iptvOrgID: match.id, categories: categories)
        }
        return result
    }
}

struct CoreCurationInput: Sendable {
    var catalogs: [ProviderCatalog]
    var preferences: ContentPreferences
    var verifiedQualities: [String: Int] = [:]
    var failingVariants: [String: Int] = [:]
    var channelArt: [String: CoreChannelArt] = [:]
}

enum CoreCuration {
    static func library(from input: CoreCurationInput) -> Library {
        guard !input.catalogs.isEmpty else { return Library.empty }
        var curated = Curator(preferences: input.preferences)
            .curate(input.catalogs, verifiedQualities: input.verifiedQualities, failingVariants: input.failingVariants)
        if !input.channelArt.isEmpty {
            curated.channels = curated.channels.map { CoreChannelArt.apply(input.channelArt[$0.id], to: $0) }
        }
        return Library(catalog: curated)
    }

    /// Same library with iptv-org art patched into its channels.
    static func applying(_ art: [String: CoreChannelArt], to library: Library) -> Library {
        guard !art.isEmpty else { return library }
        let channels = library.channels.map { CoreChannelArt.apply(art[$0.id], to: $0) }
        let catalog = CuratedCatalog(movies: library.movies, series: library.series, channels: channels, stats: library.stats)
        return Library(catalog: catalog, generatedAt: library.generatedAt)
    }
}

/// Rails for Home / Movies / Series plus the hero titles, built off the main thread.
struct CoreRails: Sendable {
    var home: [Rail]
    var movies: [Rail]
    var series: [Rail]
    var featured: [Title]

    static func build(_ context: RailContext) -> CoreRails {
        let home = RailComposer.home(context)
        return CoreRails(home: home,
                         movies: RailComposer.browse(.movie, context),
                         series: RailComposer.browse(.series, context),
                         featured: featured(from: home, library: context.library))
    }

    static func title(of item: RailItem) -> Title? {
        switch item {
        case .title(let title): return title
        case .progress(let title, _): return title
        default: return nil
        }
    }

    static func featured(from rails: [Rail], library: Library) -> [Title] {
        if let hero = rails.first(where: { $0.style == .hero }) {
            let titles = hero.items.compactMap(title(of:))
            if !titles.isEmpty { return Array(titles.prefix(6)) }
        }
        let fallback = library.showcase(.movie).prefix(4) + library.showcase(.series).prefix(2)
        return Array(fallback.prefix(6))
    }
}

/// Everything the demo needs, built off the main thread. No network.
struct CoreDemoBundle: Sendable {
    var catalog: ProviderCatalog
    var library: Library
    var metadata: [String: MediaMetadata]
    var guide: Guide
    var userState: UserState
    var status: ProviderStatus

    static func make(preferences: ContentPreferences, now: Date) -> CoreDemoBundle {
        let catalog = DemoContent.catalog(now: now)
        let library = Library(catalog: Curator(preferences: preferences).curate([catalog]))
        let config = DemoContent.providerConfig()
        let status = ProviderStatus(config: config, account: DemoContent.account(now: now),
                                    shield: demoShield(providerID: config.id, now: now),
                                    lastSync: now.addingTimeInterval(-3 * 3600), lastError: nil)
        return CoreDemoBundle(catalog: catalog, library: library,
                              metadata: DemoContent.metadata(for: library),
                              guide: DemoContent.guide(for: library, now: now),
                              userState: DemoContent.userState(for: library, now: now),
                              status: status)
    }

    /// A calm, realistic Provider Shield for the demo (one gentle sync, 7 requests).
    static func demoShield(providerID: ProviderID, now: Date) -> GovernorSnapshot {
        let steps: [(String, String, Int)] = [
            ("account", "player_api.php", 180), ("live_categories", "get_live_categories", 240),
            ("vod_categories", "get_vod_categories", 210), ("series_categories", "get_series_categories", 190),
            ("live_streams", "get_live_streams", 1450), ("vod_streams", "get_vod_streams", 2310),
            ("series", "get_series", 1720),
        ]
        let start = now.addingTimeInterval(-3 * 3600)
        let log = steps.enumerated().map { index, step in
            RequestLogEntry(id: index, date: start.addingTimeInterval(Double(index) * 2.1), purpose: step.0,
                            summary: step.1, status: 200, durationMs: step.2, priority: .background, outcome: "ok")
        }
        return GovernorSnapshot(providerID: providerID, breaker: .closed, requestsToday: steps.count,
                                dailySoftBudget: 400, lastRequestAt: log.last?.date, nextAllowedAt: nil,
                                recent: Array(log.reversed()))
    }
}

/// The real state kept aside while the demo is shown.
struct CoreDemoStash {
    var library: Library
    var metadata: [String: MediaMetadata]
    var guide: Guide
    var userState: UserState
    var providerStatus: [ProviderStatus]
    var syncPhase: SyncPhase
}

struct CoreGridKey: Hashable {
    var kind: TitleKind?
    var filter: BrowseFilter
}

struct CoreProgressSample {
    var position: Double
    var at: Date
}

enum CoreHistory {
    /// Adds watch time to the newest history entry when it is the same item (within 6 h), else records a new one.
    static func add(seconds: Double, kind: HistoryEntry.Kind, itemID: String, at date: Date, to state: inout UserState) {
        if let first = state.history.first, first.kind == kind, first.itemID == itemID,
           date.timeIntervalSince(first.watchedAt) < 6 * 3600 {
            state.history[0].secondsWatched += seconds
        } else {
            state.record(HistoryEntry(kind: kind, itemID: itemID, watchedAt: date, secondsWatched: seconds))
        }
    }
}

enum CoreEpisodePicker {
    /// In-progress episode, else the one after the last finished episode, else S1E1.
    static func pick(_ episodes: [RawEpisode], progress: [WatchProgress], resume: Bool) -> RawEpisode? {
        let ordered = episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard !ordered.isEmpty else { return nil }
        let firstRegular = ordered.first(where: { $0.season >= 1 }) ?? ordered[0]
        guard resume, let latest = progress.max(by: { $0.updatedAt < $1.updatedAt }),
              let index = ordered.firstIndex(where: { $0.ref == latest.episodeRef }) else { return firstRegular }
        if !latest.isFinished { return ordered[index] }
        return index + 1 < ordered.count ? ordered[index + 1] : firstRegular
    }
}

extension MetadataStore {
    /// Metadata for several title ids in one actor hop.
    func metadata(forIDs ids: [String]) -> [String: MediaMetadata] {
        var result: [String: MediaMetadata] = [:]
        for id in ids { if let value = metadata(for: id) { result[id] = value } }
        return result
    }
}
