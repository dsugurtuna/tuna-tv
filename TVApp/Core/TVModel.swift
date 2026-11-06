import SwiftUI
import UIKit
import Observation
import TunaCore

// =====================================================================================================
// TV MODEL: the single source of truth for every Apple TV screen (a port of the Mac app's AppModel; the
// orchestration and provider-safety logic are kept identical). Screens read it with
// `@Environment(TVModel.self) private var model`.
//
// Provider safety rules implemented here:
// - Multi-request provider work (catalog syncs, XMLTV guide) runs in ONE serial job queue: one provider at a
//   time, never in parallel, and every request still goes through that provider's RequestGovernor.
// - Launch is cache-first (no network); a sync only happens when the session says it is stale, or when the
//   user asks (and not within 10 minutes of the last one). Failures are never retried automatically.
// - Detail pages make at most one user-initiated provider request (vod_info / series_info, cached by the session).
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
final class TVModel {
    // MARK: Services
    let environment: AppEnvironment
    /// Bumped when every tab's navigation stack should return to its root (demo on/off).
    private(set) var navigationResetToken = 0
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
    var hasTMDBKey: Bool { tmdbKeySaved }
    var hasOMDbKey: Bool { omdbKeySaved }

    // MARK: Private services
    private let files: FileStore
    private let cacheFiles: FileStore
    private let cache: CacheStore
    private let stateStore: AppStateStore
    private let secrets: SecretStore
    private let limiter: HostLimiter
    private let gate: StreamGate
    private let metadataStore: MetadataStore
    private let metadataService: MetadataService
    /// Serial queue for JSON writes (settings, providers, user state): ordered and off the main thread.
    private let writeQueue = DispatchQueue(label: "io.github.dsugurtuna.tunatv.state-writes", qos: .utility)

    // MARK: Private observed state
    private var tmdbKeySaved = false
    private var omdbKeySaved = false
    private var providerDetails: [String: RawItemInfo] = [:]
    private var searchIndexVersion = 0

    // MARK: Private bookkeeping (not observed)
    @ObservationIgnored private var sessions: [ProviderID: ProviderSession] = [:]
    @ObservationIgnored private var catalogs: [ProviderID: ProviderCatalog] = [:]
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var preemptHandlerInstalled = false
    // Provider job queue
    @ObservationIgnored private var providerQueueTail: Task<Void, Never>?
    @ObservationIgnored private var providerJobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var syncJobQueued = false
    @ObservationIgnored private var guideJobQueued = false
    @ObservationIgnored private var forcedSyncIDs: Set<ProviderID> = []
    @ObservationIgnored private var activeProviderWork: ProviderID?
    @ObservationIgnored private var lastSuccessfulSync: [ProviderID: Date] = [:]
    @ObservationIgnored private var syncErrors: [ProviderID: Error] = [:]
    @ObservationIgnored private var lastGuideFetch: [ProviderID: Date] = [:]
    @ObservationIgnored private var deferredSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pipelineTimerTask: Task<Void, Never>?
    @ObservationIgnored private var statusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastShieldRefresh = Date.distantPast
    @ObservationIgnored private var lastRefreshSucceeded = false
    // Curation / rails
    @ObservationIgnored private var curationGeneration = 0
    @ObservationIgnored private var libraryGeneration = 0
    @ObservationIgnored private var railGeneration = 0
    @ObservationIgnored private var lastRailBuild = Date.distantPast
    @ObservationIgnored private var railRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var railsStaleWhilePlaying = false
    @ObservationIgnored private var featuredGeneration = -1
    @ObservationIgnored private var featuredNeedsUpgrade = false
    @ObservationIgnored private var recurateTask: Task<Void, Never>?
    @ObservationIgnored private var deferredCurationTask: Task<Void, Never>?
    @ObservationIgnored private var deferredCurationPending = false
    // Metadata
    @ObservationIgnored private var metadataPipelineStarted = false
    @ObservationIgnored private var enrichmentTask: Task<Void, Never>?
    @ObservationIgnored private var metadataUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTrickleTask: Task<Void, Never>?
    @ObservationIgnored private var metadataRequestTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMetadataIDs: Set<String> = []
    @ObservationIgnored private var requestedMetadataIDs: Set<String> = []
    @ObservationIgnored private var pendingMetadataRequests: [Title] = []
    @ObservationIgnored private var trendingMovieIDs: [Int] = []
    @ObservationIgnored private var trendingSeriesIDs: [Int] = []
    @ObservationIgnored private var channelArt: [String: CoreChannelArt] = [:]
    @ObservationIgnored private var didEnrichChannels = false
    @ObservationIgnored private var seriesInfoCache: [String: RawSeriesInfo] = [:]
    @ObservationIgnored private var detailsInFlight: Set<String> = []
    // Derived caches
    @ObservationIgnored private var searchIndexCache: SearchIndex?
    @ObservationIgnored private var searchIndexDirty = true
    @ObservationIgnored private var searchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var gridCache: [CoreGridKey: [Title]] = [:]
    @ObservationIgnored private var similarCache: [String: [Title]] = [:]
    @ObservationIgnored private var genreCache: [TitleKind: [(genre: String, count: Int)]] = [:]
    // User state
    @ObservationIgnored private var persistUserStateTask: Task<Void, Never>?
    @ObservationIgnored private var progressSamples: [String: CoreProgressSample] = [:]
    // Demo
    @ObservationIgnored private var demoStash: CoreDemoStash?
    @ObservationIgnored private var demoCatalog: ProviderCatalog?
    // Validation
    @ObservationIgnored private var validationGovernors: [String: RequestGovernor] = [:]
    @ObservationIgnored private var validationFingerprints: [String: String] = [:]
    @ObservationIgnored private var validationCache: CacheStore?
    // Adult PIN
    @ObservationIgnored private var pinFailures = 0
    @ObservationIgnored private var pinLockedUntil: Date?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    init(environment: AppEnvironment = .live) {
        self.environment = environment
        let isLive = environment == .live
        // Small state JSON in Application Support; big, rebuildable caches (catalogs, metadata, guide) in Caches.
        let files = isLive ? FileStore(baseURL: CorePaths.applicationSupport()) : FileStore.temporary()
        let cacheFiles = isLive ? FileStore(baseURL: CorePaths.caches()) : files
        let secrets: SecretStore = isLive ? KeychainSecretStore() : InMemorySecretStore()
        let stateStore = AppStateStore(files: files)
        let loadedSettings = isLive ? stateStore.loadSettings() : AppSettings()
        let limiter = HostLimiter.standard()
        let metadataStore = MetadataStore(files: cacheFiles)
        let keys = MetadataKeys(tmdb: secrets.secret(for: SecretKeys.tmdbToken),
                                omdb: secrets.secret(for: SecretKeys.omdbKey),
                                language: CoreLocale.metadataLanguage(for: loadedSettings.content.worlds))
        self.files = files
        self.cacheFiles = cacheFiles
        self.cache = CacheStore(files: cacheFiles)
        self.stateStore = stateStore
        self.secrets = secrets
        self.limiter = limiter
        self.gate = StreamGate()
        self.metadataStore = metadataStore
        self.metadataService = MetadataService(keys: keys, store: metadataStore,
                                               http: URLSessionHTTPClient(maxConnectionsPerHost: 6),
                                               limiter: limiter, files: cacheFiles)
        // Every stored property is initialized from here on.
        settings = loadedSettings
        if isLive {
            providers = stateStore.loadProviders()
            userState = stateStore.loadUserState()
        }
        tmdbKeySaved = keys.tmdb != nil
        omdbKeySaved = keys.omdb != nil
        if let token = keys.tmdb { TunaLog.shared.registerSecret(token) }
        if let key = keys.omdb { TunaLog.shared.registerSecret(key) }
        for config in providers where config.isEnabled {
            sessions[config.id] = makeSession(for: config)
        }
        providerStatus = providers.map { ProviderStatus(config: $0) }
        player = PlayerModel(app: self)
        observeTermination()
        observePlayerPresentation()
    }

