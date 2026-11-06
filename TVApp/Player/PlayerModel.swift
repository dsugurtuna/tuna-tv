import SwiftUI
import Observation
import CoreGraphics
import TunaCore

// =====================================================================================================
// PLAYER MODEL (Apple TV port of the Mac player model). One engine instance for the whole app (AetherEngine
// via TunaPlaybackEngine). Every open goes through TVModel.streamGate (one ticket per open); zaps are
// debounced; failed loads are NEVER retried automatically (see docs/ARCHITECTURE.md "Provider Safety Spec").
// =====================================================================================================

@MainActor
@Observable
final class PlayerModel {
    enum Content: Equatable {
        case movie(Title, Variant)
        case episode(Title, Variant, RawEpisode)
        case channel(Channel, Variant)
        case catchup(Channel, Variant, Program)

        var variant: Variant {
            switch self {
            case .movie(_, let v), .episode(_, let v, _), .channel(_, let v), .catchup(_, let v, _): return v
            }
        }

        var isLive: Bool { if case .channel = self { return true } else { return false } }

        var displayTitle: String {
            switch self {
            case .movie(let t, _): return t.name
            case .episode(let t, _, _): return t.name
            case .channel(let c, _): return c.name
            case .catchup(_, _, let p): return p.title
            }
        }

        var displaySubtitle: String? {
            switch self {
            case .movie(let t, _): return t.year.map(String.init)
            case .episode(_, _, let e): return "S\(e.season) · E\(e.episode) · \(e.title)"
            case .channel: return nil
            case .catchup(let c, _, _): return c.name
            }
        }
    }

    enum Status: Equatable {
        case idle
        case opening
        case playing
        case paused
        case buffering
        case reconnecting
        case ended
        case failed(message: String, retryAfter: Date?)

        var isActive: Bool {
            switch self {
            case .opening, .playing, .paused, .buffering, .reconnecting: return true
            default: return false
            }
        }
    }

    struct TrackOption: Identifiable, Hashable {
        let id: Int
        var name: String
        var language: String?
        var detail: String?
        var isSelected: Bool
    }

    /// "Nerd stats" for the tech panel and quality verification.
    struct TechInfo: Hashable {
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var hdr: String?
        var frameRate: Double?
        var bitrateMbps: Double?
        var decoder: String?
        var audioCodec: String?
        var audioChannels: Int?
        var route: String?
        var bufferSeconds: Double?
        var droppedFrames: Int?
        var engineVersion: String?

        var resolutionLabel: String? {
            guard let w = width, let h = height, w > 0, h > 0 else { return nil }
            return "\(w)×\(h)"
        }
    }

    struct UpNext: Equatable {
        var title: Title
        var episode: RawEpisode
        var variant: Variant
    }

    unowned let app: TVModel

    private(set) var content: Content?
    private(set) var status: Status = .idle
    /// Full-window player visible.
    var isPresented = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLive = false
    /// Seconds behind the live edge (timeshift).
    private(set) var behindLive: Double = 0
    private(set) var audioTracks: [TrackOption] = []
    private(set) var subtitleTracks: [TrackOption] = []
    private(set) var tech = TechInfo()
    /// Current subtitle line(s) to draw over the video.
    private(set) var subtitleText: String?
    private(set) var upNext: UpNext?
    private(set) var upNextCountdown: Int?
    var volume: Double = 1
    var isMuted = false
    /// Channel currently "previewed" in the zapping strip before the debounce fires.
    private(set) var pendingZap: Channel?

    // MARK: Extra state for the player UI (owner: player; additive, not part of the fixed contract)

    /// True once the single engine exists, so the video surface can be mounted.
    private(set) var hasEngineSurface = false
    /// True once this session's first picture is up (the loading cover comes off).
    private(set) var hasVideoFrame = false
    /// Cues to draw right now (text and positioned bitmaps).
    private(set) var subtitleCues: [PlayerSubtitleCue] = []
    /// Displayed width / height of the source picture, for placing bitmap subtitles.
    private(set) var videoAspect: Double?
    /// Open stream connections (StreamGate tickets) held by the player: 0 or 1.
    private(set) var connectionsInUse = 0
    /// The failure behind `.failed`, for the error card.
    private(set) var failure: PlayerFailure?
    /// Live: whether playback sits at the live edge.
    private(set) var isAtLiveEdge = true

