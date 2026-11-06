import Foundation

// MARK: - Demo content

/// Deterministic offline demo: a fake provider with ~400 messy-named items (invented titles, realistic garbage tags,
/// several languages incl. Turkish), matching metadata (invented cast/overviews/ratings, `demo://` artwork URLs),
/// a 24 h guide for the demo channels and some user state. Used by the onboarding "Try the demo" button, the
/// CI snapshot run and previews. Artwork URLs use the form "demo://poster/<seed>" / "demo://backdrop/<seed>" /
/// "demo://logo/<seed>" / "demo://person/<seed>" / "demo://channel/<seed>" — the app renders them generatively.
public enum DemoContent {
    public static let providerID: ProviderID = "demo-provider"
    public static func providerConfig() -> ProviderConfig { fatalError("TODO(library)") }
    public static func catalog(now: Date) -> ProviderCatalog { fatalError("TODO(library)") }
    /// Metadata keyed by curated Title id (call after curating `catalog`).
    public static func metadata(for library: Library) -> [String: MediaMetadata] { fatalError("TODO(library)") }
    public static func guide(for library: Library, now: Date) -> Guide { fatalError("TODO(library)") }
    public static func seriesInfo(for ref: StreamRef) -> RawSeriesInfo? { fatalError("TODO(library)") }
    public static func userState(for library: Library, now: Date) -> UserState { fatalError("TODO(library)") }
    public static func account(now: Date) -> AccountInfo { fatalError("TODO(library)") }
    public static func person(id: Int) -> PersonDetails? { fatalError("TODO(library)") }
}