    /// Launch: load cached catalogs (no network) -> curate -> publish library; then, only if stale, run ONE
    /// sequential background sync per provider (one provider at a time), then the guide (once per 24 h),
    /// then metadata enrichment (visible-first). In `.snapshot` it calls `startDemo()`.
    func start() async {
        guard !didStart else { return }
        didStart = true
        await installPreemptHandlerIfNeeded()
        configureImagePipeline()
        if environment == .snapshot {
            await startDemo()
            return
        }
        await configureProviderLimits()
        await bootFromCache()
        observeMetadataUpdatesIfNeeded()
        updateMetadataPause()
        startStatusRefreshLoop()
        startPipelineTimer()
        scheduleBackgroundPipeline()
    }

    /// Loads DemoContent (no network at all) so people can try the app without a provider.
    func startDemo() async {
        guard !isDemo else { return }
        await installPreemptHandlerIfNeeded()
        if environment == .live { persistUserStateNow() }
        cancelBackgroundWork()
        demoStash = CoreDemoStash(library: library, metadata: metadata, guide: guide, userState: userState,
                                  providerStatus: providerStatus, syncPhase: syncPhase)
        isDemo = true
        curationGeneration += 1
        navigationResetToken &+= 1
        let now = Date()
        let preferences = settings.content
        let demo = await Task.detached(priority: .userInitiated) {
            CoreDemoBundle.make(preferences: preferences, now: now)
        }.value
        guard isDemo else { return }
        demoCatalog = demo.catalog
        metadata = demo.metadata
        guide = demo.guide
        userState = demo.userState
        providerStatus = [demo.status]
        syncPhase = .upToDate(demo.status.lastSync ?? now)
        trendingMovieIDs = []
        trendingSeriesIDs = []
        searchIndexCache = nil
        await publishLibrary(demo.library)
        isBooting = false
    }

    func exitDemo() {
        guard isDemo else { return }
        isDemo = false
        curationGeneration += 1
        railGeneration += 1
        demoCatalog = nil
        if player.content != nil { player.stop() }
        player.isPresented = false
        navigationResetToken &+= 1
        let stash = demoStash
        demoStash = nil
        library = stash?.library ?? .empty
        metadata = stash?.metadata ?? [:]
        guide = stash?.guide ?? .empty
        userState = stash?.userState ?? (environment == .live ? stateStore.loadUserState() : UserState())
        providerStatus = providers.map { config in
            stash?.providerStatus.first(where: { $0.id == config.id }) ?? ProviderStatus(config: config)
        }
        syncPhase = stash?.syncPhase ?? .idle
        homeRails = []
        movieRails = []
        seriesRails = []
        featured = []
        libraryGeneration += 1
        pendingMetadataIDs.removeAll()
        invalidateLookupCaches()
        searchIndexCache = nil
        searchIndexDirty = true
        guard environment == .live, didStart else { return }
        Task { [weak self] in await self?.resumeAfterDemo() }
    }

    // MARK: Providers
    /// ONE request (account check). Does not save anything.
    func validateProvider(kind: ProviderKind, server: String, username: String, password: String) async throws -> AccountInfo {
        let serverURL = try CoreHosts.normalizedServer(kind: kind, input: server)
        let user = username.tunaTrimmed
        let probe = ProviderConfig(id: "validation", name: "Validation", kind: kind, serverURL: serverURL, username: user)
        CoreHosts.registerSecrets(for: probe, password: password)
        let governor = await governorForValidation(probe, password: password)
        let session = ProviderSession(config: probe, password: password, governor: governor, cache: validationCacheStore())
        return try await session.validate()
    }

    /// Saves the provider (password to the keychain), then syncs it.
    func addProvider(_ config: ProviderConfig, password: String) async throws {
        if isDemo { exitDemo() }
        var config = config
        config.serverURL = try CoreHosts.normalizedServer(kind: config.kind, input: config.serverURL)
        config.username = config.username.tunaTrimmed
        if config.name.tunaTrimmed.isEmpty { config.name = CoreHosts.displayName(for: config) }
        if let same = providers.first(where: { $0.id != config.id && $0.kind == config.kind
                && $0.serverURL == config.serverURL && $0.username == config.username }) {
            config.id = same.id // re-adding the same account replaces it instead of duplicating it
        }
        secrets.setSecret(password.isEmpty ? nil : password, for: SecretKeys.providerPassword(config.id))
        if let index = providers.firstIndex(where: { $0.id == config.id }) {
            if activeProviderWork == config.id { await cancelProviderWorkAndWait() }
            providers[index] = config
        } else {
            providers.append(config)
        }
        saveProviders()
        upsertStatus(for: config)
        guard config.isEnabled else {
            sessions[config.id] = nil
            return
        }
        let session = makeSession(for: config, password: password)
        sessions[config.id] = session
        await configureLimits(for: config)
        configureImagePipeline()
        forcedSyncIDs.remove(config.id)
        let saved = config
        let job = enqueueProviderJob { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if await self.performSync(saved, session: session, force: true, announceFailure: false) {
                await self.recurate()
            }
        }
        await job.value
        observeMetadataUpdatesIfNeeded()
        scheduleBackgroundPipeline()
        if let error = syncErrors[saved.id] { throw error }
    }

