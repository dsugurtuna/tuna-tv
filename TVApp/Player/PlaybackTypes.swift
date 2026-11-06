import Foundation
import CoreGraphics

// =====================================================================================================
// Engine-agnostic playback types shared by TunaPlaybackEngine (both builds), PlayerModel and the views.
// Nothing in here touches AetherEngine, so the TunaTVCheck target (no engine) compiles them too.
// =====================================================================================================

/// One stream the engine wrapper is asked to open: already resolved (URL + headers) and already holding a
/// StreamGate ticket. The wrapper never resolves URLs or opens tickets itself.
struct PlayerSource: Equatable {
    enum Kind: Equatable {
        /// A live channel. `isHLS` for `.m3u8` outputs; `dvrWindowSeconds` nil means live-only (no timeshift).
        case live(isHLS: Bool, dvrWindowSeconds: Double?)
        /// A movie or an episode, resuming at `startPosition` (nil = from the start).
        case vod(startPosition: Double?)
        /// A catch-up recording of one programme (sequential origin with a declared duration).
        case catchup(durationSeconds: Double)
    }

    var url: URL
    var headers: [String: String]
    var kind: Kind
    var audioLanguages: [String]
    var subtitleLanguages: [String]

    var isLive: Bool {
        if case .live = kind { return true }
        return false
    }

    var startPosition: Double? {
        if case .vod(let start) = kind { return start }
        return nil
    }
}

/// What the engine wrapper reports to PlayerModel.
enum PlayerEngineStatus: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case reconnecting
    case ended
    case failed(PlayerFailure)
}

/// How a `TunaPlaybackEngine.load(_:)` call ended. Failures are reported once, through the status callback.
enum PlayerLoadOutcome: Equatable {
    case started
    case cancelled
    case failed
}

/// A playback failure in words a person understands, plus the manual-retry cooldown.
/// Failures are NEVER retried automatically (provider safety); `cooldown` only unlocks the Retry button.
struct PlayerFailure: Equatable {
    enum Kind: String, Equatable {
        /// 429 / 458 / 503 / 509, or the Xtream "connection limit reached" notice.
        case rateLimited
        /// 401 / 403: on a connection-capped panel this usually means the slot is still held.
        case refused
        case notFound
        case serverError
        /// The live source is not delivering anything.
        case unavailable
        /// A format or codec this Apple TV cannot play.
        case unsupported
        case certificate
        case network
        case storage
        /// The stall watchdog stopped a stream that stayed stalled for 12 s.
        case interrupted
        /// The bounded live recovery (1 in-place retry, then 1 reload) was spent.
        case liveExhausted
        /// The stream did not start within the opening budget.
        case timedOut
        /// StreamGate refused the open (too many stream starts in a short time).
        case streamLimit
        /// The provider's request breaker is open.
        case providerPaused
        case missingURL
        case noProvider
        case demo
        /// TunaTVCheck build: no playback engine compiled in.
        case notIncluded
        case engineUnavailable
        case unknown
    }

    var kind: Kind
    /// Friendly, user-facing sentence.
    var message: String
    var httpStatus: Int? = nil
    /// Technical detail for the "Why am I seeing this?" disclosure (credentials are never included).
    var detail: String? = nil
    /// Seconds until manual Retry unlocks; nil = Retry is not offered for this failure.
    var cooldown: TimeInterval? = nil
    /// Whether the failure is the variant's fault (it gets demoted in the version order).
    var countsAgainstVariant: Bool = false
}

extension PlayerFailure {
    static let demo = PlayerFailure(kind: .demo, message: "Demo mode: add your provider to watch real streams.")

    static let noProvider = PlayerFailure(
        kind: .noProvider,
        message: "This provider is not set up on this Apple TV. Add or enable it in Settings to watch.")

    static let missingURL = PlayerFailure(
        kind: .missingURL,
        message: "Tuna TV could not build a stream address for this version.",
        countsAgainstVariant: true)

    static func interrupted() -> PlayerFailure {
        PlayerFailure(kind: .interrupted,
                      message: "Stream interrupted. The provider stopped sending video, so Tuna TV closed the connection.",
                      detail: "Stalled for 12 s; the stall watchdog stopped the engine.",
                      cooldown: 10)
    }

    static func liveExhausted() -> PlayerFailure {
        PlayerFailure(kind: .liveExhausted,
                      message: "This channel keeps dropping out. Tuna TV stopped trying so your account stays safe.",
                      detail: "Live source reset twice (one in-place recovery, one reload).",
                      cooldown: 10,
                      countsAgainstVariant: true)
    }

    static func timedOut() -> PlayerFailure {
        PlayerFailure(kind: .timedOut,
                      message: "The stream did not start. Your provider may be busy right now.",
                      detail: "No picture within 45 s; the opening watchdog stopped the engine.",
                      cooldown: 15,
                      countsAgainstVariant: true)
    }

