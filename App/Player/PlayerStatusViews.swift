import SwiftUI
import TunaCore

/// Everything drawn over the picture that is about the session's state: the opening cover, buffering and
/// reconnecting spinners, the error card, the "finished" card and the Picture in Picture placeholder.
struct PlayerStatusLayer: View {
    let player: PlayerModel
    let app: AppModel

    var body: some View {
        ZStack {
            if player.isPictureInPicture {
                PlayerPiPPlaceholder(player: player)
                    .transition(.opacity)
            } else {
                stateView
            }
        }
        .animation(.easeInOut(duration: 0.3), value: player.status)
        .animation(.easeInOut(duration: 0.3), value: player.hasVideoFrame)
    }

    @ViewBuilder
    private var stateView: some View {
        switch player.status {
        case .opening:
            PlayerLoadingView(player: player, app: app, message: openingMessage)
                .transition(.opacity)
        case .buffering, .reconnecting:
            if player.hasVideoFrame {
                PlayerInlineSpinner(isReconnecting: player.status == .reconnecting)
                    .transition(.opacity)
            } else {
                PlayerLoadingView(player: player, app: app,
                                  message: player.status == .reconnecting ? "Reconnecting…" : "Buffering…")
                    .transition(.opacity)
            }
        case .failed(let message, let retryAfter):
            ZStack {
                PlayerArtworkBackdrop(content: player.content, app: app, dimming: 0.72)
                PlayerErrorCard(player: player, message: message, retryAfter: retryAfter)
            }
            .transition(.opacity)
        case .ended:
            if player.upNext == nil {
                PlayerEndedCard(player: player, title: player.isLive ? "The broadcast ended" : "Finished",
                                actionTitle: player.isLive ? "Tune in again" : "Watch again")
                    .transition(.opacity)
            }
        case .idle:
            if player.content != nil {
                PlayerEndedCard(player: player, title: "Playback stopped", actionTitle: "Play")
                    .transition(.opacity)
            }
        case .playing, .paused:
            EmptyView()
        }
    }

    private var openingMessage: String {
        guard let content = player.content else { return "Opening…" }
        switch content {
        case .channel: return "Tuning in…"
        case .catchup: return "Opening the recording…"
        case .movie, .episode: return "Opening…"
        }
    }
}

// MARK: - Loading

/// Opening/buffering cover: the title's artwork, blurred, with an elegant spinner.
struct PlayerLoadingView: View {
    let player: PlayerModel
    let app: AppModel
    let message: String

    var body: some View {
        ZStack {
            PlayerArtworkBackdrop(content: player.content, app: app, dimming: 0.5)
            VStack(spacing: 22) {
                if let channel = player.currentChannel {
                    TunaImage(url: channel.logoURL, kind: .channel, seed: channel.id, title: channel.name, contentMode: .fit)
                        .frame(width: 168, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 8)
                }
                PlayerSpinner(size: 52)
                VStack(spacing: 8) {
                    Text(player.content?.displayTitle ?? "")
                        .font(Tuna.Fonts.display(30, weight: .heavy))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let subtitle = player.content?.displaySubtitle {
                        Text(subtitle)
                            .font(Tuna.Fonts.bodyLarge)
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Text(message)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: 640)
            }
            .padding(40)
        }
    }
}

/// Blurred artwork of the current item behind state cards (never a grey box: TunaImage falls back to
/// generative art).
struct PlayerArtworkBackdrop: View {
    let content: PlayerModel.Content?
    let app: AppModel
    var dimming: Double = 0.55