    // MARK: Session bookkeeping (not observed)

    @ObservationIgnored private var token = 0
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var currentOperation: Task<Void, Never>?
    @ObservationIgnored private var ticket: StreamTicket?
    /// Engine callbacks are accepted only while the engine is loading/playing the current session.
    @ObservationIgnored private var engineBound = false
    @ObservationIgnored private var reachedPlayback = false
    @ObservationIgnored private var resumeTarget: Double?
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var qualityRecorded = false
    @ObservationIgnored private var failureRecorded = false
    @ObservationIgnored private var watchStart: Date?
    @ObservationIgnored private var watchedSeconds: Double = 0
    @ObservationIgnored private var zapTask: Task<Void, Never>?
    @ObservationIgnored private var lastChannel: Channel?
    @ObservationIgnored private var previousChannel: Channel?
    @ObservationIgnored private var zapCache: (id: ObjectIdentifier, stamp: Date, list: [Channel])?
    @ObservationIgnored private var upNextLookup: Task<Void, Never>?
    @ObservationIgnored private var upNextLookupStarted = false
    @ObservationIgnored private var upNextCandidate: UpNext?
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var upNextTimer: Task<Void, Never>?
    @ObservationIgnored private var preemptHandlerRegistered = false
    /// Account-level cooldowns after a provider refused/limited a stream: no new open on that provider until then.
    @ObservationIgnored private var providerCooldowns: [ProviderID: (until: Date, failure: PlayerFailure)] = [:]

    init(app: TVModel) {
        self.app = app
        engine.owner = self
        trackUserControls()
    }

    private var engine: TunaPlaybackEngine { TunaPlaybackEngine.shared }

    var canRetry: Bool {
        guard case .failed(_, let retryAfter) = status, let retryAfter else { return false }
        return Date() >= retryAfter
    }

    func play(_ content: Content, resumeAt: Double?) {
        zapTask?.cancel()
        zapTask = nil
        pendingZap = nil
        if let current = self.content, current == content {
            // Same item already opening/playing: never reconnect, at most seek.
            if status.isActive {
                isPresented = true
                if let resumeAt, !current.isLive, abs(resumeAt - position) > 5 { seek(to: resumeAt) }
                return
            }
            // Same item still cooling down after a failure: show the card, do not ask the provider again.
            if case .failed(_, let retryAfter) = status, let retryAfter, retryAfter > Date() {
                isPresented = true
                return
            }
        }
        begin(content, resumeAt: resumeAt)
    }

