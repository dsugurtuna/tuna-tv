import Foundation
import MediaPlayer

/// System Now Playing card and media keys (play/pause, ±10 s, next/previous, scrubbing from Control Center).
/// The host drives the shared centers (the engine's own video Now-Playing session is left off, its default).
/// Remote commands only ever call PlayerModel methods, so they obey the same provider-safety rules
/// (debounced zaps, no automatic retries).
@MainActor
final class PlayerNowPlaying {
    static let shared = PlayerNowPlaying()

    private weak var player: PlayerModel?
    private var targets: [Any] = []
    private var registered = false
    private var lastSignature = ""

    private init() {}

    /// Registers the remote command handlers once and routes them to `player`.
    func attach(_ player: PlayerModel) {
        self.player = player
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()

        targets.append(center.playCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.resume() }
            return .success
        })
        targets.append(center.pauseCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.pause() }
            return .success
        })
        targets.append(center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.togglePlayPause() }
            return .success
        })
        targets.append(center.stopCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.stop() }
            return .success
        })

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        targets.append(center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.skip(by: 10) }
            return .success
        })
        targets.append(center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.skip(by: -10) }
            return .success
        })

        targets.append(center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.remoteNext() }
            return .success
        })
        targets.append(center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in PlayerNowPlaying.shared.player?.remotePrevious() }
            return .success
        })

        targets.append(center.changePlaybackPositionCommand.addTarget { event in
            guard let change = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = change.positionTime
            Task { @MainActor in PlayerNowPlaying.shared.player?.seek(to: position) }
            return .success
        })
    }

    /// Publishes the current item. Elapsed time is extrapolated by the system from the rate, so this only needs
    /// to run on state changes, seeks and the ~10 s progress tick.
    func update(title: String, subtitle: String?, duration: Double, position: Double,
                isLive: Bool, isPlaying: Bool, canGoNext: Bool, canGoPrevious: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = canGoNext
        commands.previousTrackCommand.isEnabled = canGoPrevious
        commands.skipForwardCommand.isEnabled = !isLive
        commands.skipBackwardCommand.isEnabled = !isLive
        commands.changePlaybackPositionCommand.isEnabled = !isLive && duration > 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if !isLive, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, min(position, duration))
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        lastSignature = title
    }

    func clear() {
        guard !lastSignature.isEmpty else { return }
        lastSignature = ""
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
    }
}
