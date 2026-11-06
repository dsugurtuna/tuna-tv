import SwiftUI
import Observation
import TunaCore

// =====================================================================================================
// APP MODEL CONTRACT (owner: app-core). The single source of truth for every screen.
// Screens read it with `@Environment(AppModel.self) private var model`.
// Public (internal) signatures below are FIXED for other agents; the owner implements every body
// (replacing fatalError) and may add private helpers or extensions in App/Core/.
// =====================================================================================================

/// Where the app keeps its files.
enum AppEnvironment: Equatable {
    /// ~/Library/Application Support/TunaTV2 + Keychain.
    case live
    /// Temporary directory + in-memory secrets + demo content (CI snapshots, previews).
    case snapshot
}

enum SyncPhase: Equatable {
    case idle
    case syncing(SyncProgress)
    case failed(String)
    case upToDate(Date)
}

/// Provider row for Settings and the Provider Shield.
struct ProviderStatus: Identifiable, Equatable {
    var id: ProviderID { config.id }
    var config: ProviderConfig
    var account: AccountInfo?
    var shield: GovernorSnapshot?
    var lastSync: Date?
    var lastError: String?
}

struct ToastMessage: Identifiable, Equatable {
    enum Style: Equatable { case info, success, warning, error }
    let id = UUID()
    var text: String
    var style: Style
}

@MainActor
@Observable
final class AppModel {
    // MARK: Services
    let environment: AppEnvironment
    let router = Router()
    /// Created in `init` (needs `self`).
    private(set) var player: PlayerModel!

    // MARK: Persistent state
    private(set) var settings: AppSettings = AppSettings()
    private(set) var providers: [ProviderConfig] = []
    private(set) var userState: UserState = UserState()

    // MARK: Catalog state (rebuilt off the main thread, then swapped in)
    private(set) var library: Library = .empty
    private(set) var metadata: [String: MediaMetadata] = [:]
    private(set) var guide: Guide = .empty
    private(set) var homeRails: [Rail] = []
    private(set) var movieRails: [Rail] = []
    private(set) var seriesRails: [Rail] = []
    /// Hero carousel items (up to 6) for Home.
    private(set) var featured: [Title] = []
    private(set) var providerStatus: [ProviderStatus] = []
    private(set) var syncPhase: SyncPhase = .idle
    private(set) var isDemo = false
    /// True until cached catalogs are loaded and curated on launch.
    private(set) var isBooting = true
    private(set) var adultUnlocked = false
    var toast: ToastMessage?

    var needsOnboarding: Bool { !settings.hasCompletedOnboarding && providers.isEmpty && !isDemo }
    var hasTMDBKey: Bool { fatalError("TODO(app-core)") }
    var hasOMDbKey: Bool { fatalError("TODO(app-core)") }

    init(environment: AppEnvironment = .live) {
        self.environment = environment
        // TODO(app-core): create FileStore/CacheStore/AppStateStore/SecretStore (KeychainSecretStore for .live),
        // HostLimiter.standard(), StreamGate(), MetadataService; load settings/providers/user state; player = PlayerModel(app: self)
        self.player = PlayerModel(app: self)
    }

    /// Launch: load cached catalogs (no network) -> curate -> publish library; then, only if stale, run ONE
    /// sequential background sync per provider (one provider at a time), then the guide (once per 24 h),
    /// then metadata enrichment (visible-first). In `.snapshot` it calls `startDemo()`.
    func start() async { fatalError("TODO(app-core)") }

    /// Loads DemoContent (no network at all) so people can try the app without a provider.
    func startDemo() async { fatalError("TODO(app-core)") }
    func exitDemo() { fatalError("TODO(app-core)") }

    // MARK: Providers
    /// ONE request (account check). Does not save anything.
    func validateProvider(kind: ProviderKind, server: String, username: String, password: String) async throws -> AccountInfo { fatalError("TODO(app-core)") }
    /// Saves the provider (password to the keychain), then syncs it.
    func addProvider(_ config: ProviderConfig, password: String) async throws { fatalError("TODO(app-core)") }
    func updateProvider(_ config: ProviderConfig, password: String?) async { fatalError("TODO(app-core)") }
    func removeProvider(_ id: ProviderID) { fatalError("TODO(app-core)") }
    /// User-initiated refresh. Ignored (with a toast) within 10 minutes of the last sync unless `force`.
    func refreshCatalog(force: Bool) async { fatalError("TODO(app-core)") }
    func resetShield(for providerID: ProviderID) async { fatalError("TODO(app-core)") }

    // MARK: Settings
    /// Mutates and persists settings; re-curates the library when content preferences changed.
    func updateSettings(_ change: (inout AppSettings) -> Void) { fatalError("TODO(app-core)") }
    func completeOnboarding() { fatalError("TODO(app-core)") }
    func setMetadataKeys(tmdb: String?, omdb: String?) async { fatalError("TODO(app-core)") }

