import Foundation

/// Everything `ProviderSession` does with ONE provider. Rules (the reason this file exists, see the IPTVMac ban
/// diagnosis): every request goes through `governor.perform` (never a raw URLSession); a sync is strictly sequential
/// (each request awaited before the next), one request per section and never per category; cache first (fresh
/// sections are skipped, a fresh sync makes zero requests); raw bytes are saved before decoding; an empty or failed
/// section never replaces the saved one; no automatic retries, and recently failed requests are not repeated.
final class ProviderSessionCore: @unchecked Sendable {
    // MARK: Freshness

    static let accountTTL: TimeInterval = 10 * 60
    static let vodInfoTTL: TimeInterval = 14 * 86_400
    static let seriesInfoTTL: TimeInterval = 3 * 86_400
    /// A details answer without details (`"info": []`) is asked again sooner than a full one.
    static let emptyDetailsTTL: TimeInterval = 86_400
    static let shortEPGTTL: TimeInterval = 10 * 60
    static let guideTTL: TimeInterval = 24 * 3600
    /// After a failed guide download no new attempt is made for this long (persisted across launches).
    static let guideFailureCooldown: TimeInterval = 3 * 3600
    /// After a failed details / short EPG request the same request is not repeated for this long.
    static let requestFailureCooldown: TimeInterval = 2 * 60
    static let shortEPGLimit = 4

    let config: ProviderConfig
    private let password: String
    private let governor: RequestGovernor
    private let cache: CacheStore
    private let clock: TunaClock
    private let keys: ProviderCacheKeys
    private let state = ProviderSessionState()
    /// Xtream: normalized panel address. M3U: the playlist URL.
    private let server: String

    private static let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
    private static let badServer = TunaError.invalidInput("The server address is not valid.")

    init(config: ProviderConfig, password: String, governor: RequestGovernor, cache: CacheStore, clock: TunaClock) {
        self.config = config
        self.password = password
        self.governor = governor
        self.cache = cache
        self.clock = clock
        self.keys = ProviderCacheKeys(providerID: config.id)
        let trimmed = config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch config.kind {
        case .xtream: server = XtreamURLKit.normalizeServer(trimmed) ?? trimmed
        case .m3u: server = trimmed
        }
        TunaLog.shared.registerSecret(password)
        TunaLog.shared.registerSecret(config.username)
    }

    // MARK: - Account

    func validate() async throws -> AccountInfo {
        switch config.kind {
        case .xtream:
            let account = try await fetchAccount(priority: .userInitiated)
            try Self.requireUsable(account)
            return account
        case .m3u:
            return try await validatePlaylist()
        }
    }

    func account(refresh: Bool) async throws -> AccountInfo? {
        guard config.kind == .xtream else { return nil }
        let saved = loadAccount()
        guard refresh else { return saved }
        if let saved, isFresh(saved.fetchedAt, ttl: Self.accountTTL, now: clock.now()) { return saved }
        return try await fetchAccount(priority: .userInitiated)
    }

    /// ONE `player_api.php` call (shared by concurrent callers). The answer is cached without the password the panel
    /// echoes back in `user_info`.
    private func fetchAccount(priority: RequestPriority) async throws -> AccountInfo {
        guard let url = XtreamURLKit.apiURL(server: server, username: config.username, password: password, action: nil, params: [:]) else {
            throw Self.badServer
        }
        let response = try await sharedGet(key: keys.section(.account), url: url, purpose: "account", priority: priority)
        let json = try XtreamJSONKit.parse(response.body)
        let fetchedAt = clock.now()
        let account = try XtreamDecodingKit.account(json: json, now: fetchedAt)
        store(Self.redactingPassword(json), keys.section(.account), fetchedAt)
        return account
    }

    private func loadAccount() -> AccountInfo? {
        guard let entry = cache.entry(keys.section(.account)), let json = try? XtreamJSONKit.parse(entry.data) else { return nil }
        return try? XtreamDecodingKit.account(json: json, now: entry.fetchedAt)
    }

    private func serverTimeZone() -> TimeZone? {
        guard let entry = cache.entry(keys.section(.account)), let json = try? XtreamJSONKit.parse(entry.data) else { return nil }
        return XtreamDecodingKit.serverTimeZone(json: json)
    }

