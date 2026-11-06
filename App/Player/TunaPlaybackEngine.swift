import Foundation
import CoreGraphics

// =====================================================================================================
// TunaPlaybackEngine: the ONE playback engine of the app (provider safety: one engine, one connection).
//
// - TunaTV target (TUNA_ENGINE): wraps exactly one AetherEngine instance (created lazily on the first real
//   load, never for the demo). Every LoadOptions block is provider-safe (one request at a time, no background
//   scrub previews, no I-frame playlist, no Atmos confirmation reader). Failed loads are never retried here.
//   A 12 s stall watchdog and a bounded live-recovery policy cap the engine's own reconnect ladders.
// - TunaTVCheck target: a stub with the same API that reports "Playback engine not included in this build".
//
// The wrapper never resolves URLs and never touches StreamGate: PlayerModel does both, and calls `load(_:)`
// only while it holds a ticket. Engine state flows to PlayerModel through Combine sinks (`owner` callbacks).
// =====================================================================================================

#if TUNA_ENGINE
import AetherEngine
import AVFoundation
import Combine

@MainActor
final class TunaPlaybackEngine {
    static let shared = TunaPlaybackEngine()
    static let isAvailable = true
    static let unavailableMessage = "Playback engine not included in this build"
    nonisolated static var engineLabel: String { "AetherEngine \(AetherEngine.version)" }

    /// Receives every status/time/track/subtitle update. Only the active session's events are forwarded.
    weak var owner: PlayerModel?

    /// The single engine instance (nil until the first real load).
    private(set) var aetherEngine: AetherEngine?
    private var pictureInPicture: TunaPictureInPicture?
    private var bag = Set<AnyCancellable>()

    // Session bookkeeping. `session` changes on every user-initiated load and on every stop, so deferred work
    // (watchdogs, recovery) can tell whether it still belongs to the stream it was armed for.
    private var session = 0
    private var active = false
    private var source: PlayerSource?
    private var failedSession = -1
    private var reachedPlayback = false
    private var awaitingStart = false

    // Watchdogs and the bounded live recovery.
    private var stallWatchdog: Task<Void, Never>?
    private var openWatchdog: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var usedInPlaceRecovery = false
    private var usedReload = false
    private var lastMotion = Date.distantPast
    private var lastClockSample: Double = 0

    // Subtitles and the coalesced track/tech snapshot.
    private var cues: [SubtitleCue] = []
    private var subtitlesOn = false
    private var shownCueIDs: [Int] = []
    private var snapshotPending = false

    private var volume: Float = 1
    private var registeredSecrets = Set<String>()

    private static let stallLimitSeconds: Double = 12
    private static let openLimitSeconds: Double = 45
    private static let inPlaceRecoveryDelay: Double = 5
    private static let reloadSpacing: Double = 20

    private init() {}

    var hasSurface: Bool { aetherEngine != nil }

    // MARK: Loading

    /// Opens `source` on the single engine. The caller already holds a StreamGate ticket and has stopped the
    /// previous session. Never retries: a failure is reported once (status callback) and stays failed.
    func load(_ source: PlayerSource) async -> PlayerLoadOutcome {
        let engine: AetherEngine
        do {
            engine = try ensureEngine()
        } catch {
            owner?.engineStatusChanged(.failed(PlayerFailure(
                kind: .engineUnavailable,
                message: "The playback engine could not start on this Mac.",
                detail: String(describing: error),
                cooldown: 10)))
            return .failed
        }
        owner?.engineSurfaceReady()
        begin(source)
        let token = session
        registerSecrets(in: source.url)
        do {
            try await engine.load(url: source.url, startPosition: source.startPosition, options: Self.options(for: source))
            return token == session ? .started : .cancelled
        } catch is CancellationError {
            // Superseded by our own stop()/load(): not a failure, nothing to report, nothing to retry.
            return .cancelled
        } catch {
            guard token == session else { return .cancelled }
            if failedSession != session {
                // The engine normally publishes `.error` + errorInfo before it throws; this covers a throw without it.
                fail(Self.classify(info: engine.errorInfo, message: String(describing: error)))
            }
            return .failed
        }
    }