    func updateProvider(_ config: ProviderConfig, password: String?) async {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        var config = config
        if let normalized = try? CoreHosts.normalizedServer(kind: config.kind, input: config.serverURL) {
            config.serverURL = normalized
        }
        config.username = config.username.tunaTrimmed
        let old = providers[index]
        let passwordKey = SecretKeys.providerPassword(config.id)
        let oldPassword = secrets.secret(for: passwordKey) ?? ""
        let newPassword = password ?? oldPassword
        let credentialsChanged = old.kind != config.kind || old.serverURL != config.serverURL
            || old.username != config.username || newPassword != oldPassword
        let needsNewGovernor = credentialsChanged || old.userAgent != config.userAgent
        if let password { secrets.setSecret(password.isEmpty ? nil : password, for: passwordKey) }
        providers[index] = config
        saveProviders()
        upsertStatus(for: config)

        if !config.isEnabled {
            if activeProviderWork == config.id { await cancelProviderWorkAndWait() }
            sessions[config.id] = nil
        } else if needsNewGovernor || sessions[config.id] == nil {
            if activeProviderWork == config.id { await cancelProviderWorkAndWait() }
            let session = makeSession(for: config, password: newPassword)
            sessions[config.id] = session
            if credentialsChanged {
                let governor = await session.governor
                await governor.resetBreaker()
            }
        } else if let existing = sessions[config.id] {
            let governor = await existing.governor
            if old.pacing != config.pacing { await governor.updatePolicy(GovernorPolicy.forPacing(config.pacing)) }
            sessions[config.id] = ProviderSession(config: config, password: newPassword, governor: governor, cache: cache)
        }

        if config.isEnabled {
            await configureLimits(for: config)
            if catalogs[config.id] == nil, let session = sessions[config.id], let cached = await session.cachedCatalog() {
                catalogs[config.id] = cached
                applyCatalogToStatus(cached, providerID: config.id)
            }
            await refreshShield(for: config.id)
        }
        configureImagePipeline()
        if old.isEnabled != config.isEnabled { await recurate() }
        if credentialsChanged && config.isEnabled {
            // Re-sync the edited account shortly, unless the caller refreshes right away (refreshCatalog cancels this).
            forcedSyncIDs.insert(config.id)
            deferredSyncTask?.cancel()
            deferredSyncTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.scheduleBackgroundPipeline()
            }
        }
    }

    func removeProvider(_ id: ProviderID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        if let content = player.content, content.variant.ref.providerID == id { player.stop() }
        let wasActive = activeProviderWork == id
        if wasActive { cancelProviderJobs() }
        secrets.setSecret(nil, for: SecretKeys.providerPassword(id))
        cache.removeAll(prefix: "providers/\(id)")
        sessions[id] = nil
        catalogs[id] = nil
        lastGuideFetch[id] = nil
        lastSuccessfulSync[id] = nil
        syncErrors[id] = nil
        forcedSyncIDs.remove(id)
        providers.removeAll { $0.id == id }
        providerStatus.removeAll { $0.id == id }
        saveProviders()
        configureImagePipeline()
        if case .syncing(let progress) = syncPhase, progress.providerID == id { syncPhase = .idle }
        Task { [weak self] in
            guard let self else { return }
            await self.recurate()
            if wasActive { self.scheduleBackgroundPipeline() }
        }
    }

    /// User-initiated refresh. Ignored (with a toast) within 10 minutes of the last sync unless `force`.
    func refreshCatalog(force: Bool) async {
        guard !isDemo else {
            showToast("You're exploring the demo library. Add your provider to sync a real one.", style: .info)
            return
        }
        let enabled = providers.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            showToast("Add a provider first.", style: .info)
            return
        }
        if !force, let last = lastKnownSync(), Date().timeIntervalSince(last) < 600 {
            showToast("Your library refreshed less than 10 minutes ago", style: .info)
            return
        }
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        let ids = Set(enabled.map(\.id))
        lastRefreshSucceeded = false
        let job = enqueueProviderJob { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.lastRefreshSucceeded = await self.runUserRefresh(ids)
        }
        await job.value
        if lastRefreshSucceeded, case .upToDate = syncPhase { showToast("Your library is up to date.", style: .success) }
        scheduleBackgroundPipeline()
    }

    func resetShield(for providerID: ProviderID) async {
        guard let session = sessions[providerID] else { return }
        let governor = await session.governor
        await governor.resetBreaker()
        updateStatus(providerID) { $0.lastError = nil }
        await refreshShield(for: providerID)
        showToast("Provider Shield reset. Tuna TV will continue gently.", style: .success)
    }

    // MARK: Settings
    /// Mutates and persists settings; re-curates the library when content preferences changed.
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let old = settings
        settings = updated
        if environment == .live {
            let store = stateStore
            let snapshot = updated
            writeQueue.async { store.saveSettings(snapshot) }
        }
        settingsDidChange(from: old, to: updated)
    }

    func completeOnboarding() {
        updateSettings { $0.hasCompletedOnboarding = true }
        if isDemo && !providers.isEmpty { exitDemo() }
    }

    /// `nil` keeps the saved key, an empty string removes it, anything else replaces it.
    func setMetadataKeys(tmdb: String?, omdb: String?) async {
        if let tmdb {
            let value = tmdb.nonEmpty
            secrets.setSecret(value, for: SecretKeys.tmdbToken)
            if let value { TunaLog.shared.registerSecret(value) }
        }
        if let omdb {
            let value = omdb.nonEmpty
            secrets.setSecret(value, for: SecretKeys.omdbKey)
            if let value { TunaLog.shared.registerSecret(value) }
        }
        tmdbKeySaved = secrets.secret(for: SecretKeys.tmdbToken) != nil
        omdbKeySaved = secrets.secret(for: SecretKeys.omdbKey) != nil
        await metadataService.updateKeys(currentMetadataKeys())
        guard environment == .live, !isDemo, didStart else { return }
        requestedMetadataIDs.removeAll()
        observeMetadataUpdatesIfNeeded()
        metadataPipelineStarted = true
        await refreshTrending()
        enqueueVisibleTitles()
        startMetadataTrickle()
    }

    // MARK: Lookups
    func title(_ id: String) -> Title? { library.title(id) }
    func channel(_ id: String) -> Channel? { library.channel(id) }
    func metadata(for title: Title) -> MediaMetadata? { metadata[title.id] }

    /// Detail page opened: user-initiated metadata fetch + provider details (vod/series info), cached.
    func loadDetails(for title: Title) async {
        guard !isDemo, detailsInFlight.insert(title.id).inserted else { return }
        defer { detailsInFlight.remove(title.id) }
        async let fetchedMetadata = fetchMetadata(for: title)
        async let fetchedInfo = fetchProviderInfo(for: title)
        let (md, info) = await (fetchedMetadata, fetchedInfo)
        guard !isDemo else { return }
        if let md { applyMetadata(md, for: title.id) }
        if let info { providerDetails[title.id] = info }
    }

    /// Cached provider details for a movie (after `loadDetails`).
    func providerInfo(for title: Title) -> RawItemInfo? { providerDetails[title.id] }

    func seriesInfo(for title: Title) async throws -> RawSeriesInfo {
        try await seriesInfo(for: title, preferring: nil)
    }

    func season(for title: Title, number: Int) async -> SeasonMetadata? {
        guard !isDemo, let tvID = metadata[title.id]?.tmdbID ?? title.providerTMDBID else { return nil }
        if settings.onlineMetadata {
            return await metadataService.season(for: title, tvID: tvID, season: number)
        }
        return await metadataStore.season(tvID: tvID, season: number)
    }

    func person(id: Int) async -> PersonDetails? {
        if isDemo { return DemoContent.person(id: id) }
        if settings.onlineMetadata { return await metadataService.person(id: id) }
        return await metadataStore.person(id)
    }

    func nowPlaying(on channel: Channel, at date: Date = Date()) -> Program? {
        for key in guideKeys(for: channel) {
            if let program = guide.now(key, at: date) { return program }
        }
        return nil
    }

    func nextProgram(on channel: Channel, at date: Date = Date()) -> Program? {
        for key in guideKeys(for: channel) {
            if let program = guide.next(key, after: date) { return program }
        }
        return nil
    }

    func programs(on channel: Channel, in interval: DateInterval) -> [Program] {
        for key in guideKeys(for: channel) {
            let found = guide.programs(key, in: interval)
            if !found.isEmpty { return found }
        }
        return []
    }

    func liveEvents(at date: Date = Date()) -> [(channel: Channel, program: Program)] {
        guide.liveEvents(at: date, channels: library.liveShowcase)
    }

    func search(_ query: String, scope: TitleKind? = nil) -> [SearchHit] {
        let trimmed = query.tunaTrimmed
        guard !trimmed.isEmpty else { return [] }
        _ = searchIndexVersion // re-run when a fresher index is swapped in
        let hits = currentSearchIndex().search(trimmed, scope: scope)
        if adultUnlocked && !settings.content.hideAdult { return hits }
        let lib = library
        return hits.filter { hit in
            switch hit.target {
            case .title(let id): return lib.title(id)?.isAdult != true
            case .channel(let id): return lib.channel(id)?.isAdult != true
            default: return true
            }
        }
    }

    func similar(to title: Title) -> [Title] {
        let context = railContext()
        if let cached = similarCache[title.id] { return cached }
        let result = RailComposer.similar(to: title, context)
        if similarCache.count >= 64 { similarCache.removeAll() }
        similarCache[title.id] = result
        return result
    }

    func titles(for person: PersonDetails) -> [Title] {
        RailComposer.titles(for: person, railContext())
    }

    func grid(_ kind: TitleKind?, filter: BrowseFilter) -> [Title] {
        let context = railContext()
        let key = CoreGridKey(kind: kind, filter: filter)
        if let cached = gridCache[key] { return cached }
        let result = RailComposer.grid(kind, filter: filter, context)
        if gridCache.count >= 32 { gridCache.removeAll() }
        gridCache[key] = result
        return result
    }

    func genres(_ kind: TitleKind) -> [(genre: String, count: Int)] {
        let lib = library
        let md = metadata
        if let cached = genreCache[kind] { return cached }
        let result = lib.genres(kind, metadata: md)
        genreCache[kind] = result
        return result
    }

    func insights() -> InsightsReport {
        InsightsReport.build(library: library, metadata: metadata, userState: userState)
    }

    /// Visible-first background enrichment (cards call this from .onAppear in batches; dedupe inside).
    func requestMetadata(for titles: [Title]) {
        guard !isDemo, environment == .live, settings.onlineMetadata else { return }
        let fresh = titles.filter { metadata[$0.id] == nil && !requestedMetadataIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        requestedMetadataIDs.formUnion(fresh.map(\.id))
        pendingMetadataRequests.append(contentsOf: fresh)
        observeMetadataUpdatesIfNeeded()
        guard metadataRequestTask == nil else { return }
        metadataRequestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            let batch = self.pendingMetadataRequests
            self.pendingMetadataRequests = []
            self.metadataRequestTask = nil
            guard !batch.isEmpty, !Task.isCancelled else { return }
            await self.metadataService.enqueue(batch, priority: .background)
        }
    }

    // MARK: User state
    func progress(for title: Title) -> WatchProgress? {
        if title.kind == .movie { return userState.progress[title.id] }
        return userState.progress.values
            .filter { $0.titleID == title.id }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    func progress(forEpisode ref: StreamRef) -> WatchProgress? { userState.progress[ref.id] }

    var continueWatching: [(title: Title, progress: WatchProgress)] {
        var seen = Set<String>()
        var result: [(title: Title, progress: WatchProgress)] = []
        for entry in userState.continueWatching where seen.insert(entry.titleID).inserted {
            guard let title = library.title(entry.titleID), isAllowed(title) else { continue }
            result.append((title: title, progress: entry))
        }
        return result
    }

    var myList: [Title] {
        userState.myList.compactMap { library.title($0) }.filter { isAllowed($0) }
    }

    func isInMyList(_ title: Title) -> Bool { userState.isInMyList(title.id) }

    func toggleMyList(_ title: Title) {
        userState.toggleMyList(title.id)
        userStateDidChange()
    }

    var favoriteChannels: [Channel] { userState.favoriteChannels.compactMap { library.channel($0) } }
    var recentChannels: [Channel] { userState.recentChannels.compactMap { library.channel($0) } }
    func isFavorite(_ channel: Channel) -> Bool { userState.favoriteChannels.contains(channel.id) }

    func toggleFavorite(_ channel: Channel) {
        if let index = userState.favoriteChannels.firstIndex(of: channel.id) {
            userState.favoriteChannels.remove(at: index)
        } else {
            userState.favoriteChannels.append(channel.id)
        }
        userStateDidChange()
    }

    func rating(for title: Title) -> Int { userState.ratings[title.id] ?? 0 }

    func rate(_ title: Title, _ value: Int) {
        let clamped = max(-2, min(2, value))
        guard userState.ratings[title.id] != (clamped == 0 ? nil : clamped) else { return }
        userState.ratings[title.id] = clamped == 0 ? nil : clamped
        userStateDidChange()
    }

    /// Called by PlayerModel (throttled to every ~10 s and on stop).
    func recordProgress(_ progress: WatchProgress) {
        let key = progress.episodeRef?.id ?? progress.titleID
        let now = Date()
        var watched = 0.0
        if let sample = progressSamples[key] {
            let elapsed = now.timeIntervalSince(sample.at)
            if elapsed < 90 { watched = max(0, min(progress.position - sample.position, elapsed + 5)) }
        }
        progressSamples[key] = CoreProgressSample(position: progress.position, at: now)
        var state = userState
        state.progress[key] = progress
        if watched > 0 { CoreHistory.add(seconds: watched, kind: .title, itemID: progress.titleID, at: now, to: &state) }
        userState = state
        userStateDidChange()
    }

    func recordWatched(channel: Channel, seconds: Double) {
        var state = userState
        state.recordChannel(channel.id)
        if seconds >= 1 { CoreHistory.add(seconds: seconds, kind: .channel, itemID: channel.id, at: Date(), to: &state) }
        guard state != userState else { return }
        userState = state
        userStateDidChange()
    }

    func recordVerifiedQuality(_ quality: Quality, variantID: String) {
        guard quality != .unknown, userState.verifiedQualities[variantID] != quality.rawValue else { return }
        userState.verifiedQualities[variantID] = quality.rawValue
        userStateDidChange(railsAffected: false)
        scheduleDeferredCuration()
    }

    func recordFailure(variantID: String) {
        userState.failingVariants[variantID, default: 0] += 1
        userStateDidChange(railsAffected: false)
        scheduleDeferredCuration()
    }

    // MARK: Playback (thin wrappers over `player`)
    func play(_ title: Title, variant: Variant? = nil, resume: Bool = true) {
        if title.kind == .series {
            Task { [weak self] in await self?.playSeries(title, variant: variant, resume: resume) }
            return
        }
        guard let chosen = variant ?? title.defaultVariant else {
            showToast("There's no playable version of \(title.name).", style: .warning)
            return
        }
        let resumeAt = resume ? resumePosition(userState.progress[title.id]) : nil
        player.play(.movie(title, chosen), resumeAt: resumeAt)
    }

    func play(episode: RawEpisode, of title: Title, variant: Variant? = nil) {
        guard let chosen = variant ?? episodeVariant(for: episode, of: title) else {
            showToast("There's no playable version of \(title.name).", style: .warning)
            return
        }
        player.play(.episode(title, chosen, episode), resumeAt: resumePosition(userState.progress[episode.ref.id]))
    }

    func play(_ channel: Channel, variant: Variant? = nil) {
        var state = userState
        state.recordChannel(channel.id)
        if state != userState {
            userState = state
            userStateDidChange()
        }
        if variant == nil, player.isPresented, player.content?.isLive == true {
            player.zap(to: channel)
            return
        }
        guard let chosen = variant ?? channel.defaultVariant else {
            showToast("\(channel.name) has no playable feed.", style: .warning)
            return
        }
        player.play(.channel(channel, chosen), resumeAt: nil)
    }

    func playCatchup(_ program: Program, on channel: Channel) {
        let archived = channel.variants.first { ($0.raw.catchupDays ?? 0) > 0 }
        guard let chosen = archived ?? channel.defaultVariant else {
            showToast("This programme can't be replayed.", style: .warning)
            return
        }
        player.play(.catchup(channel, chosen, program), resumeAt: nil)
    }

    func session(for providerID: ProviderID) -> ProviderSession? { isDemo ? nil : sessions[providerID] }
    var streamGate: StreamGate { gate }
    var hostLimiter: HostLimiter { limiter }

    // MARK: Adult content
    func unlockAdult(pin: String) -> Bool {
        guard let hash = settings.content.adultPINHash else {
            adultUnlocked = true
            return true
        }
        if let until = pinLockedUntil, until > Date() { return false }
        guard CoreHash.sha256Hex(pin) == hash else {
            pinFailures += 1
            if pinFailures >= 5 {
                pinFailures = 0
                pinLockedUntil = Date().addingTimeInterval(30)
            }
            return false
        }
        pinFailures = 0
        pinLockedUntil = nil
        adultUnlocked = true
        return true
    }

    func setAdultPIN(_ pin: String?) {
        let hash = pin?.nonEmpty.map { CoreHash.sha256Hex($0) }
        updateSettings { $0.content.adultPINHash = hash }
        if hash != nil { adultUnlocked = false }
    }

    func showToast(_ text: String, style: ToastMessage.Style = .info) {
        toast = ToastMessage(text: text, style: style)
    }

    /// Writes pending state synchronously (app termination).
    func flushPendingWrites() {
        persistUserStateTask?.cancel()
        persistUserStateNow()
        writeQueue.sync {}
        let store = metadataStore
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await store.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}

// MARK: - Sessions & services

extension TVModel {
    private func makeSession(for config: ProviderConfig, password explicit: String? = nil) -> ProviderSession {
        let password = explicit ?? secrets.secret(for: SecretKeys.providerPassword(config.id)) ?? ""
        CoreHosts.registerSecrets(for: config, password: password)
        let client = URLSessionHTTPClient(maxConnectionsPerHost: 1, defaultHeaders: ["User-Agent": config.userAgent.value])
        let governor = RequestGovernor(providerID: config.id, policy: GovernorPolicy.forPacing(config.pacing),
                                       client: client, persistence: stateStore)
        return ProviderSession(config: config, password: password, governor: governor, cache: cache)
    }

    /// Validation shares the governor of a saved provider on the same panel (else one per panel host), so
    /// repeated "Check connection" clicks are paced. Changed credentials close a tripped breaker.
    private func governorForValidation(_ probe: ProviderConfig, password: String) async -> RequestGovernor {
        let host = CoreHosts.keys(for: probe).last ?? probe.serverURL
        let key = "\(probe.kind.rawValue)|\(host)"
        let fingerprint = CoreHash.sha256Hex("\(probe.serverURL)|\(probe.username)|\(password)")
        var governor: RequestGovernor?
        if let saved = providers.first(where: { $0.kind == probe.kind && CoreHosts.keys(for: $0).last == host }),
           let session = sessions[saved.id] {
            governor = await session.governor
        }
        if governor == nil { governor = validationGovernors[key] }
        let resolved: RequestGovernor
        if let governor {
            resolved = governor
            if let previous = validationFingerprints[key], previous != fingerprint { await resolved.resetBreaker() }
        } else {
            let client = URLSessionHTTPClient(maxConnectionsPerHost: 1, defaultHeaders: ["User-Agent": probe.userAgent.value])
            resolved = RequestGovernor(providerID: "validation-\(host)", policy: GovernorPolicy.forPacing(probe.pacing), client: client)
            validationGovernors[key] = resolved
        }
        validationFingerprints[key] = fingerprint
        return resolved
    }

    private func validationCacheStore() -> CacheStore {
        if let existing = validationCache { return existing }
        let store = CacheStore(files: FileStore.temporary(named: "validation-\(UUID().uuidString)"))
        validationCache = store
        return store
    }

    private func configureImagePipeline() {
        let enabled = providers.filter(\.isEnabled)
        let hosts = Set(enabled.flatMap { CoreHosts.keys(for: $0) })
        let userAgent = enabled.first?.userAgent.value ?? UserAgentPreset.default.value
        ImagePipeline.shared.configure(limiter: limiter, providerHosts: hosts, userAgent: userAgent)
    }

    private func configureProviderLimits() async {
        for config in providers where config.isEnabled { await configureLimits(for: config) }
    }

    private func configureLimits(for config: ProviderConfig) async {
        for host in CoreHosts.keys(for: config) { await limiter.setRule(.providerImages, for: host) }
        let account = providerStatus.first(where: { $0.id == config.id })?.account ?? catalogs[config.id]?.account
        await gate.setMaxStreams(config.effectiveMaxStreams(account: account), for: config.id)
    }

    private func installPreemptHandlerIfNeeded() async {
        guard !preemptHandlerInstalled else { return }
        preemptHandlerInstalled = true
        await gate.setPreemptHandler { [weak self] _ in
            guard let model = self else { return }
            await model.stopPlaybackForPreemption()
        }
    }

    private func stopPlaybackForPreemption() {
        player.stop()
    }

    private func saveProviders() {
        guard environment == .live else { return }
        let list = providers
        let store = stateStore
        writeQueue.async { store.saveProviders(list) }
    }

    private func observeTermination() {
        guard environment == .live else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
        // tvOS rarely sends willTerminate: write state whenever the app leaves the screen.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
    }

    /// Pauses the metadata trickle while video plays; catches up on deferred work once the player closes.
    private func observePlayerPresentation() {
        guard let player else { return }
        withObservationTracking {
            _ = player.isPresented
        } onChange: { [weak self] in
            guard let model = self else { return }
            Task { @MainActor in model.playerPresentationChanged() }
        }
    }

    private func playerPresentationChanged() {
        updateMetadataPause()
        if !player.isPresented {
            if railsStaleWhilePlaying {
                railsStaleWhilePlaying = false
                scheduleRailRebuild()
            }
            if deferredCurationPending { scheduleDeferredCuration(delay: 5) }
        }
        observePlayerPresentation()
    }

    private func updateMetadataPause() {
        guard environment == .live else { return }
        let paused = (player?.isPresented ?? false) || !settings.onlineMetadata
        let service = metadataService
        Task { await service.setPaused(paused) }
    }
}

// MARK: - Boot, provider job queue, sync, guide

extension TVModel {
    private func bootFromCache() async {
        let store = metadataStore
        async let storedMetadata = store.allMetadata()
        for config in providers where config.isEnabled {
            guard let session = sessions[config.id] else { continue }
            if let catalog = await session.cachedCatalog() {
                catalogs[config.id] = catalog
                applyCatalogToStatus(catalog, providerID: config.id)
            }
            if let account = try? await session.account(refresh: false) {
                updateStatus(config.id) { $0.account = account }
                await gate.setMaxStreams(config.effectiveMaxStreams(account: account), for: config.id)
            }
            await refreshShield(for: config.id)
        }
        let stored = await storedMetadata
        if isDemo {
            demoStash?.metadata.merge(stored) { current, _ in current }
        } else {
            mergeMetadata(stored)
            await recurate()
        }
        isBooting = false
    }

    private func resumeAfterDemo() async {
        let stored = await metadataStore.allMetadata()
        guard !isDemo else { return }
        mergeMetadata(stored)
        await recurate()
        startStatusRefreshLoop()
        scheduleBackgroundPipeline()
    }

    /// Serial queue for multi-request provider work: each job starts after the previous one finished.
    @discardableResult
    private func enqueueProviderJob(_ job: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = providerQueueTail
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await job()
            self?.providerJobs[id] = nil
        }
        providerJobs[id] = task
        providerQueueTail = task
        return task
    }

    private func cancelProviderJobs() {
        for task in providerJobs.values { task.cancel() }
        syncJobQueued = false
        guideJobQueued = false
    }

    private func cancelProviderWorkAndWait() async {
        cancelProviderJobs()
        await providerQueueTail?.value
    }

    /// Background pipeline: stale syncs (sequential) -> guide (24 h) -> metadata/channel enrichment.
    private func scheduleBackgroundPipeline() {
        guard environment == .live, !isDemo, didStart else { return }
        if !syncJobQueued {
            syncJobQueued = true
            enqueueProviderJob { [weak self] in
                guard let self else { return }
                self.syncJobQueued = false
                guard !Task.isCancelled else { return }
                await self.syncStaleProviders()
            }
        }
        if !guideJobQueued {
            guideJobQueued = true
            enqueueProviderJob { [weak self] in
                guard let self else { return }
                self.guideJobQueued = false
                guard !Task.isCancelled else { return }
                await self.refreshGuides()
                self.startEnrichment()
            }
        }
    }

    /// Re-checks staleness every 6 h while the app stays open (no network unless something is stale).
    private func startPipelineTimer() {
        pipelineTimerTask?.cancel()
        pipelineTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.scheduleBackgroundPipeline()
            }
        }
    }

    private func syncStaleProviders() async {
        var changed = false
        for config in providers where config.isEnabled {
            if Task.isCancelled || isDemo { return }
            guard let session = sessions[config.id] else { continue }
            let forced = forcedSyncIDs.contains(config.id)
            var due = forced
            if !due { due = await session.isStale() }
            guard due else { continue }
            forcedSyncIDs.remove(config.id)
            if await performSync(config, session: session, force: forced, announceFailure: true) { changed = true }
        }
        if changed, !Task.isCancelled, !isDemo { await recurate() }
        if !changed, syncPhase == .idle, let last = lastKnownSync() { setSyncPhase(.upToDate(last)) }
    }

    /// Forced sync of the given providers (skips accounts synced successfully in the last 2 minutes unless edited).
    private func runUserRefresh(_ ids: Set<ProviderID>) async -> Bool {
        var changed = false
        var firstFailure: String?
        for config in providers where config.isEnabled && ids.contains(config.id) {
            if Task.isCancelled || isDemo { break }
            guard let session = sessions[config.id] else { continue }
            let edited = forcedSyncIDs.contains(config.id)
            if !edited, let last = lastSuccessfulSync[config.id], Date().timeIntervalSince(last) < 120 { continue }
            forcedSyncIDs.remove(config.id)
            if await performSync(config, session: session, force: true, announceFailure: true) {
                changed = true
            } else if firstFailure == nil, let error = syncErrors[config.id], !CoreErrors.isCancellation(error) {
                firstFailure = CoreErrors.message(for: error)
            }
        }
        if changed, !isDemo { await recurate() }
        if let firstFailure { setSyncPhase(.failed(firstFailure)) }
        if !changed, firstFailure == nil, syncPhase == .idle, let last = lastKnownSync() { setSyncPhase(.upToDate(last)) }
        return firstFailure == nil
    }

    /// One provider sync. Never retried automatically; cached data is kept on failure.
    @discardableResult
    private func performSync(_ config: ProviderConfig, session: ProviderSession, force: Bool, announceFailure: Bool) async -> Bool {
        let id = config.id
        activeProviderWork = id
        defer { if activeProviderWork == id { activeProviderWork = nil } }
        setSyncPhase(.syncing(SyncProgress(providerID: id, stage: .checkingAccount,
                                           message: "Contacting \(config.name)…", fraction: 0)))
        do {
            let catalog = try await session.sync(force: force) { [weak self] progress in
                guard let model = self else { return }
                Task { @MainActor in model.handleSyncProgress(progress) }
            }
            syncErrors[id] = nil
            lastSuccessfulSync[id] = Date()
            catalogs[id] = catalog
            applyCatalogToStatus(catalog, providerID: id)
            updateStatus(id) { status in
                status.lastSync = Date()
                status.lastError = nil
            }
            if let account = catalog.account {
                await gate.setMaxStreams(config.effectiveMaxStreams(account: account), for: id)
            }
            setSyncPhase(.upToDate(Date()))
            await refreshShield(for: id)
            return true
        } catch {
            syncErrors[id] = error
            await refreshShield(for: id)
            if CoreErrors.isCancellation(error) {
                if case .syncing = syncPhase { setSyncPhase(.idle) }
                return false
            }
            let message = CoreErrors.message(for: error)
            TunaLog.shared.log("sync", "\(config.name): \(error)")
            updateStatus(id) { $0.lastError = message }
            setSyncPhase(.failed(message))
            if announceFailure && !isDemo { showToast(message, style: .warning) }
            return false
        }
    }

    private func handleSyncProgress(_ progress: SyncProgress) {
        guard activeProviderWork == progress.providerID else { return }
        setSyncPhase(.syncing(progress))
        let now = Date()
        guard now.timeIntervalSince(lastShieldRefresh) >= 1 else { return }
        lastShieldRefresh = now
        Task { [weak self] in await self?.refreshShield(for: progress.providerID) }
    }

    private func setSyncPhase(_ phase: SyncPhase) {
        guard !isDemo, syncPhase != phase else { return }
        syncPhase = phase
    }

    private func lastKnownSync() -> Date? {
        let fromStatus = providerStatus.compactMap(\.lastSync).max()
        let fromSession = lastSuccessfulSync.values.max()
        switch (fromStatus, fromSession) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// The guide: one XMLTV download per provider per 24 h (cache-first in the session), showcase channels only.
    private func refreshGuides() async {
        guard !isDemo else { return }
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-2 * 3600), end: now.addingTimeInterval(30 * 3600))
        var collected: [Program] = []
        for config in providers where config.isEnabled {
            if Task.isCancelled || isDemo { return }
            guard let session = sessions[config.id] else { continue }
            if let last = lastGuideFetch[config.id], now.timeIntervalSince(last) < 24 * 3600 { continue }
            let keys = epgKeys(for: config.id)
            guard !keys.isEmpty else { continue }
            activeProviderWork = config.id
            do {
                let programs = try await session.guide(channels: keys, window: window)
                lastGuideFetch[config.id] = Date()
                collected.append(contentsOf: programs)
            } catch {
                if !CoreErrors.isCancellation(error) {
                    TunaLog.shared.log("guide", "\(config.name): \(CoreErrors.message(for: error))")
                }
            }
            if activeProviderWork == config.id { activeProviderWork = nil }
            await refreshShield(for: config.id)
        }
        guard !collected.isEmpty, !isDemo else { return }
        let programs = collected
        let current = guide
        let merged = await Task.detached(priority: .utility) { current.merging(programs) }.value
        guard !isDemo else { return }
        guide = merged
        searchIndexDirty = true
        scheduleRailRebuild()
    }

    private func epgKeys(for providerID: ProviderID) -> Set<String> {
        var keys = Set<String>()
        for channel in library.liveShowcase + favoriteChannels {
            var onProvider = false
            for variant in channel.variants where variant.ref.providerID == providerID {
                onProvider = true
                if let key = variant.raw.epgChannelID?.nonEmpty { keys.insert(key) }
            }
            if onProvider, let key = channel.epgChannelID?.nonEmpty { keys.insert(key) }
        }
        return keys
    }

    private func guideKeys(for channel: Channel) -> [String] {
        var keys: [String] = []
        if let key = channel.epgChannelID?.nonEmpty { keys.append(key) }
        for variant in channel.variants {
            if let key = variant.raw.epgChannelID?.nonEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    private func cancelBackgroundWork() {
        cancelProviderJobs()
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        metadataTrickleTask?.cancel()
        metadataTrickleTask = nil
        metadataRequestTask?.cancel()
        metadataRequestTask = nil
        pendingMetadataRequests = []
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        recurateTask?.cancel()
        recurateTask = nil
        deferredCurationTask?.cancel()
        deferredCurationTask = nil
        railRebuildTask?.cancel()
        railRebuildTask = nil
    }
}

// MARK: - Provider status

extension TVModel {
    private func updateStatus(_ id: ProviderID, _ change: (inout ProviderStatus) -> Void) {
        guard !isDemo, let index = providerStatus.firstIndex(where: { $0.id == id }) else { return }
        var status = providerStatus[index]
        change(&status)
        if status != providerStatus[index] { providerStatus[index] = status }
    }

    private func upsertStatus(for config: ProviderConfig) {
        guard !isDemo else { return }
        if let index = providerStatus.firstIndex(where: { $0.id == config.id }) {
            if providerStatus[index].config != config { providerStatus[index].config = config }
        } else {
            let catalog = catalogs[config.id]
            providerStatus.append(ProviderStatus(config: config, account: catalog?.account,
                                                 lastSync: catalog?.fetchedAt.values.max()))
        }
    }

    private func applyCatalogToStatus(_ catalog: ProviderCatalog, providerID: ProviderID) {
        updateStatus(providerID) { status in
            if let account = catalog.account { status.account = account }
            if let fetched = catalog.fetchedAt.values.max() { status.lastSync = fetched }
        }
    }

    private func refreshShield(for id: ProviderID) async {
        guard let session = sessions[id] else { return }
        let governor = await session.governor
        let snapshot = await governor.snapshot()
        updateStatus(id) { $0.shield = snapshot }
    }

    /// Local governor snapshots only (no network), every 15 s.
    private func startStatusRefreshLoop() {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isDemo {
                    for id in Array(self.sessions.keys) { await self.refreshShield(for: id) }
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}

// MARK: - Curation, rails, caches

extension TVModel {
    private func enabledCatalogs() -> [ProviderCatalog] {
        providers.filter(\.isEnabled).compactMap { catalogs[$0.id] }
    }

    private func recurate() async {
        curationGeneration += 1
        let generation = curationGeneration
        deferredCurationPending = false
        let built: Library
        if isDemo {
            guard let catalog = demoCatalog else { return }
            let input = CoreCurationInput(catalogs: [catalog], preferences: settings.content)
            built = await Task.detached(priority: .userInitiated) { CoreCuration.library(from: input) }.value
            guard generation == curationGeneration, isDemo else { return }
        } else {
            let input = CoreCurationInput(catalogs: enabledCatalogs(), preferences: settings.content,
                                          verifiedQualities: userState.verifiedQualities,
                                          failingVariants: userState.failingVariants, channelArt: channelArt)
            built = await Task.detached(priority: .userInitiated) { CoreCuration.library(from: input) }.value
            guard generation == curationGeneration, !isDemo else { return }
        }
        await publishLibrary(built)
    }

    private func scheduleRecurate(delay: TimeInterval = 0.35) {
        recurateTask?.cancel()
        recurateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.recurate()
        }
    }

    /// Verified qualities / failing variants re-curate later, never while something is playing.
    private func scheduleDeferredCuration(delay: TimeInterval = 60) {
        guard !isDemo else { return }
        deferredCurationPending = true
        deferredCurationTask?.cancel()
        deferredCurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.deferredCurationPending, !self.isDemo, !self.player.isPresented else { return }
            await self.recurate()
        }
    }

    private func publishLibrary(_ newLibrary: Library) async {
        library = newLibrary
        libraryGeneration += 1
        invalidateLookupCaches()
        searchIndexDirty = true
        scheduleSearchIndexRebuild()
        await rebuildRailsNow()
        if metadataPipelineStarted && !isDemo { startMetadataTrickle() }
    }

    private func railContext(now: Date = Date()) -> RailContext {
        RailContext(library: library, metadata: metadata, userState: userState, preferences: settings.content,
                    trendingMovieIDs: trendingMovieIDs, trendingSeriesIDs: trendingSeriesIDs,
                    guide: guide, now: now)
    }

    /// Throttled (≥ 2 s apart); deferred while the full-window player is up.
    private func scheduleRailRebuild() {
        if !isDemo, player?.isPresented == true {
            railsStaleWhilePlaying = true
            return
        }
        guard railRebuildTask == nil else { return }
        let wait = max(0, 2 - Date().timeIntervalSince(lastRailBuild))
        railRebuildTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.railRebuildTask = nil
            await self.rebuildRailsNow()
        }
    }

    private func rebuildRailsNow() async {
        await mergePendingMetadata()
        railGeneration += 1
        let generation = railGeneration
        lastRailBuild = Date()
        let context = railContext()
        let built = await Task.detached(priority: .userInitiated) { CoreRails.build(context) }.value
        guard generation == railGeneration else { return }
        applyRails(built)
    }

    private func applyRails(_ built: CoreRails) {
        if homeRails != built.home { homeRails = built.home }
        if movieRails != built.movies { movieRails = built.movies }
        if seriesRails != built.series { seriesRails = built.series }
        // The hero stays stable within a library generation (it only upgrades once metadata arrives).
        if featured.isEmpty || featuredGeneration != libraryGeneration || featuredNeedsUpgrade {
            if featured != built.featured { featured = built.featured }
            featuredGeneration = libraryGeneration
            let missing = built.featured.filter { metadata[$0.id] == nil }.count
            featuredNeedsUpgrade = !isDemo && missing * 2 > built.featured.count
        }
        if !isDemo && metadataPipelineStarted { enqueueVisibleTitles() }
    }

    private func invalidateLookupCaches() {
        gridCache.removeAll()
        similarCache.removeAll()
        genreCache.removeAll()
    }

    private func currentSearchIndex() -> SearchIndex {
        if let cached = searchIndexCache {
            if searchIndexDirty { scheduleSearchIndexRebuild() }
            return cached
        }
        let index = SearchIndex(library: library, metadata: metadata, guide: guide)
        searchIndexCache = index
        searchIndexDirty = false
        return index
    }

    private func scheduleSearchIndexRebuild() {
        guard searchIndexTask == nil else { return }
        searchIndexDirty = false
        let lib = library
        let md = metadata
        let currentGuide = guide
        let generation = libraryGeneration
        searchIndexTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                SearchIndex(library: lib, metadata: md, guide: currentGuide)
            }.value
            guard let self else { return }
            self.searchIndexTask = nil
            guard generation == self.libraryGeneration else {
                self.searchIndexDirty = true
                self.scheduleSearchIndexRebuild()
                return
            }
            self.searchIndexCache = index
            self.searchIndexVersion &+= 1
        }
    }

    private func settingsDidChange(from old: AppSettings, to new: AppSettings) {
        let o = old.content
        let n = new.content
        if o.worlds != n.worlds {
            let keys = currentMetadataKeys()
            let service = metadataService
            Task { await service.updateKeys(keys) }
        }
        let curationChanged = o.worlds != n.worlds || o.showcaseQuality != n.showcaseQuality
            || o.autoRelaxShowcase != n.autoRelaxShowcase || o.relaxThreshold != n.relaxThreshold
            || o.hideAdult != n.hideAdult || o.showLowQuality != n.showLowQuality
        if curationChanged { scheduleRecurate() }
        if n.hideAdult && !o.hideAdult { adultUnlocked = false }
        if old.onlineMetadata != new.onlineMetadata {
            updateMetadataPause()
            if new.onlineMetadata {
                startEnrichment()
            } else {
                metadataTrickleTask?.cancel()
                metadataTrickleTask = nil
            }
        }
    }
}

