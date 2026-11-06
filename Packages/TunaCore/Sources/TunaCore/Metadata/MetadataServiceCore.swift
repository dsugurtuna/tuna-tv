import Foundation

/// Enrichment engine behind `MetadataService`.
///
/// - Queue: `.userInitiated` jobs always start before `.background` ones, FIFO within a priority; re-enqueueing a
///   queued title at a higher priority moves it up. Cached-and-fresh titles and recent misses are never queued.
/// - Workers: `options.workers` titles at a time; TMDB calls pass a priority gate of `options.tmdbConcurrency` (4),
///   TVMaze work is strictly serial, OMDb one at a time. Everything still goes through `HostLimiter`.
/// - Resolution: provider TMDB id → details; else TMDB search(name, year), again without year → `TitleMatcher.best`
///   → details. Series without a usable TMDB key → TVMaze. A known IMDb id + OMDb key → ratings/awards/box office.
/// - Failures: a rejected TMDB key stops TMDB work until `updateKeys`; 429/5xx/network errors pause the queue
///   briefly (no retry loops: the title is simply picked up again the next time it is enqueued). Only a lookup
///   that ran and found nothing is recorded as a miss.
/// - Paused (video playing): queued work waits; direct calls (detail page, seasons, people) still run.
actor MetadataServiceCore {
    struct Options: Sendable {
        var workers = 4
        var tmdbConcurrency = 4
        /// Changed title ids are delivered in batches after this delay.
        var updateBatchInterval: TimeInterval = 1.0
        /// Store writes are debounced by this delay.
        var flushDelay: TimeInterval = 3.0
        var trendingTTL: TimeInterval = MetadataStore.trendingTTL
        var channelIndexMaxAge: TimeInterval = 7 * 86_400
        /// After a failed iptv-org download, wait this long before trying again.
        var channelRetryInterval: TimeInterval = 3_600
        /// Queue pause after a 429/5xx/network error.
        var errorCooldown: TimeInterval = 30
        /// After OMDb's daily limit is hit.
        var omdbLimitCooldown: TimeInterval = 12 * 3_600

        init() {}
    }

    init(keys: MetadataKeys, store: MetadataStore, http: HTTPClient, limiter: HostLimiter, files: FileStore,
         options: Options = Options()) {
        self.keys = keys
        self.store = store
        self.http = http
        self.limiter = limiter
        self.options = options
        self.tvmaze = TVMazeClient(http: http, limiter: limiter)
        self.iptvOrg = IPTVOrgClient(http: http, limiter: limiter, files: files)
        self.tmdbGate = MetadataSupport.Gate(limit: options.tmdbConcurrency)
        self.tvmazeGate = MetadataSupport.Gate(limit: 1)
        self.omdbGate = MetadataSupport.Gate(limit: 1)
        self.tmdb = keys.tmdb != nil ? TMDBClient(keys: keys, http: http, limiter: limiter) : nil
        self.omdb = keys.omdb.map { OMDbClient(apiKey: $0, http: http, limiter: limiter) }
    }

    private let store: MetadataStore
    private let http: HTTPClient
    private let limiter: HostLimiter
    private let options: Options
    private let tvmaze: TVMazeClient
    private let iptvOrg: IPTVOrgClient
    private let tmdbGate: MetadataSupport.Gate
    private let tvmazeGate: MetadataSupport.Gate
    private let omdbGate: MetadataSupport.Gate

    private var keys: MetadataKeys
    private var tmdb: TMDBClient?
    private var omdb: OMDbClient?
    private var tmdbBlocked = false
    private var omdbBlockedUntil: Date?
    private var omdbAttempted = Set<String>()
    private var cooldownUntil: Date?

    // Queue
    struct Job: Sendable {
        let title: Title
        let priority: RequestPriority
        let sequence: Int
    }

    struct JobQueue {
        private var items: [Job] = []
        private var head = 0

        mutating func push(_ job: Job) { items.append(job) }

        mutating func pop() -> Job? {
            guard head < items.count else { return nil }
            let job = items[head]
            head += 1
            if head >= 256, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return job
        }
    }

    private var urgentQueue = JobQueue()
    private var normalQueue = JobQueue()
    /// Live queue entries (popped or superseded entries are skipped lazily).
    private var queued: [String: (priority: RequestPriority, sequence: Int)] = [:]
    private var nextSequence = 0
    private var active = 0
    private var paused = false
    private var inFlight: [String: Task<MediaMetadata?, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var wakeTask: Task<Void, Never>?

    // Updates
    private var subscribers: [UUID: AsyncStream<[String]>.Continuation] = [:]
    private var pendingIDs: [String] = []
    private var pendingSet = Set<String>()
    private var updateTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    // Live channel index
    private var matcher: ChannelMatcher?
    private var matcherLoadedAt: Date?
    private var matcherTask: Task<ChannelMatcher?, Never>?
    private var matcherFailedAt: Date?

    // MARK: - API

    func updateKeys(_ newKeys: MetadataKeys) async {
        let tmdbChanged = newKeys.tmdb != keys.tmdb
        keys = newKeys
        tmdb = newKeys.tmdb != nil ? TMDBClient(keys: newKeys, http: http, limiter: limiter) : nil
        omdb = newKeys.omdb.map { OMDbClient(apiKey: $0, http: http, limiter: limiter) }
        tmdbBlocked = false
        omdbBlockedUntil = nil
        omdbAttempted = []
        cooldownUntil = nil
        // Misses recorded without (or with another) TMDB key deserve a new chance.
        if tmdbChanged, newKeys.tmdb != nil { await store.clearMisses() }
        pump()
    }

    func metadata(for title: Title) async -> MediaMetadata? {
        let now = Date()
        if let cached = await store.metadata(for: title.id) {
            if now.timeIntervalSince(cached.fetchedAt) >= MetadataStore.detailsTTL {
                await enqueue([title], priority: .background)
            }
            return await completingRatings(cached, titleID: title.id)
        }
        if await store.isRecentMiss(title.id, now: now) { return nil }
        guard canResolve(title) else { return nil }
        return await resolveShared(title, priority: .userInitiated)
    }

    func enqueue(_ titles: [Title], priority: RequestPriority) async {
        guard !titles.isEmpty else { return }
        let needed = await store.idsNeedingFetch(titles.map { $0.id }, now: Date())
        for title in titles where needed.contains(title.id) && canResolve(title) && inFlight[title.id] == nil {
            if let existing = queued[title.id], existing.priority >= priority { continue }
            nextSequence += 1
            queued[title.id] = (priority, nextSequence)
            let job = Job(title: title, priority: priority, sequence: nextSequence)
            if priority == .userInitiated { urgentQueue.push(job) } else { normalQueue.push(job) }
        }
        pump()
    }

    func updates() async -> AsyncStream<[String]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[String]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func season(for title: Title, tvID: Int, season: Int) async -> SeasonMetadata? {
        let cached = await store.metadata(for: title.id)
        let tmdbUsable = tmdb != nil && !tmdbBlocked
        if let cached, cached.tmdbID == nil, let showID = cached.tvmazeID {
            return await tvmazeSeason(showID: showID, season: season)
        }
        if !tmdbUsable {
            guard let showID = cached?.tvmazeID ?? (tvID > 0 ? tvID : nil) else { return nil }
            return await tvmazeSeason(showID: showID, season: season)
        }
        guard let showID = tvID > 0 ? tvID : cached?.tmdbID else { return nil }
        return await tmdbSeason(tvID: showID, season: season)
    }

    func person(id: Int) async -> PersonDetails? {
        let now = Date()
        if let cached = await store.cachedPerson(id, now: now, allowStale: false) { return cached }
        guard let tmdb, !tmdbBlocked else { return await store.cachedPerson(id, now: now, allowStale: true) }
        do {
            let person = try await tmdbGate.run(.userInitiated) { try await tmdb.person(id: id) }
            await store.storePerson(person)
            scheduleFlush()
            return person
        } catch {
            noteFailure(error, source: .tmdb)
            return await store.cachedPerson(id, now: now, allowStale: true)
        }
    }

    func trendingIDs(kind: TitleKind) async -> [Int] {
        guard let tmdb, !tmdbBlocked else { return [] }
        let cached = await store.trending(kind: kind)
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < options.trendingTTL { return cached.ids }
        do {
            let ids = try await tmdbGate.run(.userInitiated) { try await tmdb.trending(kind: kind, window: "week") }
            await store.storeTrending(ids, kind: kind, at: Date())
            scheduleFlush()
            return ids
        } catch {
            noteFailure(error, source: .tmdb)
            return cached?.ids ?? []
        }
    }

    func channelMatcher() async -> ChannelMatcher? {
        let now = Date()
        if let matcher, let loadedAt = matcherLoadedAt, now.timeIntervalSince(loadedAt) < options.channelIndexMaxAge {
            return matcher
        }
        if let running = matcherTask { return await running.value ?? matcher }
        if let failedAt = matcherFailedAt, now.timeIntervalSince(failedAt) < options.channelRetryInterval { return matcher }
        let client = iptvOrg
        let maxAge = options.channelIndexMaxAge
        // Detached: decoding ~30k channels and building the index must not block this actor.
        let task = Task.detached(priority: .utility) { () -> ChannelMatcher? in
            guard let channels = try? await client.channels(maxAge: maxAge), !channels.isEmpty else { return nil }
            return ChannelMatcher(channels: channels)
        }
        matcherTask = task
        let built = await task.value
        matcherTask = nil
        if let built {
            matcher = built
            matcherLoadedAt = Date()
            matcherFailedAt = nil
        } else {
            matcherFailedAt = Date()
        }
        return built ?? matcher
    }

    func setPaused(_ paused: Bool) async {
        self.paused = paused
        if paused { signalIdleIfNeeded() } else { pump() }
    }

    /// Writes pending store changes now (e.g. when the app quits).
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        await store.flush()
    }

    /// Returns once no queued work is running (or can run: paused / cooling down). For tests and shutdown.
    func waitForIdle() async {
        if isIdle { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in idleWaiters.append(continuation) }
    }

    // MARK: - Queue

    private var isIdle: Bool { active == 0 && (paused || queued.isEmpty || coolingDown) }

    private var coolingDown: Bool {
        guard let until = cooldownUntil else { return false }
        return until > Date()
    }

    private func canResolve(_ title: Title) -> Bool {
        (tmdb != nil && !tmdbBlocked) || title.kind == .series
    }

    private func pump() {
        if !paused {
            if coolingDown, let until = cooldownUntil {
                scheduleWake(at: until)
            } else {
                cooldownUntil = nil
                while active < max(1, options.workers), let job = nextJob() {
                    active += 1
                    Task { await self.work(job) }
                }
            }
        }
        signalIdleIfNeeded()
    }

    private func nextJob() -> Job? {
        while let job = urgentQueue.pop() ?? normalQueue.pop() {
            guard let entry = queued[job.title.id], entry.sequence == job.sequence else { continue }
            queued[job.title.id] = nil
            return job
        }
        return nil
    }

    private func work(_ job: Job) async {
        let needed = await store.idsNeedingFetch([job.title.id], now: Date())
        if needed.contains(job.title.id), canResolve(job.title) {
            _ = await resolveShared(job.title, priority: job.priority)
        }
        active -= 1
        pump()
    }

    private func signalIdleIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func scheduleWake(at date: Date) {
        guard wakeTask == nil else { return }
        let delay = max(0.05, date.timeIntervalSinceNow)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.wake()
        }
    }

    private func wake() {
        wakeTask = nil
        pump()
    }

    // MARK: - Resolution

    private enum Lookup {
        case found(MediaMetadata)
        case notFound
        case unavailable
    }

    /// One fetch per title at a time; concurrent callers share it.
    private func resolveShared(_ title: Title, priority: RequestPriority) async -> MediaMetadata? {
        if let running = inFlight[title.id] { return await running.value }
        let task = Task { await self.resolve(title, priority: priority) }
        inFlight[title.id] = task
        let result = await task.value
        inFlight[title.id] = nil
        return result
    }

    private func resolve(_ title: Title, priority: RequestPriority) async -> MediaMetadata? {
        switch await lookup(title, priority: priority) {
        case .found(let metadata):
            let merged = await withOMDb(metadata, priority: priority)
            await store.store(merged, for: title.id)
            publish(title.id)
            scheduleFlush()
            return merged
        case .notFound:
            await store.markMiss(title.id)
            scheduleFlush()
            return nil
        case .unavailable:
            return nil
        }
    }

    private func lookup(_ title: Title, priority: RequestPriority) async -> Lookup {
        if let tmdb, !tmdbBlocked {
            do {
                if let metadata = try await lookupTMDB(title, client: tmdb, priority: priority) { return .found(metadata) }
                return .notFound
            } catch {
                noteFailure(error, source: .tmdb)
                // A rejected key leaves TVMaze for series; anything else is retried another time.
                guard tmdbBlocked, title.kind == .series else { return .unavailable }
            }
        }
        guard title.kind == .series else { return .unavailable }
        let client = tvmaze
        let query = Self.searchQuery(for: title.name, year: title.year)
        let year = title.year
        do {
            let show = try await tvmazeGate.run(priority) { try await client.show(named: query, year: year) }
            return show.map { .found($0) } ?? .notFound
        } catch {
            noteFailure(error, source: .tvmaze)
            return .unavailable
        }
    }

    private func lookupTMDB(_ title: Title, client: TMDBClient, priority: RequestPriority) async throws -> MediaMetadata? {
        let kind = title.kind
        if let id = title.providerTMDBID, id > 0 {
            do {
                return try await tmdbGate.run(priority) { try await client.details(id: id, kind: kind) }
            } catch TunaError.http(let status, _) where status == 404 {
                // The provider's id is wrong (or of the other kind): fall back to a search.
            }
        }
        let query = Self.searchQuery(for: title.name, year: title.year)
        guard !query.isEmpty else { return nil }
        let year = title.year
        let first = try await tmdbGate.run(priority) { try await client.search(query, kind: kind, year: year) }
        var match = TitleMatcher.best(title: query, year: year, candidates: first)
        if match == nil, year != nil {
            let second = try await tmdbGate.run(priority) { try await client.search(query, kind: kind, year: nil) }
            var seen = Set(first.map { $0.id })
            let all = first + second.filter { seen.insert($0.id).inserted }
            match = TitleMatcher.best(title: query, year: year, candidates: all)
            if match == nil, kind == .series {
                // Providers often tag a series with the year of its latest season.
                match = TitleMatcher.best(title: query, year: nil, candidates: all)
            }
        }
        if match == nil, let year, first.count == 1, first[0].year == year {
            // A year-filtered search with exactly one hit: TMDB also matches translated/alternative titles.
            match = first[0]
        }
        guard let match else { return nil }
        let id = match.id
        return try await tmdbGate.run(priority) { try await client.details(id: id, kind: kind) }
    }

    private var omdbUsable: Bool {
        guard omdb != nil else { return false }
        if let until = omdbBlockedUntil, until > Date() { return false }
        return true
    }

    private func withOMDb(_ metadata: MediaMetadata, priority: RequestPriority) async -> MediaMetadata {
        guard let omdb, omdbUsable, let imdbID = metadata.imdbID?.nonEmpty else { return metadata }
        omdbAttempted.insert(imdbID)
        do {
            let ratings = try await omdbGate.run(priority) { try await omdb.ratings(imdbID: imdbID) }
            var merged = metadata
            if let value = ratings.imdb { merged.imdbRating = value }
            if let value = ratings.votes { merged.imdbVotes = value }
            if let value = ratings.rottenTomatoes { merged.rottenTomatoes = value }
            if let value = ratings.metacritic { merged.metacritic = value }
            if let value = ratings.awards { merged.awards = value }
            if let value = ratings.boxOffice { merged.boxOffice = value }
            return merged
        } catch {
            noteFailure(error, source: .omdb)
            return metadata
        }
    }

    /// Detail page for a title cached without OMDb data (key added later, or the daily limit was hit): one OMDb call.
    private func completingRatings(_ cached: MediaMetadata, titleID: String) async -> MediaMetadata {
        guard omdbUsable, let imdbID = cached.imdbID?.nonEmpty, !omdbAttempted.contains(imdbID),
              cached.imdbRating == nil, cached.rottenTomatoes == nil, cached.metacritic == nil else { return cached }
        let merged = await withOMDb(cached, priority: .userInitiated)
        guard merged != cached else { return cached }
        await store.store(merged, for: titleID)
        publish(titleID)
        scheduleFlush()
        return merged
    }

    private func tmdbSeason(tvID: Int, season: Int) async -> SeasonMetadata? {
        let key = MetadataStore.seasonKey(source: .tmdb, showID: tvID, season: season)
        if let cached = await store.cachedSeason(key: key, now: Date(), allowStale: false) { return cached }
        guard let tmdb, !tmdbBlocked else { return await store.cachedSeason(key: key, now: Date(), allowStale: true) }
        do {
            let result = try await tmdbGate.run(.userInitiated) { try await tmdb.season(tvID: tvID, season: season) }
            await store.storeSeason(result, key: key, at: Date())
            scheduleFlush()
            return result
        } catch {
            noteFailure(error, source: .tmdb)
            return await store.cachedSeason(key: key, now: Date(), allowStale: true)
        }
    }

    private func tvmazeSeason(showID: Int, season: Int) async -> SeasonMetadata? {
        let key = MetadataStore.seasonKey(source: .tvmaze, showID: showID, season: season)
        if let cached = await store.cachedSeason(key: key, now: Date(), allowStale: false) { return cached }
        let client = tvmaze
        do {
            let seasons = try await tvmazeGate.run(.userInitiated) { try await client.episodes(showID: showID) }
            let now = Date()
            for item in seasons {
                await store.storeSeason(item, key: MetadataStore.seasonKey(source: .tvmaze, showID: showID, season: item.seasonNumber), at: now)
            }
            scheduleFlush()
            return seasons.first(where: { $0.seasonNumber == season })
        } catch {
            noteFailure(error, source: .tvmaze)
            return await store.cachedSeason(key: key, now: Date(), allowStale: true)
        }
    }

    private func noteFailure(_ error: Error, source: MetadataSource) {
        let failure = error as? TunaError
        switch failure {
        case .unauthorized?:
            if source == .tmdb, !tmdbBlocked {
                tmdbBlocked = true
                TunaLog.shared.log(MetadataSupport.logCategory, "TMDB key rejected; TMDB lookups stop until the key changes")
            } else if source == .omdb {
                omdbBlockedUntil = .distantFuture
                TunaLog.shared.log(MetadataSupport.logCategory, "OMDb key rejected; OMDb lookups stop until the key changes")
            }
        case .http(let status, _)? where status == 429 && source == .omdb:
            omdbBlockedUntil = Date().addingTimeInterval(options.omdbLimitCooldown)
            TunaLog.shared.log(MetadataSupport.logCategory, "OMDb daily limit reached")
        case .http(let status, let host)? where status == 429 || status >= 500:
            cooldownUntil = Date().addingTimeInterval(options.errorCooldown)
            TunaLog.shared.log(MetadataSupport.logCategory, "HTTP \(status) from \(host); metadata queue pauses \(Int(options.errorCooldown)) s")
        case .network(let message)?:
            if source != .omdb { cooldownUntil = Date().addingTimeInterval(options.errorCooldown) }
            TunaLog.shared.log(MetadataSupport.logCategory, "\(source.rawValue) network error: \(message)")
        case .cancelled?:
            break
        default:
            TunaLog.shared.log(MetadataSupport.logCategory, "\(source.rawValue) lookup failed: \(error)")
        }
    }

    // MARK: - Updates & persistence

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish(_ titleID: String) {
        guard !subscribers.isEmpty else { return }
        if pendingSet.insert(titleID).inserted { pendingIDs.append(titleID) }
        guard updateTask == nil else { return }
        let interval = max(0, options.updateBatchInterval)
        updateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            await self?.deliverUpdates()
        }
    }

    private func deliverUpdates() {
        updateTask = nil
        guard !pendingIDs.isEmpty else { return }
        let batch = pendingIDs
        pendingIDs = []
        pendingSet = []
        for continuation in subscribers.values { continuation.yield(batch) }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = max(0, options.flushDelay)
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushScheduled()
        }
    }

    private func flushScheduled() async {
        flushTask = nil
        await store.flush()
    }

    // MARK: - Query cleaning

    /// Search text for a curated title name: bracketed parts, a trailing copy of the title's year, quality tags and
    /// season markers ("S01") are dropped; scene-style dots become spaces. Real numbers in names stay
    /// ("Blade Runner 2049", "1917").
    static func searchQuery(for name: String, year: Int?) -> String {
        var text = ""
        var depth = 0
        for character in name {
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
                text.append(" ")
            } else if depth == 0 {
                text.append(character)
            }
        }
        if !text.contains(" ") {
            text = text.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        var words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while words.count > 1, let last = words.last, isTrailingTag(last, year: year) { words.removeLast() }
        let result = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -:|·–"))
        return result.isEmpty ? name.tunaTrimmed : result
    }

    static let qualityTags: Set<String> = ["4k", "uhd", "fhd", "hd", "sd", "hdr", "hdr10", "dv", "hevc", "x265", "x264", "h265",
                                           "h264", "1080p", "720p", "2160p", "multi", "dual", "vostfr", "subbed", "dubbed", "remux",
                                           "bluray", "webrip", "web-dl", "webdl"]

    static func isTrailingTag(_ word: String, year: Int?) -> Bool {
        let lower = word.lowercased()
        if let year, lower == String(year) { return true }
        if qualityTags.contains(lower) { return true }
        // "S01", "S1", "S01E02"
        let characters = Array(lower)
        guard characters.count >= 2, characters[0] == "s", characters[1].isNumber else { return false }
        var index = 1
        while index < characters.count, characters[index].isNumber { index += 1 }
        if index == characters.count { return index <= 3 }
        guard characters[index] == "e", index + 1 < characters.count else { return false }
        return characters[(index + 1)...].allSatisfy { $0.isNumber }
    }
}