    /// Debounced (settings.playback.zapDebounce, default 0.6 s): only the last selection opens a stream.
    func zap(to channel: Channel) {
        if pendingZap == nil, let current = currentChannel, current.id == channel.id, status.isActive {
            return
        }
        pendingZap = channel
        zapTask?.cancel()
        let delay = max(0.25, app.settings.playback.zapDebounce)
        zapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.pendingZap?.id == channel.id else { return }
            self.zapTask = nil
            self.pendingZap = nil
            if let current = self.currentChannel, current.id == channel.id, self.status.isActive { return }
            guard let variant = channel.defaultVariant else { return }
            self.play(.channel(channel, variant), resumeAt: nil)
        }
    }

    func zapNext() { stepChannel(by: 1) }
    func zapPrevious() { stepChannel(by: -1) }

    func recallLastChannel() {
        guard let previous = previousChannel else { return }
        zap(to: previous)
    }

    func togglePlayPause() {
        switch status {
        case .ended:
            // `.ended` is terminal in the engine: replaying is a new (user-initiated) load.
            if let content, !content.isLive { begin(content, resumeAt: nil) }
        case .playing, .paused, .buffering, .reconnecting:
            engine.togglePlayPause()
        default:
            break
        }
    }

    func seek(to seconds: Double) {
        guard let content else { return }
        var target = max(0, seconds)
        if !content.isLive, duration > 0 { target = min(target, max(0, duration - 1)) }
        if status == .ended, !content.isLive {
            begin(content, resumeAt: target)
            return
        }
        guard status.isActive else { return }
        position = target
        if upNext != nil, !content.isLive, duration - target > 35 { hideUpNext() }
        Task { [weak self] in await self?.engine.seek(to: target) }
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        guard content != nil else { return }
        seek(to: position + seconds)
    }

    func goLive() {
        guard isLive, status.isActive else { return }
        behindLive = 0
        isAtLiveEdge = true
        Task { [weak self] in await self?.engine.goLive() }
    }

    /// Stops the engine, waits for it to be idle, closes the StreamGate ticket, saves progress.
    func stop() {
        zapTask?.cancel()
        zapTask = nil
        pendingZap = nil
        resetUpNext(dismissed: true)
        endCurrentSession()
        token += 1
        status = .idle
        updateNowPlaying()
        enqueue(cancellingCurrent: true) { [weak self] in
            await self?.releaseTicket()
        }
    }

    /// Manual retry only (respects `retryAfter`).
    func retry() {
        guard canRetry, let content else { return }
        let resume: Double? = content.isLive ? nil : (reachedPlayback ? position : resumeTarget)
        begin(content, resumeAt: resume)
    }

    func selectAudio(_ id: Int) {
        guard status.isActive else { return }
        engine.selectAudio(id: id)
        audioTracks = audioTracks.map { track in
            var copy = track
            copy.isSelected = track.id == id
            return copy
        }
    }

    func selectSubtitle(_ id: Int?) {
        guard status.isActive else { return }
        engine.selectSubtitle(id: id)
        subtitleTracks = subtitleTracks.map { track in
            var copy = track
            copy.isSelected = track.id == id
            return copy
        }
        if id == nil {
            subtitleCues = []
            subtitleText = nil
        }
    }

    func switchVariant(_ variant: Variant) {
        guard let content, variant.id != content.variant.id else { return }
        switch content {
        case .movie(let title, _):
            begin(.movie(title, variant), resumeAt: currentResumePosition)
        case .channel(let channel, _):
            begin(.channel(channel, variant), resumeAt: nil)
        case .catchup(let channel, _, let program):
            begin(.catchup(channel, variant, program), resumeAt: nil)
        case .episode:
            // An episode belongs to one provider series record; other records number their episodes differently.
            return
        }
    }

    func playUpNext() {
        guard let next = upNext ?? upNextCandidate else { return }
        let saved = app.progress(forEpisode: next.episode.ref)
        let resume: Double? = saved.flatMap { progress in
            (progress.isFinished || progress.position < 30) ? nil : progress.position
        }
        begin(.episode(next.title, next.variant, next.episode), resumeAt: resume)
    }

    func cancelUpNext() {
        resetUpNext(dismissed: true)
    }

    /// Hide the player UI and stop playback.
    func dismiss() {
        stop()
        isPresented = false
        content = nil
        isLive = false
        failure = nil
    }
}

// MARK: - Public helpers for the player UI (additive)

extension PlayerModel {
    /// The channel on screen (live or catch-up).
    var currentChannel: Channel? {
        switch content {
        case .channel(let channel, _)?: return channel
        case .catchup(let channel, _, _)?: return channel
        default: return nil
        }
    }

    /// Showcase channels in zapping order: channel number, then name.
    var zapChannels: [Channel] {
        let library = app.library
        let identity = ObjectIdentifier(library)
        if let cache = zapCache, cache.id == identity, cache.stamp == library.generatedAt {
            return cache.list
        }
        let list = library.liveShowcase.sorted(by: Self.channelOrder)
        zapCache = (identity, library.generatedAt, list)
        return list
    }

    /// Other versions the error card can offer ("Try another version"), next best first.
    var alternativeVariants: [Variant] {
        guard let content else { return [] }
        let all: [Variant]
        switch content {
        case .movie(let title, _): all = title.variants
        case .channel(let channel, _), .catchup(let channel, _, _): all = channel.variants
        case .episode: return []
        }
        guard all.count > 1 else { return [] }
        let currentIndex = all.firstIndex(where: { $0.id == content.variant.id }) ?? -1
        return (1..<all.count).map { all[(currentIndex + $0 + all.count) % all.count] }
            .filter { $0.id != content.variant.id }
    }