// MARK: - Metadata

extension TVModel {
    private func currentMetadataKeys() -> MetadataKeys {
        MetadataKeys(tmdb: secrets.secret(for: SecretKeys.tmdbToken), omdb: secrets.secret(for: SecretKeys.omdbKey),
                     language: CoreLocale.metadataLanguage(for: settings.content.worlds))
    }

    private func observeMetadataUpdatesIfNeeded() {
        guard metadataUpdatesTask == nil, environment == .live else { return }
        let service = metadataService
        metadataUpdatesTask = Task { [weak self] in
            let stream = await service.updates()
            for await ids in stream {
                guard let self else { return }
                self.metadataDidUpdate(ids)
            }
        }
    }

    private func metadataDidUpdate(_ ids: [String]) {
        guard !isDemo, !ids.isEmpty else { return }
        pendingMetadataIDs.formUnion(ids)
        scheduleRailRebuild()
    }

    private func mergePendingMetadata() async {
        guard !isDemo, !pendingMetadataIDs.isEmpty else { return }
        let ids = Array(pendingMetadataIDs)
        pendingMetadataIDs.removeAll()
        let fresh = await metadataStore.metadata(forIDs: ids)
        guard !isDemo else { return }
        mergeMetadata(fresh)
    }

    private func mergeMetadata(_ incoming: [String: MediaMetadata]) {
        guard !incoming.isEmpty else { return }
        var merged = metadata
        var changed = false
        for (id, value) in incoming where merged[id] != value {
            merged[id] = value
            changed = true
        }
        guard changed else { return }
        metadata = merged
        invalidateLookupCaches()
        searchIndexDirty = true
    }