    static func requireUsable(_ account: AccountInfo) throws {
        guard account.isAuthorized else { throw TunaError.unauthorized("The provider did not accept this username and password.") }
        guard !account.isUsable else { return }
        if let status = account.status, !status.lowercased().hasPrefix("active") {
            throw TunaError.unauthorized("The provider reports this account as \(status.lowercased()).")
        }
        throw TunaError.unauthorized("The subscription has expired.")
    }

    static func redactingPassword(_ json: Any) -> Data {
        guard var root = json as? [String: Any] else { return Data(#"{"user_info":{"auth":0}}"#.utf8) }
        if var user = root["user_info"] as? [String: Any] {
            user["password"] = nil
            root["user_info"] = user
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [])) ?? Data(#"{"user_info":{"auth":0}}"#.utf8)
    }

    // MARK: - Catalog

    func cachedCatalog() async -> ProviderCatalog? {
        await assembleCatalog()
    }

    func isStale() async -> Bool {
        let now = clock.now()
        switch config.kind {
        case .xtream: return XtreamSyncSection.lists.contains { !isFresh(lastChecked($0), ttl: config.syncInterval, now: now) }
        case .m3u: return !isFresh(lastPlaylistCheck(), ttl: config.syncInterval, now: now)
        }
    }

    func sync(force: Bool, progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> ProviderCatalog {
        // Single flight: a second caller joins the running sync (and receives its progress) instead of starting one.
        let task = await state.joinSync(listener: progress) { generation in
            Task.detached(priority: .utility) { [self] in
                do {
                    let catalog = try await self.runSync(force: force)
                    await self.state.endSync(generation: generation)
                    return catalog
                } catch {
                    await self.state.endSync(generation: generation)
                    throw error
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runSync(force: Bool) async throws -> ProviderCatalog {
        switch config.kind {
        case .xtream: return try await syncXtream(force: force)
        case .m3u: return try await syncPlaylist(force: force)
        }
    }

    private func syncXtream(force: Bool) async throws -> ProviderCatalog {
        let started = clock.now()
        let lists = XtreamSyncSection.lists.filter { force || !isFresh(lastChecked($0), ttl: config.syncInterval, now: started) }
        guard !lists.isEmpty else { return await finishSync(notes: [], upToDate: true) }

        // The account check opens the sync unless a usable answer is younger than 10 min (e.g. from `validate()`).
        var stages = lists
        let savedAccount = loadAccount()
        let accountIsFresh = savedAccount.map { $0.isUsable && isFresh($0.fetchedAt, ttl: Self.accountTTL, now: started) } ?? false
        if force || !accountIsFresh { stages.insert(.account, at: 0) }

        log("sync: \(stages.map(\.rawValue).joined(separator: ", "))")
        let totalWeight = stages.reduce(0) { $0 + $1.weight }
        var completed = 0.0
        var counts: [String: Int] = [:]
        var notes: [String] = []
        for section in stages {
            // Strictly one request at a time: each one is awaited before the next starts.
            if Task.isCancelled { throw TunaError.cancelled }
            await report(section.stage, "Loading \(section.label)…", counts: counts, fraction: completed / totalWeight, pacing: true)
            do {
                if section == .account {
                    try Self.requireUsable(try await fetchAccount(priority: .background))
                } else if let count = try await fetchList(section) {
                    if !section.isCategoryList { counts[section.kind.rawValue] = count }
                } else {
                    notes.append("The provider sent no \(section.label); the saved list was kept.")
                }
            } catch {
                let failure = Self.tunaError(error)
                // Only an unreadable answer (e.g. an HTML page with status 200) lets the sync go on with the next
                // section. Paused / unauthorized / budget / HTTP / network errors stop it at once; the cache stays.
                guard case .decoding(let reason) = failure, section != .account else {
                    log("sync stopped at \(section.rawValue): \(failure)")
                    throw failure
                }
                log("\(section.rawValue) kept from cache: \(reason)")
                notes.append("\(reason) The saved \(section.label) were kept.")
            }
            completed += section.weight
        }
        return await finishSync(notes: notes, upToDate: false)
    }

    private func finishSync(notes: [String], upToDate: Bool) async -> ProviderCatalog {
        let catalog = await assembleCatalog() ?? ProviderCatalog(providerID: config.id)
        let message = upToDate ? "Everything is up to date." : (notes.isEmpty ? "Catalog updated." : notes.joined(separator: " "))
        await report(.done, message, counts: Self.counts(catalog), fraction: 1, pacing: false)
        if !upToDate { log("sync finished: \(catalog.items.count) items") }
        return catalog
    }

    /// ONE list request. Returns the number of decoded rows, or nil when the provider sent an empty list and a
    /// non-empty saved one was kept.
    private func fetchList(_ section: XtreamSyncSection) async throws -> Int? {
        guard let action = section.action,
              let url = XtreamURLKit.apiURL(server: server, username: config.username, password: password, action: action, params: [:]) else {
            throw Self.badServer
        }
        let response = try await get(url, purpose: section.rawValue, priority: .background, timeout: 60)
        let json = try XtreamJSONKit.parse(response.body)
        let rows = try XtreamDecodingKit.listRows(json, what: section.label)
        let fetchedAt = clock.now()
        if rows.isEmpty, let saved = cache.entry(keys.section(section)), Self.hasRows(saved.data) {
            store(Data("[]".utf8), keys.checked(section), fetchedAt)   // checked, nothing replaced
            return nil
        }
        // Raw bytes are saved BEFORE decoding: a decoding bug never costs another download.
        store(response.body, keys.section(section), fetchedAt)
        cache.remove(keys.checked(section))
        if section.isCategoryList {
            let categories = try XtreamDecodingKit.categories(json: json, kind: section.kind)
            _ = await state.setCategories(section.kind, ProviderMemo(date: fetchedAt, value: categories))
            return categories.count
        }
        let categoryMemo = await categories(for: section.kind)
        let items = try XtreamDecodingKit.items(json: json, kind: section.kind, providerID: config.id,
                                                categories: Self.names(categoryMemo?.value))
        await state.setItems(section.kind, ProviderItemsMemo(date: fetchedAt, namesVersion: categoryMemo?.version, items: items))
        return items.count
    }

    /// Last time a list section was fetched, or checked and found empty.
    private func lastChecked(_ section: XtreamSyncSection) -> Date? {
        [cache.entry(keys.section(section))?.fetchedAt, cache.entry(keys.checked(section))?.fetchedAt].compactMap { $0 }.max()
    }

    private func assembleCatalog() async -> ProviderCatalog? {
        switch config.kind {
        case .xtream:
            var categories: [RawCategory] = []
            var items: [RawItem] = []
            var fetchedAt: [String: Date] = [:]
            for kind in [StreamKind.live, .movie, .series] {
                let categoryMemo = await self.categories(for: kind)
                if let categoryMemo {
                    categories += categoryMemo.value
                    fetchedAt[XtreamSyncSection.categories(for: kind).rawValue] = categoryMemo.date
                }
                if let itemMemo = await self.items(for: kind, categories: categoryMemo) {
                    items += itemMemo.value
                    fetchedAt[XtreamSyncSection.items(for: kind).rawValue] = itemMemo.date
                }
            }
            guard !fetchedAt.isEmpty else { return nil }
            let account = loadAccount()
            if let account { fetchedAt[XtreamSyncSection.account.rawValue] = account.fetchedAt }
            let guide = config.epgURL.flatMap(ProviderTextKit.httpURLString) ?? XtreamURLKit.publicXMLTVAddress(server: server)
            return ProviderCatalog(providerID: config.id, account: account, categories: categories, items: items,
                                   fetchedAt: fetchedAt, guideURL: guide)
        case .m3u:
            guard let memo = await playlistClassification() else { return nil }
            var catalog = memo.value.catalog
            catalog.fetchedAt = ["playlist": memo.date]
            if let custom = config.epgURL.flatMap(ProviderTextKit.httpURLString) { catalog.guideURL = custom }
            return catalog
        }
    }

    private func categories(for kind: StreamKind) async -> ProviderMemo<[RawCategory]>? {
        if let memo = await state.categories(kind) { return memo }
        guard let entry = cache.entry(keys.section(XtreamSyncSection.categories(for: kind))),
              let json = try? XtreamJSONKit.parse(entry.data),
              let categories = try? XtreamDecodingKit.categories(json: json, kind: kind) else { return nil }
        return await state.setCategories(kind, ProviderMemo(date: entry.fetchedAt, value: categories))
    }

    private func items(for kind: StreamKind, categories: ProviderMemo<[RawCategory]>?) async -> ProviderMemo<[RawItem]>? {
        let names = Self.names(categories?.value)
        if let memo = await state.items(kind) {
            if memo.namesVersion == categories?.version { return ProviderMemo(date: memo.date, value: memo.items) }
            // The category list changed after the items were decoded: refresh the resolved names.
            let renamed = memo.items.map { item -> RawItem in
                var copy = item
                copy.categoryName = item.categoryID.flatMap { names[$0] }
                return copy
            }
            await state.setItems(kind, ProviderItemsMemo(date: memo.date, namesVersion: categories?.version, items: renamed))
            return ProviderMemo(date: memo.date, value: renamed)
        }
        guard let entry = cache.entry(keys.section(XtreamSyncSection.items(for: kind))),
              let json = try? XtreamJSONKit.parse(entry.data),
              let decoded = try? XtreamDecodingKit.items(json: json, kind: kind, providerID: config.id, categories: names) else { return nil }
        await state.setItems(kind, ProviderItemsMemo(date: entry.fetchedAt, namesVersion: categories?.version, items: decoded))
        return ProviderMemo(date: entry.fetchedAt, value: decoded)
    }

    // MARK: - M3U playlist

    private func playlistURL() -> URL? {
        var text = server
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private func lastPlaylistCheck() -> Date? {
        [cache.entry(keys.playlist)?.fetchedAt, cache.entry(keys.playlistChecked)?.fetchedAt].compactMap { $0 }.max()
    }

    /// ONE request for the first KB (`Range`). A server that ignores `Range` sends the whole playlist: it is kept,
    /// so the first sync does not download it again.
    private func validatePlaylist() async throws -> AccountInfo {
        guard let url = playlistURL() else { throw Self.badServer }
        let response = try await get(url, purpose: "playlist_head", priority: .userInitiated,
                                     extraHeaders: ["Range": "bytes=0-1023"], timeout: 60)
        guard M3UParsingKit.looksLikePlaylist(response.body) else { throw Self.notAPlaylist(response.body) }
        let fetchedAt = clock.now()
        if response.status == 200 && response.body.count > 1024 { _ = try? await acceptPlaylist(response.body, fetchedAt: fetchedAt) }
        return AccountInfo(isAuthorized: true, status: "Active", fetchedAt: fetchedAt)
    }

    private func syncPlaylist(force: Bool) async throws -> ProviderCatalog {
        if !force && isFresh(lastPlaylistCheck(), ttl: config.syncInterval, now: clock.now()) {
            return await finishSync(notes: [], upToDate: true)
        }
        await report(.playlist, "Downloading your playlist…", counts: [:], fraction: 0, pacing: true)
        guard let url = playlistURL() else { throw Self.badServer }
        let response = try await get(url, purpose: "playlist", priority: .background, timeout: 120)
        guard M3UParsingKit.looksLikePlaylist(response.body) else { throw Self.notAPlaylist(response.body) }
        let replaced = try await acceptPlaylist(response.body, fetchedAt: clock.now())
        return await finishSync(notes: replaced ? [] : ["The provider sent an empty playlist; the saved one was kept."], upToDate: false)
    }

    /// Saves a downloaded playlist (raw, before classification) unless it is empty while a non-empty one is saved.
    /// Returns false when the saved playlist was kept.
    private func acceptPlaylist(_ body: Data, fetchedAt: Date) async throws -> Bool {
        guard body.count <= XtreamJSONKit.maxResponseBytes else { throw TunaError.decoding("The playlist is too large.") }
        let playlist = M3UParsingKit.parse(body)
        if playlist.entries.isEmpty, let saved = await playlistClassification(), !saved.value.entries.isEmpty {
            store(Data("[]".utf8), keys.playlistChecked, fetchedAt)
            return false
        }
        store(body, keys.playlist, fetchedAt)
        cache.remove(keys.playlistChecked)
        let classification = M3UParsingKit.classify(playlist, providerID: config.id)
        await state.setPlaylist(ProviderMemo(date: fetchedAt, value: classification))
        return true
    }

    private func playlistClassification() async -> ProviderMemo<M3UParsingKit.Classification>? {
        if let memo = await state.playlist() { return memo }
        guard let entry = cache.entry(keys.playlist) else { return nil }
        let memo = ProviderMemo(date: entry.fetchedAt, value: M3UParsingKit.classify(M3UParsingKit.parse(entry.data), providerID: config.id))
        await state.setPlaylist(memo)
        return memo
    }

    private static func notAPlaylist(_ body: Data) -> TunaError {
        startsWithMarkup(body) ? .decoding(XtreamJSONKit.describeMarkup(body)) : .decoding("The address did not return an M3U playlist.")
    }

    // MARK: - Details (opened by the user: one request, cached)

    func vodInfo(_ ref: StreamRef) async throws -> RawItemInfo {
        if config.kind == .m3u { return await playlistItemInfo(ref) }
        switch ref.kind {
        case .movie: break
        case .series: return try await seriesInfo(ref).info ?? RawItemInfo()
        case .live, .episode: throw TunaError.invalidInput("Details exist only for movies and series.")
        }
        return try await details(key: keys.vodInfo(ref.streamID), action: "get_vod_info", params: ["vod_id": ref.streamID],
                                 purpose: "vod_info", ttl: { Self.hasDetails($0) ? Self.vodInfoTTL : Self.emptyDetailsTTL },
                                 decode: { json, _ in try XtreamDecodingKit.vodInfo(json: json) })
    }

    func seriesInfo(_ ref: StreamRef) async throws -> RawSeriesInfo {
        if config.kind == .m3u { return try await playlistSeriesInfo(ref) }
        guard ref.kind == .series else { throw TunaError.invalidInput("Episodes exist only for series.") }
        return try await details(key: keys.seriesInfo(ref.streamID), action: "get_series_info", params: ["series_id": ref.streamID],
                                 purpose: "series_info", ttl: { $0.episodes.isEmpty ? Self.emptyDetailsTTL : Self.seriesInfoTTL },
                                 decode: { json, fetchedAt in try XtreamDecodingKit.seriesInfo(json: json, seriesRef: ref, now: fetchedAt) })
    }

    func shortEPG(_ ref: StreamRef, channelKey: String) async throws -> [Program] {
        guard config.kind == .xtream, ref.kind == .live else { return [] }
        let timeZone = serverTimeZone()
        return try await details(key: keys.shortEPG(ref.streamID), action: "get_short_epg",
                                 params: ["stream_id": ref.streamID, "limit": String(Self.shortEPGLimit)], purpose: "short_epg",
                                 ttl: { _ in Self.shortEPGTTL },
                                 decode: { json, _ in try XtreamDecodingKit.shortEPG(json: json, channelKey: channelKey, serverTimeZone: timeZone) })
    }

    /// Cache first; else ONE user-initiated request, shared by concurrent callers and not repeated for a while after
    /// a failure. A saved copy (even an old one) is returned when the request fails.
    private func details<Value>(key: String, action: String, params: [String: String], purpose: String,
                                ttl: (Value) -> TimeInterval, decode: (Any, Date) throws -> Value) async throws -> Value {
        let now = clock.now()
        let saved = cache.entry(key)
        let savedValue = saved.flatMap { entry in (try? XtreamJSONKit.parse(entry.data)).flatMap { try? decode($0, entry.fetchedAt) } }
        if let saved, let savedValue, isFresh(saved.fetchedAt, ttl: ttl(savedValue), now: now) { return savedValue }
        if let cooling = await state.cooldownError(for: key, now: now) {
            if let savedValue { return savedValue }
            throw cooling
        }
        do {
            guard let url = XtreamURLKit.apiURL(server: server, username: config.username, password: password, action: action, params: params) else {
                throw Self.badServer
            }
            let response = try await sharedGet(key: key, url: url, purpose: purpose, priority: .userInitiated)
            let json = try XtreamJSONKit.parse(response.body)
            let fetchedAt = clock.now()
            let value = try decode(json, fetchedAt)
            store(response.body, key, fetchedAt)
            return value
        } catch {
            let failure = Self.tunaError(error)
            if Self.shouldCoolDown(failure) {
                await state.setCooldown(for: key, until: clock.now().addingTimeInterval(Self.requestFailureCooldown), error: failure)
            }
            if let savedValue { return savedValue }
            throw failure
        }
    }

    private static func hasDetails(_ info: RawItemInfo) -> Bool {
        info.plot != nil || info.cast != nil || info.director != nil || info.genre != nil || info.releaseDate != nil
            || info.rating != nil || info.durationSeconds != nil || info.tmdbID != nil || info.trailerYouTubeID != nil
            || !info.backdropURLs.isEmpty
    }

    private func playlistItemInfo(_ ref: StreamRef) async -> RawItemInfo {
        guard let item = await playlistClassification()?.value.catalog.items.first(where: { $0.ref == ref }) else { return RawItemInfo() }
        return RawItemInfo(name: item.name, posterURL: item.iconURL, containerExtension: item.containerExtension)
    }

    /// M3U series are built from the saved playlist: no network.
    private func playlistSeriesInfo(_ ref: StreamRef) async throws -> RawSeriesInfo {
        guard let memo = await playlistClassification() else { throw TunaError.notConfigured("The playlist has not been downloaded yet.") }
        let episodes = memo.value.episodes[ref.streamID] ?? []
        let counts = Dictionary(grouping: episodes, by: { $0.season }).mapValues { $0.count }
        let seasons = counts.keys.sorted().map { RawSeason(number: $0, episodeCount: counts[$0]) }
        let info = memo.value.catalog.items.first(where: { $0.ref == ref }).map { RawItemInfo(name: $0.name, posterURL: $0.iconURL) }
        return RawSeriesInfo(seriesRef: ref, info: info, seasons: seasons, episodes: episodes, fetchedAt: memo.date)
    }

    // MARK: - Guide (XMLTV)

    func guide(channels: Set<String>, window: DateInterval, force: Bool) async throws -> [Program] {
        guard !channels.isEmpty else { return [] }
        let now = clock.now()
        let saved = cache.entry(keys.guide)
        if !force, let saved, isFresh(saved.fetchedAt, ttl: Self.guideTTL, now: now) {
            return await programs(inGuide: saved, channels: channels, window: window)
        }
        if !force, let failure = cache.entry(keys.guideFailure), isFresh(failure.fetchedAt, ttl: Self.guideFailureCooldown, now: now) {
            if let saved { return await programs(inGuide: saved, channels: channels, window: window) }
            throw TunaError.paused(until: failure.fetchedAt.addingTimeInterval(Self.guideFailureCooldown),
                                   reason: "The TV guide download failed recently: \(String(decoding: failure.data, as: UTF8.self))")
        }
        guard let url = await guideDownloadURL() else { throw TunaError.notConfigured("This provider has no TV guide (XMLTV) address.") }
        do {
            let response = try await get(url, purpose: "xmltv", priority: .background, timeout: 120)
            try Self.requireGuide(response.body)
            let entry = CacheStore.Entry(data: response.body, fetchedAt: clock.now())
            store(entry.data, keys.guide, entry.fetchedAt)
            cache.remove(keys.guideFailure)
            return await programs(inGuide: entry, channels: channels, window: window)
        } catch {
            let failure = Self.tunaError(error)
            if Self.shouldCoolDown(failure) { store(Data(failure.description.utf8), keys.guideFailure, clock.now()) }
            if let saved, failure != .cancelled { return await programs(inGuide: saved, channels: channels, window: window) }
            throw failure
        }
    }

    private func guideDownloadURL() async -> URL? {
        if let custom = config.epgURL.flatMap(ProviderTextKit.httpURLString) { return URL(string: custom) }
        switch config.kind {
        case .xtream: return XtreamURLKit.xmltvURL(server: server, username: config.username, password: password)
        case .m3u: return await playlistClassification()?.value.catalog.guideURL.flatMap { URL(string: $0) }
        }
    }

    private func programs(inGuide entry: CacheStore.Entry, channels: Set<String>, window: DateInterval) async -> [Program] {
        if let memo = await state.guide(), memo.fetchedAt == entry.fetchedAt, memo.channels == channels, memo.window == window {
            return memo.programs
        }
        let programs = XMLTVParsingKit.parse(entry.data, channels: channels, window: window)
        await state.setGuide(ProviderGuideMemo(fetchedAt: entry.fetchedAt, channels: channels, window: window, programs: programs))
        return programs
    }

    private static func requireGuide(_ body: Data) throws {
        if XMLTVParsingKit.isGzip(body) { throw TunaError.decoding("The TV guide is gzip-compressed; use an uncompressed XMLTV address.") }
        let head = String(decoding: body.prefix(65_536), as: UTF8.self).lowercased()
        if head.contains("<tv") { return }
        throw TunaError.decoding(startsWithMarkup(body) && head.contains("<html") ? XtreamJSONKit.describeMarkup(body)
                                 : "The guide address did not return an XMLTV guide.")
    }

    // MARK: - Playback (no network)

    func streamURL(for ref: StreamRef, containerExtension: String?, directURL: String?) async -> URL? {
        switch config.kind {
        case .m3u:
            var candidate = directURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate?.isEmpty ?? true { candidate = await playlistClassification()?.value.entries[ref.streamID]?.url }
            guard let candidate, M3UParsingKit.isPlayable(candidate) else { return nil }
            return URL(string: candidate) ?? URL(string: candidate.replacingOccurrences(of: " ", with: "%20"))
        case .xtream:
            switch ref.kind {
            case .live:
                return XtreamURLKit.streamURL(kind: "live", server: server, username: config.username, password: password,
                                              id: ref.streamID, ext: liveExtension(), defaultExt: "ts")
            case .movie:
                return XtreamURLKit.streamURL(kind: "movie", server: server, username: config.username, password: password,
                                              id: ref.streamID, ext: containerExtension, defaultExt: "mp4")
            case .episode:
                return XtreamURLKit.streamURL(kind: "series", server: server, username: config.username, password: password,
                                              id: ref.streamID, ext: containerExtension, defaultExt: "mp4")
            case .series:
                return nil
            }
        }
    }

    /// `.auto`: MPEG-TS, unless the account lists allowed formats without "ts" but with "m3u8".
    private func liveExtension() -> String {
        switch config.liveFormat {
        case .ts: return "ts"
        case .m3u8: return "m3u8"
        case .auto:
            let formats = loadAccount()?.allowedOutputFormats ?? []
            return !formats.isEmpty && !formats.contains("ts") && formats.contains("m3u8") ? "m3u8" : "ts"
        }
    }

    func catchupURL(for ref: StreamRef, program: Program) async -> URL? {
        let now = clock.now()
        guard program.end > program.start, program.start < now else { return nil }   // the future has no archive
        switch config.kind {
        case .xtream:
            guard ref.kind == .live else { return nil }
            if let channel = await state.items(.live)?.items.first(where: { $0.ref == ref }) {
                guard let days = channel.catchupDays,
                      program.start >= now.addingTimeInterval(-TimeInterval(days) * 86_400 - 3600) else { return nil }
            }
            return XtreamURLKit.catchupURL(server: server, username: config.username, password: password, streamID: ref.streamID,
                                           start: program.start, durationMinutes: Int((program.duration / 60).rounded(.up)),
                                           serverTimeZone: serverTimeZone() ?? Self.utc)
        case .m3u:
            guard let entry = await playlistClassification()?.value.entries[ref.streamID] else { return nil }
            return M3UParsingKit.catchupURL(for: entry, start: program.start, end: program.end, now: now)
        }
    }

    func streamHeaders(for item: RawItem?) async -> [String: String] {
        var headers = ["User-Agent": item?.userAgentOverride ?? config.userAgent.value]
        if let referrer = item?.referrerOverride, !referrer.isEmpty { headers["Referer"] = referrer }
        return headers
    }

    // MARK: - Requests

    /// The only way this type talks to the provider: `governor.perform` (one in flight, paced, breaker).
    private func get(_ url: URL, purpose: String, priority: RequestPriority, extraHeaders: [String: String] = [:],
                     timeout: TimeInterval = 30) async throws -> HTTPResponse {
        var headers = ["User-Agent": config.userAgent.value]
        for (name, value) in extraHeaders { headers[name] = value }
        let request = HTTPRequest(url: url, headers: headers, timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await governor.perform(request, priority: priority, purpose: purpose)
        } catch {
            throw Self.tunaError(error)
        }
        guard response.isSuccess else { throw TunaError.http(status: response.status, host: request.hostKey) }
        return response
    }

    /// `get`, shared by concurrent callers asking for the same `key` (one request, every caller gets its answer).
    private func sharedGet(key: String, url: URL, purpose: String, priority: RequestPriority) async throws -> HTTPResponse {
        let task = await state.sharedFetch(key: key) {
            Task.detached { [self] in
                do {
                    let response = try await self.get(url, purpose: purpose, priority: priority)
                    await self.state.endFetch(key: key)
                    return response
                } catch {
                    await self.state.endFetch(key: key)
                    throw error
                }
            }
        }
        return try await task.value
    }

    // MARK: - Helpers

    private func report(_ stage: SyncStage, _ message: String, counts: [String: Int], fraction: Double, pacing: Bool) async {
        var wait: TimeInterval?
        if pacing, let next = await governor.snapshot().nextAllowedAt {
            let seconds = next.timeIntervalSince(clock.now())
            wait = seconds > 0 ? seconds : nil
        }
        await state.emit(SyncProgress(providerID: config.id, stage: stage, message: message, counts: counts,
                                      fraction: min(1, max(0, fraction)), nextRequestIn: wait))
    }

    private func store(_ data: Data, _ key: String, _ fetchedAt: Date) {
        do {
            try cache.store(data, for: key, fetchedAt: fetchedAt)
        } catch {
            log("could not save \(key): \(error)")
        }
    }

    /// Fresh when younger than `ttl` (a date far in the future, from a clock change, does not count as fresh).
    private func isFresh(_ date: Date?, ttl: TimeInterval, now: Date) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age < ttl && age > -86_400
    }

    private func log(_ message: String) {
        TunaLog.shared.log("providers", "[\(config.name)] \(message)")
    }

    static func tunaError(_ error: Error) -> TunaError {
        if let tuna = error as? TunaError { return tuna }
        if error is CancellationError { return .cancelled }
        return .network(error.localizedDescription)
    }

    /// Errors after which the same request is not repeated for a while (the governor handles pauses and budgets).
    private static func shouldCoolDown(_ error: TunaError) -> Bool {
        switch error {
        case .http, .network, .decoding: return true
        default: return false
        }
    }

    static func names(_ categories: [RawCategory]?) -> [String: String] {
        var names: [String: String] = [:]
        for category in categories ?? [] where names[category.id] == nil { names[category.id] = category.name }
        return names
    }

    static func counts(_ catalog: ProviderCatalog) -> [String: Int] {
        var counts = [StreamKind.live.rawValue: 0, StreamKind.movie.rawValue: 0, StreamKind.series.rawValue: 0]
        for item in catalog.items { counts[item.ref.kind.rawValue, default: 0] += 1 }
        return counts
    }

    /// True when a saved list body has at least one row (cheap: looks at the first bytes only).
    static func hasRows(_ data: Data) -> Bool {
        var iterator = data.lazy.filter { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }.makeIterator()
        guard let first = iterator.next(), first == UInt8(ascii: "[") || first == UInt8(ascii: "{") else { return false }
        guard let second = iterator.next() else { return false }
        return second != UInt8(ascii: "]") && second != UInt8(ascii: "}")
    }

    static func startsWithMarkup(_ data: Data) -> Bool {
        data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF })
            == UInt8(ascii: "<")
    }
}
