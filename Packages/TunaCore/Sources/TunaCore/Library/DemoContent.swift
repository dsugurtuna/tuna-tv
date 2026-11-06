import Foundation

// MARK: - Demo content

/// Deterministic offline demo: a fake provider with ~400 messy-named items (invented titles, realistic garbage tags,
/// several languages incl. Turkish), matching metadata (invented cast/overviews/ratings, `demo://` artwork URLs),
/// a 24 h guide for the demo channels and some user state. Used by the onboarding "Try the demo" button, the
/// CI snapshot run and previews. Artwork URLs use the form "demo://poster/<seed>" / "demo://backdrop/<seed>" /
/// "demo://logo/<seed>" / "demo://person/<seed>" / "demo://channel/<seed>" — the app renders them generatively.
///
/// Everything is invented and fully deterministic: the same inputs always produce identical output (seeded
/// SplitMix64 generators, no system clock, locale or time zone). The tables live in `Demo*.swift` files.
public enum DemoContent {
    public static let providerID: ProviderID = "demo-provider"

    public static func providerConfig() -> ProviderConfig {
        ProviderConfig(id: providerID, name: "Tuna Demo", kind: .xtream, serverURL: "demo://tuna", username: "demo",
                       epgURL: nil, userAgent: .tunaTV, pacing: .balanced, maxStreams: 1, liveFormat: .auto,
                       syncInterval: 24 * 3_600, isEnabled: true, createdAt: DemoClock.reference)
    }

    public static func catalog(now: Date) -> ProviderCatalog { DemoCatalogBuilder.catalog(now: now) }

    /// Metadata keyed by curated Title id (call after curating `catalog`).
    public static func metadata(for library: Library) -> [String: MediaMetadata] {
        DemoMetadataBuilder.metadata(for: library.movies + library.series)
    }

    /// Programmes from `now - 6 h` to `now + 30 h` for every demo EPG id (and any other channel in the library).
    public static func guide(for library: Library, now: Date) -> Guide {
        let extra = library.channels.compactMap(\.epgChannelID)
        return Guide(programs: DemoGuideBuilder.programs(now: now, extraKeys: extra))
    }

    public static func seriesInfo(for ref: StreamRef) -> RawSeriesInfo? { DemoSeriesInfoBuilder.info(for: ref) }

    public static func userState(for library: Library, now: Date) -> UserState {
        DemoUserStateBuilder.userState(movies: library.movies, series: library.series, channels: library.channels, now: now)
    }

    public static func account(now: Date) -> AccountInfo {
        AccountInfo(isAuthorized: true, status: "Active", expiresAt: now.addingTimeInterval(180 * 86_400),
                    createdAt: now.addingTimeInterval(-400 * 86_400), isTrial: false, activeConnections: 0, maxConnections: 1,
                    allowedOutputFormats: ["m3u8", "ts"], serverTimezone: "UTC", serverTimeNow: now,
                    serverMessage: "Welcome to the Tuna TV demo. Everything here is invented.", fetchedAt: now)
    }

    public static func person(id: Int) -> PersonDetails? { DemoMetadataBuilder.person(id: id) }
}