    /// Every version of the current item, for the versions menu.
    var versions: [Variant] {
        switch content {
        case .movie(let title, _)?: return title.variants
        case .channel(let channel, _)?: return channel.variants
        case .catchup(let channel, _, _)?: return channel.variants
        default: return []
        }
    }

    func tryAnotherVersion() {
        guard let next = alternativeVariants.first else { return }
        switchVariant(next)
    }

    /// Simultaneous streams the current provider allows (for the Provider Shield line).
    var connectionLimit: Int {
        guard let content else { return 1 }
        let providerID = content.variant.ref.providerID
        guard let status = app.providerStatus.first(where: { $0.id == providerID }) else { return 1 }
        return status.config.effectiveMaxStreams(account: status.account)
    }

    var supportsScrubPreview: Bool { !isLive && engine.supportsScrubPreview }

    /// Seek-bar preview decoded from bytes the session already holds (never a second connection).
    func scrubPreview(at seconds: Double) async -> CGImage? {
        guard supportsScrubPreview else { return nil }
        return await engine.scrubPreview(at: seconds)
    }

    func resume() {
        switch status {
        case .paused: engine.play()
        case .ended: togglePlayPause()
        default: break
        }
    }

    func pause() {
        guard status.isActive else { return }
        engine.pause()
    }

    /// Media key "next": next channel (live) or the next episode.
    func remoteNext() {
        if isLive {
            zapNext()
        } else if upNext != nil || upNextCandidate != nil {
            playUpNext()
        }
    }

    /// Media key "previous": previous channel (live) or back to the start.
    func remotePrevious() {
        if isLive {
            zapPrevious()
        } else {
            seek(to: 0)
        }
    }
}

// MARK: - Engine callbacks (called by TunaPlaybackEngine on the main actor)

extension PlayerModel {
    func engineStatusChanged(_ engineStatus: PlayerEngineStatus) {
        guard engineBound else { return }
        switch engineStatus {
        case .idle:
            return
        case .loading:
            if status != .opening { status = .opening }
        case .playing:
            if !reachedPlayback {
                reachedPlayback = true
                resumeTarget = nil
            }
            if status != .playing { status = .playing }
        case .paused:
            if status != .paused { status = .paused }
        case .buffering:
            if status != .buffering { status = .buffering }
        case .reconnecting:
            if status != .reconnecting { status = .reconnecting }
        case .ended:
            handleEnded()
        case .failed(let failure):
            engineBound = false
            applyFailure(failure)
            // Tear down on a later turn (this may run inside an engine callback), then close the ticket.
            enqueue(cancellingCurrent: false) { [weak self] in
                await self?.teardownAfterFailure()
            }
            return
        }
        updateWatchClock()
        updateNowPlaying()
    }

    func engineTimeChanged(position newPosition: Double, duration newDuration: Double, behindLive newBehind: Double, atLiveEdge: Bool) {
        guard engineBound else { return }
        if newDuration.isFinite, newDuration > 0, abs(newDuration - duration) >= 0.5 { duration = newDuration }
        // Until playback has really started the clock may read 0: keep the resume point on screen (and in progress).
        guard reachedPlayback, newPosition.isFinite else { return }
        if abs(newPosition - position) >= 0.25 { position = newPosition }
        if isLive {
            let behind = max(0, newBehind)
            if abs(behind - behindLive) >= 0.5 || (behind == 0 && behindLive != 0) { behindLive = behind }
            if isAtLiveEdge != atLiveEdge { isAtLiveEdge = atLiveEdge }
        }
        if Date().timeIntervalSince(lastProgressSave) >= 10 {
            saveProgress()
            updateNowPlaying()
        }
        evaluateUpNext(ended: false)
    }

    func engineSnapshotChanged(audio: [TrackOption], subtitles: [TrackOption], tech newTech: TechInfo, videoAspect aspect: Double?) {
        guard engineBound else { return }
        if audio != audioTracks { audioTracks = audio }
        if subtitles != subtitleTracks { subtitleTracks = subtitles }
        if newTech != tech { tech = newTech }
        if aspect != videoAspect { videoAspect = aspect }
        recordVerifiedQualityIfNeeded()
    }

    func engineSubtitlesChanged(_ cues: [PlayerSubtitleCue]) {
        guard engineBound else { return }
        subtitleCues = cues
        let text = cues.compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
        let newText: String? = text.isEmpty ? nil : text
        if newText != subtitleText { subtitleText = newText }
    }