    /// Stops the engine synchronously (engine `state` is `.idle` when this returns) and forgets the session.
    func stopNow() {
        session += 1
        active = false
        source = nil
        awaitingStart = false
        cancelTasks()
        cues = []
        shownCueIDs = []
        pictureInPicture?.stop()
        aetherEngine?.stop()
    }

    /// Waits (briefly) until the engine reports `.idle`. `stop()` is synchronous, so this normally returns at once.
    func waitUntilIdle() async {
        guard let engine = aetherEngine else { return }
        var spins = 0
        while engine.state != .idle, spins < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            spins += 1
        }
    }

    // MARK: Transport

    func play() {
        guard active else { return }
        aetherEngine?.play()
    }

    func pause() {
        guard active else { return }
        aetherEngine?.pause()
    }

    func togglePlayPause() {
        guard active else { return }
        aetherEngine?.togglePlayPause()
    }

    func seek(to seconds: Double) async {
        guard active, let engine = aetherEngine else { return }
        await engine.seek(to: seconds)
    }

    func goLive() async {
        guard active, let engine = aetherEngine, engine.isLive else { return }
        await engine.seekToLiveEdge()
        if case .paused = engine.state { engine.play() }
    }

    func setVolume(_ value: Float) {
        volume = value
        aetherEngine?.volume = value
    }

    func selectAudio(id: Int) {
        guard active, let engine = aetherEngine else { return }
        engine.selectAudioTrack(index: id)
        scheduleSnapshot()
    }

    func selectSubtitle(id: Int?) {
        guard active, let engine = aetherEngine else { return }
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
        scheduleSnapshot()
    }

    /// Scrub previews come ONLY from bytes the session already holds (no second connection).
    var supportsScrubPreview: Bool {
        guard active, let engine = aetherEngine else { return false }
        return !engine.isLive && engine.supportsCacheBackedStills
    }

    func scrubPreview(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard supportsScrubPreview, let engine = aetherEngine else { return nil }
        return await engine.scrubThumbnail(atSeconds: seconds, maxWidth: maxWidth)
    }

    var isPictureInPicturePossible: Bool { pictureInPicture?.isPossible ?? false }

    func togglePictureInPicture() {
        guard active else { return }
        pictureInPicture?.toggle()
    }

    func stopPictureInPicture() {
        pictureInPicture?.stop()
    }

    // MARK: Session lifecycle

    private func ensureEngine() throws -> AetherEngine {
        if let engine = aetherEngine { return engine }
        let engine = try AetherEngine()
        engine.videoGravity = .resizeAspect
        engine.volume = volume
        aetherEngine = engine
        wire(engine)
        let pip = TunaPictureInPicture(engine: engine)
        pip.onActiveChange = { [weak self] isActive in
            self?.owner?.enginePictureInPictureChanged(isActive)
        }
        pictureInPicture = pip
        return engine
    }

    private func begin(_ source: PlayerSource) {
        session += 1
        cancelTasks()
        self.source = source
        active = true
        failedSession = -1
        reachedPlayback = false
        awaitingStart = true
        usedInPlaceRecovery = false
        usedReload = false
        lastMotion = .distantPast
        lastClockSample = 0
        cues = []
        subtitlesOn = false
        shownCueIDs = []
        armOpenWatchdog()
    }

    private func isCurrent(_ token: Int) -> Bool { token == session && active }

    private func cancelTasks() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        openWatchdog?.cancel()
        openWatchdog = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func emit(_ status: PlayerEngineStatus) {
        guard active else { return }
        owner?.engineStatusChanged(status)
    }

    /// Reports a failure once. Does not stop the engine (this may run inside an engine publisher callback);
    /// PlayerModel tears the session down on its next turn and only then closes the StreamGate ticket.
    private func fail(_ failure: PlayerFailure) {
        guard failedSession != session else { return }
        failedSession = session
        active = false
        awaitingStart = false
        cancelTasks()
        owner?.engineStatusChanged(.failed(failure))
    }

    /// Watchdog verdict: report the failure and stop the engine right away (this caps every internal ladder).
    private func giveUp(_ failure: PlayerFailure) {
        guard active else { return }
        fail(failure)
        aetherEngine?.stop()
    }

    private static func delay(seconds: Double) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    // MARK: Watchdogs

    private func armOpenWatchdog() {
        openWatchdog?.cancel()
        let token = session
        openWatchdog = Task { [weak self] in
            guard await Self.delay(seconds: Self.openLimitSeconds) else { return }
            guard let self, self.isCurrent(token), self.awaitingStart else { return }
            self.openWatchdog = nil
            self.giveUp(.timedOut())
        }
    }

    private func armStallWatchdog() {
        guard stallWatchdog == nil else { return }
        let token = session
        stallWatchdog = Task { [weak self] in
            guard await Self.delay(seconds: Self.stallLimitSeconds) else { return }
            guard let self, self.isCurrent(token) else { return }
            self.stallWatchdog = nil
            if case .stalled? = self.aetherEngine?.playbackPhase {
                // Still down after 12 s: stop the engine instead of letting its reconnect ladder run on.
                self.giveUp(.interrupted())
            }
        }
    }

    private func clearStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    private func clearOpenWatchdog() {
        awaitingStart = false
        openWatchdog?.cancel()
        openWatchdog = nil
    }

    // MARK: Live recovery (liveSourceReset)

    /// At most one in-place `retryLiveSourceRecovery()` (5 s after the reset), then at most one reload of the
    /// same URL at least 20 s after the reset, then stop. Counters reset only on a user-initiated load.
    private func liveSourceDidReset() {
        guard active, let source, source.isLive else { return }
        guard recoveryTask == nil else { return }
        if usedInPlaceRecovery && usedReload {
            giveUp(.liveExhausted())
            return
        }
        emit(.reconnecting)
        let token = session
        let resetAt = Date()
        recoveryTask = Task { [weak self] in
            await self?.recover(token: token, resetAt: resetAt)
        }
    }

    private func recover(token: Int, resetAt: Date) async {
        var accepted = false
        if !usedInPlaceRecovery {
            usedInPlaceRecovery = true
            guard await Self.delay(seconds: Self.inPlaceRecoveryDelay), isCurrent(token) else { return }
            accepted = aetherEngine?.retryLiveSourceRecovery() ?? false
        }
        let wait = Self.reloadSpacing - Date().timeIntervalSince(resetAt)
        guard await Self.delay(seconds: wait), isCurrent(token) else { return }
        recoveryTask = nil
        if accepted, lastMotion > resetAt.addingTimeInterval(Self.inPlaceRecoveryDelay) {
            return   // the in-place recovery brought the picture back
        }
        guard !usedReload else {
            giveUp(.liveExhausted())
            return
        }
        await reloadOnce(token: token)
    }

    private func reloadOnce(token: Int) async {
        guard let engine = aetherEngine, let source, isCurrent(token) else { return }
        usedReload = true
        emit(.reconnecting)
        awaitingStart = true
        armOpenWatchdog()
        do {
            try await engine.load(url: source.url, startPosition: nil, options: Self.options(for: source))
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(token) else { return }
            fail(Self.classify(info: engine.errorInfo, message: String(describing: error)))
        }
    }

    // MARK: Engine -> PlayerModel

    private func wire(_ engine: AetherEngine) {
        engine.$playbackPhase
            .removeDuplicates()
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &bag)

        // errorInfo is assigned before state, so it is this failure's own info here.
        engine.$state
            .sink { [weak self, weak engine] state in
                guard case .error(let message) = state else { return }
                self?.engineReportedError(message: message, info: engine?.errorInfo)
            }
            .store(in: &bag)

        engine.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.liveSourceDidReset() }
            .store(in: &bag)

        engine.clock.$currentTime
            .sink { [weak self] time in self?.clockTicked(time) }
            .store(in: &bag)

        engine.clock.$sourceTime
            .sink { [weak self] time in self?.refreshSubtitles(at: time) }
            .store(in: &bag)

        engine.$subtitleCues
            .sink { [weak self] newCues in self?.cuesChanged(newCues) }
            .store(in: &bag)

        engine.$isSubtitleActive
            .removeDuplicates()
            .sink { [weak self] isOn in self?.subtitleActivityChanged(isOn) }
            .store(in: &bag)

        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .sink { [weak self] ready in
                if ready { self?.firstFrameReady() }
            }
            .store(in: &bag)

        // Tracks and nerd stats: coalesced, read on a later main-actor turn (@Published fires in willSet).
        engine.objectWillChange
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &bag)

        engine.diagnostics.$liveTelemetry
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &bag)
    }

    private func phaseChanged(_ phase: PlaybackPhase) {
        guard active else { return }
        switch phase {
        case .idle:
            return
        case .loading:
            emit(reachedPlayback ? .reconnecting : .loading)
        case .playing:
            reachedPlayback = true
            clearOpenWatchdog()
            clearStallWatchdog()
            emit(.playing)
        case .paused:
            clearOpenWatchdog()
            clearStallWatchdog()
            emit(.paused)
        case .seeking, .rebuffering:
            clearStallWatchdog()
            emit(.buffering)
        case .stalled:
            emit(.reconnecting)
            armStallWatchdog()
        case .ended:
            clearOpenWatchdog()
            clearStallWatchdog()
            emit(.ended)
        case .error:
            return   // reported through $state + errorInfo
        default:
            return
        }
    }

    private func engineReportedError(message: String, info: PlaybackErrorInfo?) {
        guard active else { return }
        fail(Self.classify(info: info, message: message))
    }

    private func clockTicked(_ time: Double) {
        guard active, let engine = aetherEngine else { return }
        if abs(time - lastClockSample) >= 0.2 {
            if time > lastClockSample { lastMotion = Date() }
            lastClockSample = time
        }
        let clock = engine.clock
        owner?.engineTimeChanged(position: time,
                                 duration: engine.duration,
                                 behindLive: clock.behindLiveSeconds,
                                 atLiveEdge: clock.isAtLiveEdge)
    }

    private func firstFrameReady() {
        guard active else { return }
        owner?.engineFirstFrame()
    }

    // MARK: Subtitles

    private func cuesChanged(_ newCues: [SubtitleCue]) {
        cues = newCues
        guard active, let engine = aetherEngine else { return }
        refreshSubtitles(at: engine.clock.sourceTime)
    }

    private func subtitleActivityChanged(_ isOn: Bool) {
        subtitlesOn = isOn
        guard active, let engine = aetherEngine else { return }
        refreshSubtitles(at: engine.clock.sourceTime)
        scheduleSnapshot()
    }

    /// Cues carry source PTS; they are matched against `clock.sourceTime` (the presented frame).
    private func refreshSubtitles(at time: Double) {
        guard active, time.isFinite else { return }
        let showing = cues.filter { cue in
            (subtitlesOn || cue.isForced) && cue.startTime <= time && time < cue.endTime
        }
        let ids = showing.map { $0.id }
        guard ids != shownCueIDs else { return }
        shownCueIDs = ids
        owner?.engineSubtitlesChanged(showing.compactMap { Self.convert($0) })
    }

    private static func convert(_ cue: SubtitleCue) -> PlayerSubtitleCue? {
        let prefersTop = (cue.placement?.alignment).map { $0 >= 7 } ?? false
        switch cue.body {
        case .text(let text):
            return PlayerSubtitleCue(id: cue.id, body: .text(cleanText(text)), prefersTop: prefersTop)
        case .richText(let runs):
            return PlayerSubtitleCue(id: cue.id, body: .text(cleanText(runs.map { $0.text }.joined())), prefersTop: prefersTop)
        case .image(let image):
            return PlayerSubtitleCue(id: cue.id, body: .bitmap(image.cgImage, rect: image.position, canvas: image.canvasSize))
        default:
            return nil
        }
    }

    private static func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Tracks and nerd stats

    private func scheduleSnapshot() {
        guard active, !snapshotPending else { return }
        snapshotPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.snapshotPending = false
            self.publishSnapshot()
        }
    }

    private func publishSnapshot() {
        guard active, let engine = aetherEngine else { return }
        let activeAudio = engine.activeAudioTrackIndex
        let audio = engine.audioTracks.enumerated().map { index, track in
            Self.audioOption(track, index: index, selected: track.id == activeAudio)
        }
        let activeSubtitle = engine.isSubtitleActive ? engine.activeSubtitleTrackIndex : nil
        let subtitles = engine.subtitleTracks.enumerated().map { index, track in
            Self.subtitleOption(track, index: index, selected: track.id == activeSubtitle)
        }
        var aspect: Double?
        let width = Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio
        let height = Double(engine.sourceVideoHeight)
        if width > 0, height > 0 { aspect = width / height }
        owner?.engineSnapshotChanged(audio: audio, subtitles: subtitles, tech: techInfo(engine), videoAspect: aspect)
    }

    private func techInfo(_ engine: AetherEngine) -> PlayerModel.TechInfo {
        var tech = PlayerModel.TechInfo()
        let telemetry = engine.diagnostics.liveTelemetry
        if engine.sourceVideoWidth > 0 { tech.width = Int(engine.sourceVideoWidth) }
        if engine.sourceVideoHeight > 0 { tech.height = Int(engine.sourceVideoHeight) }
        if let codec = engine.sourceVideoCodecName, !codec.isEmpty {
            tech.videoCodec = Self.codecLabel(codec) + (engine.sourceVideoScan.isInterlaced ? " · interlaced" : "")
        }
        if tech.height != nil {
            let source = Self.hdrLabel(engine.sourceVideoFormat, profile: engine.sourceDVProfile)
            let shown = Self.hdrLabel(engine.videoFormat, profile: nil)
            tech.hdr = engine.videoFormat == engine.sourceVideoFormat ? source : "\(source) → \(shown)"
        }
        if let fps = engine.sourceVideoFrameRate, fps > 0 { tech.frameRate = fps }
        if let mbps = telemetry?.instantBitrateMbps, mbps > 0 {
            tech.bitrateMbps = mbps
        } else if engine.sourceVideoBitrate > 0 {
            tech.bitrateMbps = Double(engine.sourceVideoBitrate) / 1_000_000
        }
        tech.decoder = engine.activeVideoDecoder
        let audioTrack = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex } ?? engine.audioTracks.first
        if let audioTrack {
            tech.audioCodec = Self.codecLabel(audioTrack.codec) + (audioTrack.isAtmos ? " · Atmos" : "")
            if audioTrack.channels > 0 { tech.audioChannels = audioTrack.channels }
        } else if let decoder = engine.activeAudioDecoder {
            tech.audioCodec = decoder
        }
        tech.route = Self.routeLabel(engine.videoRoute)
        if let buffer = telemetry?.forwardBufferSeconds {
            tech.bufferSeconds = buffer
        } else {
            let ahead = engine.clock.bufferedPosition - engine.clock.currentTime
            if ahead > 0 { tech.bufferSeconds = ahead }
        }
        tech.droppedFrames = telemetry?.droppedFrameCount
        tech.engineVersion = Self.engineLabel
        return tech
    }

    private static func audioOption(_ track: TrackInfo, index: Int, selected: Bool) -> PlayerModel.TrackOption {
        let language = PlayerFormat.languageName(track.language)
        var parts: [String] = [codecLabel(track.codec)]
        if let layout = channelLabel(track.channels) { parts.append(layout) }
        if track.isAtmos { parts.append("Atmos") }
        if track.isCommentary { parts.append("Commentary") }
        if track.isVisualImpaired { parts.append("Audio description") }
        return PlayerModel.TrackOption(id: track.id,
                                       name: trackName(track, language: language, index: index, fallback: "Audio"),
                                       language: language,
                                       detail: parts.joined(separator: " · "),
                                       isSelected: selected)
    }

    private static func subtitleOption(_ track: TrackInfo, index: Int, selected: Bool) -> PlayerModel.TrackOption {
        let language = PlayerFormat.languageName(track.language)
        var parts: [String] = [codecLabel(track.codec)]
        if track.isForced { parts.append("Forced") }
        if track.isHearingImpaired { parts.append("SDH") }
        if track.isExternal { parts.append("External") }
        return PlayerModel.TrackOption(id: track.id,
                                       name: trackName(track, language: language, index: index, fallback: "Subtitles"),
                                       language: language,
                                       detail: parts.joined(separator: " · "),
                                       isSelected: selected)
    }

    private static func trackName(_ track: TrackInfo, language: String?, index: Int, fallback: String) -> String {
        let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return language ?? "\(fallback) \(index + 1)"
    }

    private static func channelLabel(_ channels: Int) -> String? {
        switch channels {
        case 0: return nil
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    private static func codecLabel(_ codec: String) -> String {
        let labels: [String: String] = [
            "hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9", "mpeg2video": "MPEG-2",
            "mpeg4": "MPEG-4", "vc1": "VC-1",
            "aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus", "truehd": "Dolby TrueHD",
            "dts": "DTS", "mp2": "MPEG Audio", "mp3": "MP3", "opus": "Opus", "flac": "FLAC",
            "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "mov_text": "Timed Text",
            "hdmv_pgs_subtitle": "PGS", "dvb_subtitle": "DVB", "dvd_subtitle": "VobSub",
            "dvb_teletext": "Teletext", "eia_608": "CC",
        ]
        let key = codec.lowercased()
        return labels[key] ?? key.uppercased()
    }

    private static func hdrLabel(_ format: VideoFormat, profile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return profile.map { "Dolby Vision P\($0)" } ?? "Dolby Vision"
        case .hlg: return "HLG"
        default: return "HDR"
        }
    }

    private static func routeLabel(_ route: VideoRoute) -> String? {
        switch route {
        case .none: return nil
        case .remoteBypass: return "AVPlayer (direct HLS)"
        case .loopback: return "Native (AVPlayer loopback)"
        case .software: return "Software (FFmpeg)"
        case .audio: return "Audio only"
        default: return nil
        }
    }

    // MARK: Failure classification

    /// Maps the engine's machine-readable `errorInfo` to a friendly failure plus the manual-retry cooldown:
    /// 30 s for rate limits and 401/403, 10 s for 5xx / unavailable sources.
    static func classify(info: PlaybackErrorInfo?, message: String) -> PlayerFailure {
        let kind = info?.kind
        let code = info?.underlyingCode
        var detailParts: [String] = []
        if let kind { detailParts.append(kind.rawValue) }
        if let code { detailParts.append("code \(code)") }
        if !message.isEmpty { detailParts.append(message) }
        let detail = detailParts.joined(separator: " · ")

        guard let kind else {
            return PlayerFailure(kind: .unknown, message: "The stream could not be played.", detail: detail, cooldown: 15)
        }
        if kind == .sourceRateLimited {
            return PlayerFailure.http(code ?? 509, detail: detail)
        }
        if kind == .sourceRefused {
            if let code { return PlayerFailure.http(code, detail: detail) }
            return PlayerFailure(kind: .refused,
                                 message: "Your provider refused the stream. If another device is watching on this account, stop it there first.",
                                 detail: detail, cooldown: 30)
        }
        if kind == .liveSourceUnavailable {
            return PlayerFailure(kind: .unavailable,
                                 message: "This channel is not broadcasting right now.",
                                 detail: detail, cooldown: 10, countsAgainstVariant: true)
        }
        if kind == .sourceCertificateRejected {
            return PlayerFailure(kind: .certificate,
                                 message: "The provider's secure connection could not be verified.",
                                 detail: detail, cooldown: 60)
        }
        if kind == .storageExhausted {
            return PlayerFailure(kind: .storage,
                                 message: "Your Mac is out of disk space for the playback cache. Free some space and retry.",
                                 detail: detail, cooldown: 10)
        }
        if unsupportedKinds.contains(kind) {
            return PlayerFailure(kind: .unsupported,
                                 message: "This version uses a format your Mac could not play. Try another version.",
                                 detail: detail, cooldown: 60, countsAgainstVariant: true)
        }
        if kind == .sourceOpenFailed, info?.underlyingDomain == NSURLErrorDomain {
            return PlayerFailure(kind: .network,
                                 message: "Tuna TV could not reach the provider. Check your internet connection.",
                                 detail: detail, cooldown: 15)
        }
        return PlayerFailure(kind: .unavailable,
                             message: "The stream could not be opened.",
                             detail: detail, cooldown: 15, countsAgainstVariant: true)
    }

    private static let unsupportedKinds: Set<PlaybackErrorKind> = [
        .hlsFormatUnsupported, .nativeItemFailed, .softwarePipelineFailed, .masterPlaylistRejected,
        .noPlayableTrackWithinBudget, .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported,
        .hlsPlaylistOnRawLivePath, .audioBridgeProducedNoOutput,
    ]

    // MARK: Load options (provider-safe preset)

    static func options(for source: PlayerSource) -> LoadOptions {
        var options = LoadOptions()
        // Common block: the session's own headers (User-Agent), ONE request at a time against the origin,
        // nothing that opens a second reader on the provider.
        options.httpHeaders = source.headers
        options.maxConcurrentSourceRequests = 1
        options.generatesBackgroundScrubPreviews = false
        options.serveIFramePlaylist = false
        options.confirmAtmos = false
        options.escalatesToSoftwarePath = true
        options.preferredAudioLanguages = source.audioLanguages
        options.preferredSubtitleLanguages = source.subtitleLanguages
        switch source.kind {
        case .live(let isHLS, let dvrWindowSeconds):
            options.isLive = true
            options.liveJoinProfile = .fastZap
            options.dvrWindowSeconds = dvrWindowSeconds
            if isHLS { options.nativeRemoteHLS = false }   // the engine's ingest obeys the cap; AVPlayer would not
        case .vod:
            break   // the resume point is passed as load(startPosition:)
        case .catchup(let durationSeconds):
            options.sequentialOrigin = true
            if durationSeconds > 0 { options.declaredDurationSeconds = durationSeconds }
        }
        return options
    }

    /// Keeps the account's credentials out of every engine log line (the engine already scrubs the Xtream path
    /// layout; this adds the bare path segments and query values it cannot recognise).
    private func registerSecrets(in url: URL) {
        var values: [String] = []
        let parts = url.path.split(separator: "/").map { String($0) }
        let markers: Set<String> = ["live", "movie", "series", "timeshift"]
        if let index = parts.firstIndex(where: { markers.contains($0.lowercased()) }), parts.count > index + 2 {
            values.append(parts[index + 1])
            values.append(parts[index + 2])
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let names: Set<String> = ["username", "password", "user", "pass", "token", "auth"]
            for item in items where names.contains(item.name.lowercased()) {
                if let value = item.value { values.append(value) }
            }
        }
        if let user = url.user { values.append(user) }
        if let password = url.password { values.append(password) }
        for value in values where value.count >= 4 && !registeredSecrets.contains(value) {
            registeredSecrets.insert(value)
            EngineLog.registerSecret(value)
        }
    }
}

#else

/// TunaTVCheck build: no playback engine. Same API as the real wrapper; every load reports
/// "Playback engine not included in this build".
@MainActor
final class TunaPlaybackEngine {
    static let shared = TunaPlaybackEngine()
    static let isAvailable = false
    static let unavailableMessage = "Playback engine not included in this build"
    nonisolated static var engineLabel: String { "No engine (check build)" }

    weak var owner: PlayerModel?

    private init() {}

    var hasSurface: Bool { false }

    func load(_ source: PlayerSource) async -> PlayerLoadOutcome {
        owner?.engineStatusChanged(.failed(PlayerFailure(kind: .notIncluded, message: Self.unavailableMessage)))
        return .failed
    }

    func stopNow() {}
    func waitUntilIdle() async {}
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(to seconds: Double) async {}
    func goLive() async {}
    func setVolume(_ value: Float) {}
    func selectAudio(id: Int) {}
    func selectSubtitle(id: Int?) {}
    var supportsScrubPreview: Bool { false }
    func scrubPreview(at seconds: Double, maxWidth: Int = 320) async -> CGImage? { nil }
    var isPictureInPicturePossible: Bool { false }
    func togglePictureInPicture() {}
    func stopPictureInPicture() {}
}

#endif