    private func applyMetadata(_ value: MediaMetadata, for id: String) {
        guard !isDemo, metadata[id] != value else { return }
        metadata[id] = value
        invalidateLookupCaches()
        searchIndexDirty = true
    }

    private func fetchMetadata(for title: Title) async -> MediaMetadata? {
        if settings.onlineMetadata { return await metadataService.metadata(for: title) }
        return await metadataStore.metadata(for: title.id)
    }

    /// One user-initiated vod_info request (cached 14 days by the session).
    private func fetchProviderInfo(for title: Title) async -> RawItemInfo? {
        guard title.kind == .movie, providerDetails[title.id] == nil, let variant = title.defaultVariant,
              let session = sessions[variant.ref.providerID] else { return nil }
        do {
            return try await session.vodInfo(variant.ref)
        } catch {
            TunaLog.shared.log("details", "vod_info for \(title.name): \(CoreErrors.message(for: error))")
            return nil
        }
    }

    /// Metadata + channel art enrichment (never touches the IPTV provider).
    private func startEnrichment() {
        guard environment == .live, !isDemo, enrichmentTask == nil else { return }
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.startMetadataEnrichment()
            await self.enrichChannelArt()
            self.enrichmentTask = nil
        }
    }

    private func startMetadataEnrichment() async {
        guard settings.onlineMetadata, !isDemo else { return }
        metadataPipelineStarted = true
        observeMetadataUpdatesIfNeeded()
        await refreshTrending()
        enqueueVisibleTitles()
        startMetadataTrickle()
    }

    private func refreshTrending() async {
        guard tmdbKeySaved, settings.onlineMetadata, !isDemo else { return }
        let service = metadataService
        async let movies = service.trendingIDs(kind: .movie)
        async let shows = service.trendingIDs(kind: .series)
        let (movieIDs, showIDs) = await (movies, shows)
        guard !isDemo, movieIDs != trendingMovieIDs || showIDs != trendingSeriesIDs else { return }
        trendingMovieIDs = movieIDs
        trendingSeriesIDs = showIDs
        scheduleRailRebuild()
    }

    /// Hero + rail titles first (in screen order).
    private func enqueueVisibleTitles() {
        guard settings.onlineMetadata, !isDemo else { return }
        var seen = Set<String>()
        var batch: [Title] = []
        let candidates = featured + (homeRails + movieRails + seriesRails).flatMap { $0.items.compactMap(CoreRails.title(of:)) }
        for title in candidates where metadata[title.id] == nil && !requestedMetadataIDs.contains(title.id) {
            if seen.insert(title.id).inserted { batch.append(title) }
        }
        guard !batch.isEmpty else { return }
        requestedMetadataIDs.formUnion(seen)
        let service = metadataService
        Task { await service.enqueue(batch, priority: .background) }
    }

    /// The rest of the showcase, a chunk every 20 s, so titles that scroll into view keep jumping the line.
    private func startMetadataTrickle() {
        metadataTrickleTask?.cancel()
        guard settings.onlineMetadata, !isDemo else { return }
        let movies = library.showcase(.movie)
        let series = library.showcase(.series)
        var candidates: [Title] = []
        candidates.reserveCapacity(movies.count + series.count)
        for index in 0..<max(movies.count, series.count) {
            if index < movies.count { candidates.append(movies[index]) }
            if index < series.count { candidates.append(series[index]) }
        }
        let ordered = candidates
        metadataTrickleTask = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                guard let self else { return }
                var batch: [Title] = []
                while cursor < ordered.count && batch.count < 40 {
                    let title = ordered[cursor]
                    cursor += 1
                    if self.metadata[title.id] == nil && !self.requestedMetadataIDs.contains(title.id) { batch.append(title) }
                }
                guard !batch.isEmpty else { return }
                self.requestedMetadataIDs.formUnion(batch.map(\.id))
                await self.metadataService.enqueue(batch, priority: .background)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// iptv-org logos/ids for channels (prefers them over panel-hosted logos). Once per launch.
    private func enrichChannelArt() async {
        guard settings.onlineMetadata, !isDemo, !didEnrichChannels, !library.channels.isEmpty else { return }
        didEnrichChannels = true
        guard let matcher = await metadataService.channelMatcher() else { return }
        let channels = library.liveShowcase + favoriteChannels
        let hosts = Set(providers.flatMap { CoreHosts.keys(for: $0) })
        let art = await Task.detached(priority: .utility) {
            CoreChannelArt.build(channels: channels, matcher: matcher, providerHosts: hosts)
        }.value
        guard !art.isEmpty, !isDemo else { return }
        channelArt = art
        let current = library
        let generation = curationGeneration
        let patched = await Task.detached(priority: .utility) { CoreCuration.applying(art, to: current) }.value
        guard generation == curationGeneration, !isDemo else { return }
        await publishLibrary(patched)
    }
}