    // MARK: Lookups
    func title(_ id: String) -> Title? { library.title(id) }
    func channel(_ id: String) -> Channel? { library.channel(id) }
    func metadata(for title: Title) -> MediaMetadata? { metadata[title.id] }
    /// Detail page opened: user-initiated metadata fetch + provider details (vod/series info), cached.
    func loadDetails(for title: Title) async { fatalError("TODO(app-core)") }
    /// Cached provider details for a movie (after `loadDetails`).
    func providerInfo(for title: Title) -> RawItemInfo? { fatalError("TODO(app-core)") }
    func seriesInfo(for title: Title) async throws -> RawSeriesInfo { fatalError("TODO(app-core)") }
    func season(for title: Title, number: Int) async -> SeasonMetadata? { fatalError("TODO(app-core)") }
    func person(id: Int) async -> PersonDetails? { fatalError("TODO(app-core)") }
    func nowPlaying(on channel: Channel, at date: Date = Date()) -> Program? { fatalError("TODO(app-core)") }
    func nextProgram(on channel: Channel, at date: Date = Date()) -> Program? { fatalError("TODO(app-core)") }
    func programs(on channel: Channel, in interval: DateInterval) -> [Program] { fatalError("TODO(app-core)") }
    func liveEvents(at date: Date = Date()) -> [(channel: Channel, program: Program)] { fatalError("TODO(app-core)") }
    func search(_ query: String, scope: TitleKind? = nil) -> [SearchHit] { fatalError("TODO(app-core)") }
    func similar(to title: Title) -> [Title] { fatalError("TODO(app-core)") }
    func titles(for person: PersonDetails) -> [Title] { fatalError("TODO(app-core)") }
    func grid(_ kind: TitleKind?, filter: BrowseFilter) -> [Title] { fatalError("TODO(app-core)") }
    func genres(_ kind: TitleKind) -> [(genre: String, count: Int)] { fatalError("TODO(app-core)") }
    func insights() -> InsightsReport { fatalError("TODO(app-core)") }
    /// Visible-first background enrichment (cards call this from .onAppear in batches; dedupe inside).
    func requestMetadata(for titles: [Title]) { fatalError("TODO(app-core)") }

    // MARK: User state
    func progress(for title: Title) -> WatchProgress? { fatalError("TODO(app-core)") }
    func progress(forEpisode ref: StreamRef) -> WatchProgress? { fatalError("TODO(app-core)") }
    var continueWatching: [(title: Title, progress: WatchProgress)] { fatalError("TODO(app-core)") }
    var myList: [Title] { fatalError("TODO(app-core)") }
    func isInMyList(_ title: Title) -> Bool { userState.isInMyList(title.id) }
    func toggleMyList(_ title: Title) { fatalError("TODO(app-core)") }
    var favoriteChannels: [Channel] { fatalError("TODO(app-core)") }
    var recentChannels: [Channel] { fatalError("TODO(app-core)") }
    func isFavorite(_ channel: Channel) -> Bool { userState.favoriteChannels.contains(channel.id) }
    func toggleFavorite(_ channel: Channel) { fatalError("TODO(app-core)") }
    func rating(for title: Title) -> Int { userState.ratings[title.id] ?? 0 }
    func rate(_ title: Title, _ value: Int) { fatalError("TODO(app-core)") }
    /// Called by PlayerModel (throttled to every ~10 s and on stop).
    func recordProgress(_ progress: WatchProgress) { fatalError("TODO(app-core)") }
    func recordWatched(channel: Channel, seconds: Double) { fatalError("TODO(app-core)") }
    func recordVerifiedQuality(_ quality: Quality, variantID: String) { fatalError("TODO(app-core)") }
    func recordFailure(variantID: String) { fatalError("TODO(app-core)") }

    // MARK: Playback (thin wrappers over `player`)
    func play(_ title: Title, variant: Variant? = nil, resume: Bool = true) { fatalError("TODO(app-core)") }
    func play(episode: RawEpisode, of title: Title, variant: Variant? = nil) { fatalError("TODO(app-core)") }
    func play(_ channel: Channel, variant: Variant? = nil) { fatalError("TODO(app-core)") }
    func playCatchup(_ program: Program, on channel: Channel) { fatalError("TODO(app-core)") }
    func session(for providerID: ProviderID) -> ProviderSession? { fatalError("TODO(app-core)") }
    var streamGate: StreamGate { fatalError("TODO(app-core)") }
    var hostLimiter: HostLimiter { fatalError("TODO(app-core)") }

    // MARK: Adult content
    func unlockAdult(pin: String) -> Bool { fatalError("TODO(app-core)") }
    func setAdultPIN(_ pin: String?) { fatalError("TODO(app-core)") }

    func showToast(_ text: String, style: ToastMessage.Style = .info) {
        toast = ToastMessage(text: text, style: style)
    }
}