    func engineFirstFrame() {
        guard engineBound, !hasVideoFrame else { return }
        hasVideoFrame = true
    }

    func engineSurfaceReady() {
        if !hasEngineSurface { hasEngineSurface = true }
    }

}

// MARK: - Session pipeline (private)

private extension PlayerModel {
    func isCurrent(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    /// Serializes every open/teardown: an operation starts only after the previous one finished, so the old
    /// ticket is always closed (after the engine stopped) before a new one is requested.
    func enqueue(cancellingCurrent: Bool, _ operation: @escaping @MainActor () async -> Void) {
        if cancellingCurrent { currentOperation?.cancel() }
        let previous = pipeline
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        pipeline = task
        if cancellingCurrent { currentOperation = task }
    }

    /// Starts a user-initiated session (play, retry, version switch, up next, zap).
    func begin(_ content: Content, resumeAt: Double?) {
        zapTask?.cancel()
        zapTask = nil
        pendingZap = nil
        endCurrentSession()
        token += 1
        let token = self.token

        self.content = content
        status = .opening
        failure = nil
        isLive = content.isLive
        position = resumeAt ?? 0
        duration = Self.declaredDuration(of: content)
        behindLive = 0
        isAtLiveEdge = true
        audioTracks = []
        subtitleTracks = []
        var freshTech = TechInfo()
        freshTech.engineVersion = TunaPlaybackEngine.engineLabel
        tech = freshTech
        subtitleText = nil
        subtitleCues = []
        hasVideoFrame = false
        videoAspect = nil
        resetUpNext(dismissed: false)
        resumeTarget = resumeAt
        reachedPlayback = false
        qualityRecorded = false
        failureRecorded = false
        lastProgressSave = Date()
        if case .channel(let channel, _) = content { noteChannel(channel) }
        isPresented = true

        PlayerNowPlaying.shared.attach(self)
        updateNowPlaying()
        enqueue(cancellingCurrent: true) { [weak self] in
            await self?.open(content, resumeAt: resumeAt, token: token)
        }
    }

    /// Saves progress / watch time of the outgoing session and stops the engine synchronously.
    func endCurrentSession() {
        saveProgress()
        flushWatchedTime()
        engineBound = false
        engine.stopNow()
        upNextTimer?.cancel()
        upNextTimer = nil
        upNextLookup?.cancel()
        upNextLookup = nil
    }

    func open(_ content: Content, resumeAt: Double?, token: Int) async {
        // 1. The previous session's engine is already stopped; give its connection back first.
        await releaseTicket()
        guard isCurrent(token) else { return }

        // 2. Nothing to open in the demo / check build / without a provider (the UI still renders).
        if app.isDemo {
            applyFailure(.demo)
            return
        }
        guard TunaPlaybackEngine.isAvailable else {
            applyFailure(PlayerFailure(kind: .notIncluded, message: TunaPlaybackEngine.unavailableMessage))
            return
        }
        let ref = Self.streamRef(for: content)
        guard let session = app.session(for: ref.providerID) else {
            applyFailure(.noProvider)
            return
        }
        if let cooldown = providerCooldowns[ref.providerID] {
            if cooldown.until > Date() {
                showCooldown(cooldown.failure, until: cooldown.until)
                return
            }
            providerCooldowns[ref.providerID] = nil
        }

        // 3. Resolve the URL and the session's stream headers (no network).
        let url = await Self.resolveURL(for: content, session: session)
        let headers = await session.streamHeaders(for: content.variant.raw)
        guard isCurrent(token) else { return }
        guard let url else {
            applyFailure(.missingURL)
            return
        }

        // 4. One ticket per stream connection (StreamGate paces opens and enforces the connection cap).
        let gate = app.streamGate
        registerPreemptHandlerIfNeeded(gate)
        do {
            let newTicket = try await gate.open(ref, preempt: true)
            guard isCurrent(token) else {
                await gate.close(newTicket)
                return
            }
            ticket = newTicket
            connectionsInUse = 1
        } catch {
            guard isCurrent(token) else { return }
            applyFailure(Self.gateFailure(error))
            return
        }

        // 5. Load. Status, tracks and failures arrive through the engine callbacks; nothing is retried here.
        engineBound = true
        let source = makeSource(for: content, url: url, headers: headers, resumeAt: resumeAt)
        _ = await engine.load(source)
    }

    /// Closes the ticket once the engine is idle. Safe to call repeatedly.
    func releaseTicket() async {
        guard let held = ticket else { return }
        ticket = nil
        await engine.waitUntilIdle()
        await app.streamGate.close(held)
        if ticket == nil, connectionsInUse != 0 { connectionsInUse = 0 }
    }

    func teardownAfterFailure() async {
        if !engineBound { engine.stopNow() }
        await releaseTicket()
    }

    func applyFailure(_ failure: PlayerFailure) {
        engineBound = false
        saveProgress()
        flushWatchedTime()
        self.failure = failure
        let retryAfter = failure.cooldown.map { Date().addingTimeInterval($0) }
        status = .failed(message: failure.message, retryAfter: retryAfter)
        if let content {
            if failure.countsAgainstVariant, !failureRecorded {
                failureRecorded = true
                app.recordFailure(variantID: content.variant.id)
            }
            if let retryAfter, Self.coolsDownProvider(failure.kind) {
                providerCooldowns[Self.streamRef(for: content).providerID] = (retryAfter, failure)
            }
        }
        upNextTimer?.cancel()
        upNextTimer = nil
        if upNextCountdown != nil { upNextCountdown = nil }
        updateNowPlaying()
    }

    /// The provider is still cooling down from an earlier refusal: show that, without contacting it.
    func showCooldown(_ failure: PlayerFailure, until: Date) {
        engineBound = false
        self.failure = failure
        status = .failed(message: failure.message, retryAfter: until)
        updateNowPlaying()
    }

    static func coolsDownProvider(_ kind: PlayerFailure.Kind) -> Bool {
        switch kind {
        case .rateLimited, .refused, .streamLimit, .providerPaused: return true
        default: return false
        }
    }

    func handleEnded() {
        if status != .ended { status = .ended }
        if !isLive, duration > 0 { position = duration }
        saveProgress()
        updateWatchClock()
        updateNowPlaying()
        evaluateUpNext(ended: true)
    }

    func registerPreemptHandlerIfNeeded(_ gate: StreamGate) {
        guard !preemptHandlerRegistered else { return }
        preemptHandlerRegistered = true
        Task {
            await gate.setPreemptHandler { [weak self] preempted in
                await self?.handlePreempt(preempted)
            }
        }
    }

    /// Another open needs our ticket: stop the engine first, then hand the ticket back.
    func handlePreempt(_ preempted: StreamTicket) async {
        if let held = ticket, held.id == preempted.id {
            ticket = nil
            engineBound = false
            engine.stopNow()
            connectionsInUse = 0
            if status.isActive {
                applyFailure(PlayerFailure(kind: .streamLimit,
                                           message: "Playback stopped because another stream started on this provider.",
                                           cooldown: 5))
            }
        }
        await app.streamGate.close(preempted)
    }

    func makeSource(for content: Content, url: URL, headers: [String: String], resumeAt: Double?) -> PlayerSource {
        let settings = app.settings
        let kind: PlayerSource.Kind
        switch content {
        case .channel:
            let minutes = settings.playback.liveTimeshiftMinutes
            kind = .live(isHLS: url.pathExtension.lowercased() == "m3u8",
                         dvrWindowSeconds: minutes > 0 ? Double(minutes) * 60 : nil)
        case .catchup(_, _, let program):
            kind = .catchup(durationSeconds: max(0, program.duration))
        case .movie, .episode:
            let start: Double? = (resumeAt ?? 0) > 1 ? resumeAt : nil
            kind = .vod(startPosition: start)
        }
        return PlayerSource(url: url,
                            headers: headers,
                            kind: kind,
                            audioLanguages: settings.content.preferredAudioLanguages,
                            subtitleLanguages: settings.content.preferredSubtitleLanguages)
    }

    static func streamRef(for content: Content) -> StreamRef {
        if case .episode(_, _, let episode) = content { return episode.ref }
        return content.variant.ref
    }

    static func resolveURL(for content: Content, session: ProviderSession) async -> URL? {
        switch content {
        case .movie(_, let variant):
            return await session.streamURL(for: variant.ref,
                                           containerExtension: variant.raw.containerExtension,
                                           directURL: variant.raw.directURL)
        case .episode(_, _, let episode):
            return await session.streamURL(for: episode.ref,
                                           containerExtension: episode.containerExtension,
                                           directURL: nil)
        case .channel(_, let variant):
            return await session.streamURL(for: variant.ref, containerExtension: nil, directURL: variant.raw.directURL)
        case .catchup(_, let variant, let program):
            return await session.catchupURL(for: variant.ref, program: program)
        }
    }

    static func declaredDuration(of content: Content) -> Double {
        switch content {
        case .catchup(_, _, let program): return max(0, program.duration)
        case .episode(_, _, let episode): return Double(episode.durationSeconds ?? 0)
        case .movie, .channel: return 0
        }
    }

    static func gateFailure(_ error: Error) -> PlayerFailure {
        if let tuna = error as? TunaError {
            switch tuna {
            case .streamRateLimited(let retryAfter):
                return PlayerFailure(kind: .streamLimit, message: tuna.userMessage,
                                     detail: tuna.description, cooldown: max(5, retryAfter))
            case .paused(let until, _):
                return PlayerFailure(kind: .providerPaused, message: tuna.userMessage,
                                     detail: tuna.description, cooldown: max(5, until.timeIntervalSinceNow))
            case .http(let status, _):
                return PlayerFailure.http(status, detail: tuna.description)
            default:
                return PlayerFailure(kind: .unknown, message: tuna.userMessage, detail: tuna.description, cooldown: 10)
            }
        }
        return PlayerFailure(kind: .unknown, message: "The stream could not be started.",
                             detail: String(describing: error), cooldown: 10)
    }

    var currentResumePosition: Double? {
        if reachedPlayback { return position > 1 ? position : nil }
        return resumeTarget
    }
}

// MARK: - Progress, watch time, quality, user controls (private)

private extension PlayerModel {
    /// Movies and episodes only; only once playback really started (never overwrites a resume point with 0).
    func saveProgress() {
        guard reachedPlayback, let content, duration > 0 else { return }
        let clamped = min(max(0, position), duration)
        switch content {
        case .movie(let title, let variant):
            app.recordProgress(WatchProgress(titleID: title.id, variantID: variant.id,
                                             position: clamped, duration: duration))
        case .episode(let title, let variant, let episode):
            app.recordProgress(WatchProgress(titleID: title.id, variantID: variant.id, episodeRef: episode.ref,
                                             season: episode.season, episode: episode.episode,
                                             position: clamped, duration: duration))
        case .channel, .catchup:
            return
        }
        lastProgressSave = Date()
    }

