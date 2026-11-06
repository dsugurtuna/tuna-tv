import SwiftUI
import Observation
import TunaCore

// =====================================================================================================
// PLAYER CONTRACT (owner: player). One engine instance for the whole app (AetherEngine via
// TunaPlaybackEngine). Every open goes through AppModel.streamGate; zaps are debounced; failed loads are
// NEVER retried automatically (see docs/ARCHITECTURE.md "Provider Safety Spec" and research 02-engines §8.3).
// Signatures below are FIXED for other agents; the owner implements the bodies and adds files in App/Player/.
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

    unowned let app: AppModel

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
    private(set) var isPictureInPicture = false
    /// Channel currently "previewed" in the zapping strip before the debounce fires.
    private(set) var pendingZap: Channel?

    init(app: AppModel) {
        self.app = app
    }

    var canRetry: Bool { fatalError("TODO(player)") }

    func play(_ content: Content, resumeAt: Double?) { fatalError("TODO(player)") }
    /// Debounced (settings.playback.zapDebounce, default 0.6 s): only the last selection opens a stream.
    func zap(to channel: Channel) { fatalError("TODO(player)") }
    func zapNext() { fatalError("TODO(player)") }
    func zapPrevious() { fatalError("TODO(player)") }
    func recallLastChannel() { fatalError("TODO(player)") }
    func togglePlayPause() { fatalError("TODO(player)") }
    func seek(to seconds: Double) { fatalError("TODO(player)") }
    func skip(by seconds: Double) { fatalError("TODO(player)") }
    func goLive() { fatalError("TODO(player)") }
    /// Stops the engine, waits for it to be idle, closes the StreamGate ticket, saves progress.
    func stop() { fatalError("TODO(player)") }
    /// Manual retry only (respects `retryAfter`).
    func retry() { fatalError("TODO(player)") }
    func selectAudio(_ id: Int) { fatalError("TODO(player)") }
    func selectSubtitle(_ id: Int?) { fatalError("TODO(player)") }
    func switchVariant(_ variant: Variant) { fatalError("TODO(player)") }
    func playUpNext() { fatalError("TODO(player)") }
    func cancelUpNext() { fatalError("TODO(player)") }
    func togglePictureInPicture() { fatalError("TODO(player)") }
    /// Hide the player UI and stop playback.
    func dismiss() { fatalError("TODO(player)") }
}