    /// The origin answered the stream request with an HTTP status instead of media.
    static func http(_ status: Int, detail: String?) -> PlayerFailure {
        switch status {
        case 401, 403:
            return PlayerFailure(kind: .refused,
                                 message: "Your provider refused the stream (HTTP \(status)). If another device or app is watching on this account, stop it there first.",
                                 httpStatus: status, detail: detail, cooldown: 30)
        case 429, 458, 503, 509:
            return PlayerFailure(kind: .rateLimited,
                                 message: "Your provider says the connection limit is reached. Tuna TV paused to protect your account.",
                                 httpStatus: status, detail: detail, cooldown: 30)
        case 404, 410:
            return PlayerFailure(kind: .notFound,
                                 message: "This stream is not available on your provider right now (HTTP \(status)).",
                                 httpStatus: status, detail: detail, cooldown: 10, countsAgainstVariant: true)
        case 500...599:
            return PlayerFailure(kind: .serverError,
                                 message: "Your provider's server had a problem (HTTP \(status)).",
                                 httpStatus: status, detail: detail, cooldown: 10, countsAgainstVariant: true)
        default:
            return PlayerFailure(kind: .unknown,
                                 message: "Your provider answered with HTTP \(status) instead of video.",
                                 httpStatus: status, detail: detail, cooldown: 10)
        }
    }

    /// Short heading for the error card.
    var title: String {
        switch kind {
        case .rateLimited, .refused, .streamLimit, .providerPaused: return "Your provider needs a moment"
        case .interrupted: return "Stream interrupted"
        case .liveExhausted, .unavailable: return "Channel unavailable"
        case .unsupported: return "Format not supported"
        case .timedOut: return "The stream did not start"
        case .demo: return "Demo mode"
        case .notIncluded, .engineUnavailable: return "Playback unavailable"
        case .noProvider: return "No provider"
        default: return "Can't play this right now"
        }
    }

    /// SF Symbol for the error card.
    var symbol: String {
        switch kind {
        case .rateLimited, .refused, .streamLimit, .providerPaused: return "hand.raised.fill"
        case .interrupted, .liveExhausted, .unavailable, .timedOut: return "antenna.radiowaves.left.and.right.slash"
        case .unsupported: return "film.stack"
        case .demo: return "sparkles.tv"
        case .network, .certificate: return "wifi.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    /// The text behind "Why am I seeing this?".
    var explanation: String {
        let rules = "IPTV providers usually allow only one stream at a time per account. Tuna TV opens exactly one connection and never retries on its own, because automatic retries and reconnect storms are what get accounts suspended. Retry unlocks after a short cooldown so the provider can release the previous connection first."
        switch kind {
        case .rateLimited, .refused:
            return "Your provider turned this stream request down. Most often another device or app is using your connection, or the provider has not yet noticed that the previous stream closed. " + rules
        case .streamLimit, .providerPaused:
            return "Stream starts were coming in quickly, so Tuna TV is pacing them to keep your account in good standing. " + rules
        case .interrupted, .liveExhausted:
            return "The provider stopped delivering video. Instead of hammering the server with reconnects, Tuna TV gives a stream a few bounded chances and then stops. " + rules
        case .unsupported:
            return "The stream uses a format this Apple TV could not decode. Another version of the same title often uses a different format."
        case .demo:
            return "The demo library shows what Tuna TV looks like with your provider. Add an Xtream Codes or M3U provider in Settings to watch real streams."
        case .notIncluded:
            return "This is a test build of Tuna TV without the playback engine. Download the regular build to watch streams."
        default:
            return rules
        }
    }
}

/// One subtitle cue to draw over the picture.
struct PlayerSubtitleCue: Identifiable, Equatable {
    enum Body {
        case text(String)
        /// A bitmap cue (PGS / DVB / DVD). `rect` is normalized against `canvas` (or the video frame when the
        /// canvas is `.zero`), with y measured from the top.
        case bitmap(CGImage, rect: CGRect, canvas: CGSize)
    }

    let id: Int
    let body: Body
    /// Text cues that ask for the top of the picture (ASS \an7...9).
    var prefersTop: Bool = false

    var text: String? {
        if case .text(let value) = body { return value }
        return nil
    }

    var isBitmap: Bool {
        if case .bitmap = body { return true }
        return false
    }

    static func == (lhs: PlayerSubtitleCue, rhs: PlayerSubtitleCue) -> Bool {
        lhs.id == rhs.id && lhs.prefersTop == rhs.prefersTop && lhs.text == rhs.text
    }
}

/// Small formatting helpers for the player UI.
enum PlayerFormat {
    /// "1:02:03" / "4:05".
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Localized language name for an ISO 639 code ("eng" / "en" -> "English").
    static func languageName(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
              code.lowercased() != "und" else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code.uppercased()
    }
}

/// Geometry for placing subtitles over an aspect-fit picture.
enum PlayerGeometry {
    /// The rectangle an aspect-fit picture of `aspect` (width / height) occupies inside `size`.
    static func videoRect(in size: CGSize, aspect: Double?) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard let aspect, aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else { return full }
        let ratio = CGFloat(aspect)
        if ratio > size.width / size.height {
            let height = size.width / ratio
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * ratio
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    /// On-screen frame of a bitmap cue: the canvas is mapped width-aligned and centred vertically on the video
    /// rect (the engine's own compositor does the same); a `.zero` canvas means "normalized to the video".
    static func bitmapFrame(rect: CGRect, canvas: CGSize, video: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else {
            return CGRect(x: video.minX + rect.minX * video.width,
                          y: video.minY + rect.minY * video.height,
                          width: rect.width * video.width,
                          height: rect.height * video.height)
        }
        let scale = video.width / canvas.width
        let pixelX = rect.minX * canvas.width
        let pixelY = rect.minY * canvas.height
        return CGRect(x: video.minX + pixelX * scale,
                      y: video.midY + (pixelY - canvas.height / 2) * scale,
                      width: rect.width * canvas.width * scale,
                      height: rect.height * canvas.height * scale)
    }
}