    func updateWatchClock() {
        if status == .playing {
            if watchStart == nil { watchStart = Date() }
        } else if let start = watchStart {
            watchedSeconds += Date().timeIntervalSince(start)
            watchStart = nil
        }
    }

    func flushWatchedTime() {
        if let start = watchStart {
            watchedSeconds += Date().timeIntervalSince(start)
            watchStart = nil
        }
        defer { watchedSeconds = 0 }
        guard watchedSeconds >= 1, case .channel(let channel, _)? = content else { return }
        app.recordWatched(channel: channel, seconds: watchedSeconds)
    }

    func recordVerifiedQualityIfNeeded() {
        guard !qualityRecorded, let content, let height = tech.height, height > 0 else { return }
        qualityRecorded = true
        // Scope / anamorphic frames: judge by the width too (1920×800 is Full HD).
        let effectiveHeight = max(height, (tech.width ?? 0) * 9 / 16)
        app.recordVerifiedQuality(Quality.from(height: effectiveHeight), variantID: content.variant.id)
    }

    func noteChannel(_ channel: Channel) {
        if let last = lastChannel, last.id != channel.id { previousChannel = last }
        lastChannel = channel
    }

    func stepChannel(by step: Int) {
        let list = zapChannels
        guard !list.isEmpty else { return }
        let reference = pendingZap ?? currentChannel
        let index = reference.flatMap { channel in list.firstIndex(where: { $0.id == channel.id }) }
        let next: Int
        if let index {
            next = (index + step + list.count) % list.count
        } else {
            next = step > 0 ? 0 : list.count - 1
        }
        zap(to: list[next])
    }