    var body: some View {
        ZStack {
            Color.black
            if let art = artwork {
                TunaImage(url: art.url, kind: art.kind, seed: art.seed, title: art.title, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 44, opaque: true)
                    .scaleEffect(1.15)
                    .opacity(0.9)
            }
            Color.black.opacity(dimming)
            RadialGradient(colors: [Color.clear, Color.black.opacity(0.65)],
                           center: .center, startRadius: 120, endRadius: 900)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var artwork: (url: String?, kind: ArtworkKind, seed: String, title: String)? {
        guard let content else { return nil }
        switch content {
        case .movie(let title, _), .episode(let title, _, _):
            let metadata = app.metadata(for: title)
            let url = metadata?.backdropURL ?? title.backdropURL ?? metadata?.posterURL ?? title.posterURL
            return (url, .backdrop, title.id, title.name)
        case .channel(let channel, _), .catchup(let channel, _, _):
            return (channel.logoURL, .channel, channel.id, channel.name)
        }
    }
}

/// Rotating gradient arc.
struct PlayerSpinner: View {
    var size: CGFloat = 48
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: size * 0.08)
            Circle()
                .trim(from: 0.06, to: 0.72)
                .stroke(AngularGradient(gradient: Gradient(colors: [Tuna.Palette.accent.opacity(0.05),
                                                                     Tuna.Palette.accent,
                                                                     Tuna.Palette.accentWarm]),
                                        center: .center),
                        style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.95).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}

/// Small spinner over a playing picture (rebuffering, seeking, reconnecting).
struct PlayerInlineSpinner: View {
    let isReconnecting: Bool

    var body: some View {
        VStack(spacing: 12) {
            PlayerSpinner(size: 44)
            if isReconnecting {
                Text("Reconnecting…")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Error

/// Centered glass card: friendly message, "Why am I seeing this?", Retry with cooldown, another version.
struct PlayerErrorCard: View {
    let player: PlayerModel
    let message: String
    let retryAfter: Date?
    @State private var showsWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: player.failure?.symbol ?? "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.warning)
                Text(player.failure?.title ?? "Can't play this right now")
                    .font(Tuna.Fonts.display(22, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
            }
            Text(message)
                .font(Tuna.Fonts.bodyLarge)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showsWhy) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(player.failure?.explanation ?? PlayerFailure.demo.explanation)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = player.failure?.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Tuna.Fonts.mono)
                            .foregroundStyle(Tuna.Palette.textTertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .padding(.top, 6)
            } label: {
                Text("Why am I seeing this?")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.accentCool)
            }
            buttons
        }
        .padding(28)
        .frame(width: 480)
        .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
        .shadow(color: Color.black.opacity(0.45), radius: 30, x: 0, y: 16)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if let retryAfter {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(retryAfter.timeIntervalSince(context.date).rounded(.up)))
                    PlayerCardButton(title: remaining > 0 ? "Retry in \(remaining) s" : "Retry",
                                     systemImage: "arrow.clockwise", prominent: true) {
                        player.retry()
                    }
                    .disabled(remaining > 0)
                    .opacity(remaining > 0 ? 0.55 : 1)
                }
            }
            if !player.alternativeVariants.isEmpty {
                PlayerCardButton(title: "Try another version", systemImage: "square.stack.3d.up", prominent: retryAfter == nil) {
                    player.tryAnotherVersion()
                }
            }
            Spacer(minLength: 0)
            PlayerCardButton(title: "Close", systemImage: nil, prominent: false) {
                player.dismiss()
            }
        }
    }
}

/// Capsule button used on the player cards.
struct PlayerCardButton: View {
    let title: String
    let systemImage: String?
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Tuna.Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                Capsule().fill(prominent ? Color.white.opacity(hovering ? 1 : 0.92)
                                         : Color.white.opacity(hovering ? 0.2 : 0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Ended / stopped

struct PlayerEndedCard: View {
    let player: PlayerModel
    let title: String
    let actionTitle: String

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(Tuna.Fonts.display(26, weight: .heavy))
                .foregroundStyle(Tuna.Palette.textPrimary)
            if let name = player.content?.displayTitle {
                Text(name)
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                PlayerCardButton(title: actionTitle, systemImage: "play.fill", prominent: true) {
                    if let content = player.content { player.play(content, resumeAt: nil) }
                }
                PlayerCardButton(title: "Close", systemImage: nil, prominent: false) {
                    player.dismiss()
                }
            }
        }
        .padding(28)
        .frame(minWidth: 360)
        .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
    }
}

// MARK: - Picture in Picture

struct PlayerPiPPlaceholder: View {
    let player: PlayerModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Tuna.Palette.textSecondary)
            Text("Playing in Picture in Picture")
                .font(Tuna.Fonts.sectionTitle)
                .foregroundStyle(Tuna.Palette.textPrimary)
            PlayerCardButton(title: "Bring back", systemImage: "pip.exit", prominent: true) {
                player.togglePictureInPicture()
            }
        }
    }
}