// MARK: - User state & playback helpers

extension TVModel {
    private func userStateDidChange(railsAffected: Bool = true) {
        gridCache.removeAll()
        similarCache.removeAll()
        if railsAffected { scheduleRailRebuild() }
        guard !isDemo, environment == .live else { return }
        persistUserStateTask?.cancel()
        persistUserStateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistUserStateNow()
        }
    }

    private func persistUserStateNow() {
        guard !isDemo, environment == .live else { return }
        let state = userState
        let store = stateStore
        writeQueue.async { store.saveUserState(state) }
    }

    private func isAllowed(_ title: Title) -> Bool {
        !title.isAdult || (adultUnlocked && !settings.content.hideAdult)
    }

    private func resumePosition(_ progress: WatchProgress?) -> Double? {
        guard let progress, !progress.isFinished,
              progress.position > settings.playback.resumeThresholdSeconds else { return nil }
        return progress.position
    }

    private func seriesInfo(for title: Title, preferring variant: Variant?) async throws -> RawSeriesInfo {
        let candidates = ([variant].compactMap { $0 }) + title.variants
        if isDemo {
            for candidate in candidates {
                if let info = DemoContent.seriesInfo(for: candidate.ref) { return info }
            }
            throw TunaError.notConfigured("Episodes for this show aren't part of the demo.")
        }
        guard let chosen = variant ?? title.defaultVariant else {
            throw TunaError.invalidInput("This show has no playable version.")
        }
        if let cached = seriesInfoCache[title.id], cached.seriesRef == chosen.ref,
           Date().timeIntervalSince(cached.fetchedAt) < 3600 {
            return cached
        }
        guard let session = sessions[chosen.ref.providerID] else {
            throw TunaError.notConfigured("The provider for this show isn't available right now.")
        }
        let info = try await session.seriesInfo(chosen.ref)
        seriesInfoCache[title.id] = info
        return info
    }

    private func playSeries(_ title: Title, variant: Variant?, resume: Bool) async {
        do {
            let info = try await seriesInfo(for: title, preferring: variant)
            let entries = userState.progress.values.filter { $0.titleID == title.id && $0.episodeRef != nil }
            guard let episode = CoreEpisodePicker.pick(info.episodes, progress: Array(entries), resume: resume) else {
                showToast("No episodes of \(title.name) are available yet.", style: .warning)
                return
            }
            let chosen = variant ?? title.variants.first(where: { $0.ref == info.seriesRef }) ?? title.defaultVariant
            play(episode: episode, of: title, variant: chosen)
        } catch {
            showToast(CoreErrors.message(for: error), style: .error)
        }
    }

    private func episodeVariant(for episode: RawEpisode, of title: Title) -> Variant? {
        if let info = seriesInfoCache[title.id], info.episodes.contains(where: { $0.ref == episode.ref }),
           let match = title.variants.first(where: { $0.ref == info.seriesRef }) {
            return match
        }
        return title.variants.first(where: { $0.ref.providerID == episode.ref.providerID && $0.matchesWorld })
            ?? title.defaultVariant
    }
}