    nonisolated static func channelOrder(_ lhs: Channel, _ rhs: Channel) -> Bool {
        switch (lhs.number, rhs.number) {
        case let (left?, right?) where left != right: return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Volume / mute / presentation can be set directly by any view: apply them to the engine when they change.
    func trackUserControls() {
        withObservationTracking {
            _ = self.volume
            _ = self.isMuted
            _ = self.isPresented
        } onChange: {
            Task { @MainActor [weak self] in
                self?.userControlsChanged()
            }
        }
    }

    func userControlsChanged() {
        let level = isMuted ? 0 : min(1, max(0, volume))
        engine.setVolume(Float(level))
        // Hidden without dismiss(): nothing should keep a provider connection open.
        if !isPresented, status.isActive { stop() }
        trackUserControls()
    }

    func updateNowPlaying() {
        let nowPlaying = PlayerNowPlaying.shared
        guard let content, status != .idle else {
            nowPlaying.clear()
            return
        }
        var subtitle = content.displaySubtitle
        if case .channel(let channel, _) = content {
            subtitle = app.nowPlaying(on: channel)?.title
        }
        var isEpisode = false
        if case .episode = content { isEpisode = true }
        nowPlaying.update(title: content.displayTitle,
                          subtitle: subtitle,
                          duration: duration,
                          position: position,
                          isLive: content.isLive,
                          isPlaying: status == .playing || status == .buffering,
                          canGoNext: content.isLive || isEpisode,
                          canGoPrevious: true)
    }
}

// MARK: - Up Next (private)

private extension PlayerModel {
    /// Near the end of an episode (last 30 s, or ended) find the next episode and offer it.
    func evaluateUpNext(ended: Bool) {
        guard case .episode(let title, let variant, let episode)? = content, !upNextDismissed else { return }
        guard ended || duration > 60 else { return }
        let remaining = duration - position
        if !upNextLookupStarted {
            guard ended || remaining <= 45 else { return }
            upNextLookupStarted = true
            let token = self.token
            upNextLookup = Task { [weak self] in
                guard let self else { return }
                let next = await self.findNextEpisode(after: episode, in: title, variant: variant)
                guard token == self.token, !Task.isCancelled else { return }
                self.upNextCandidate = next
                self.evaluateUpNext(ended: self.status == .ended)
            }
            return
        }
        guard upNext == nil, let candidate = upNextCandidate, ended || remaining <= 30 else { return }
        presentUpNext(candidate)
    }

    func findNextEpisode(after episode: RawEpisode, in title: Title, variant: Variant) async -> UpNext? {
        guard let info = try? await app.seriesInfo(for: title) else { return nil }
        let ordered = info.episodesBySeason.flatMap { $0.episodes }
        let index = ordered.firstIndex(where: { $0.ref == episode.ref })
            ?? ordered.firstIndex(where: { $0.season == episode.season && $0.episode == episode.episode })
        guard let index, index + 1 < ordered.count else { return nil }
        return UpNext(title: title, episode: ordered[index + 1], variant: variant)
    }

    func presentUpNext(_ next: UpNext) {
        upNext = next
        guard app.settings.playback.autoplayNextEpisode else {
            upNextCountdown = nil
            return
        }
        let seconds = max(3, app.settings.playback.upNextCountdown)
        upNextCountdown = seconds
        let token = self.token
        upNextTimer?.cancel()
        upNextTimer = Task { [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, token == self.token, self.upNext != nil else { return }
                remaining -= 1
                self.upNextCountdown = remaining
            }
            guard let self, !Task.isCancelled, token == self.token, self.upNext != nil else { return }
            self.playUpNext()
        }
    }

    func hideUpNext() {
        upNextTimer?.cancel()
        upNextTimer = nil
        if upNext != nil { upNext = nil }
        if upNextCountdown != nil { upNextCountdown = nil }
    }

    func resetUpNext(dismissed: Bool) {
        hideUpNext()
        upNextDismissed = dismissed
        if !dismissed {
            upNextLookup?.cancel()
            upNextLookup = nil
            upNextLookupStarted = false
            upNextCandidate = nil
        }
    }
}
