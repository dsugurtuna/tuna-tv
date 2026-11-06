import SwiftUI
import AppKit
import CoreGraphics
import TunaCore

/// The auto-hiding chrome: top bar, centre play/pause and the bottom glass control bar.
struct PlayerControlsOverlay: View {
    let player: PlayerModel
    let app: AppModel
    @Binding var showTech: Bool
    @Binding var hoveringControls: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                PlayerTopBar(player: player, app: app)
                    .onHover { hoveringControls = $0 }
                Spacer(minLength: 0)
                PlayerBottomBar(player: player, app: app, showTech: $showTech)
                    .onHover { hoveringControls = $0 }
            }
            PlayerCenterButton(player: player)
        }
    }
}

// MARK: - Top bar

struct PlayerTopBar: View {
    let player: PlayerModel
    let app: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PlayerIconButton(systemImage: "chevron.left", help: "Close player (Esc)", size: 18, diameter: 40, filled: true) {
                player.dismiss()
            }
            if let channel = player.currentChannel {
                TunaImage(url: channel.logoURL, kind: .channel, seed: channel.id, title: channel.name, contentMode: .fit)
                    .frame(width: 70, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(player.content?.displayTitle ?? "")
                        .font(Tuna.Fonts.display(21, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    if player.isLive { LiveBadge(compact: true) }
                }
                if let subtitle = subtitleLine {
                    Text(subtitle)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if player.versions.count > 1 {
                PlayerVersionsMenu(player: player)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 44)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.78), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var subtitleLine: String? {
        if let channel = player.currentChannel, player.isLive {
            guard let program = app.nowPlaying(on: channel) else { return channel.groupName }
            let start = program.start.formatted(date: .omitted, time: .shortened)
            let end = program.end.formatted(date: .omitted, time: .shortened)
            return "\(program.title) · \(start)–\(end)"
        }
        return player.content?.displaySubtitle
    }
}

/// Versions of the current title/channel ("4K · HDR10 · EN") → switchVariant.
struct PlayerVersionsMenu: View {
    let player: PlayerModel

    var body: some View {
        Menu {
            ForEach(Array(player.versions.enumerated()), id: \.element.id) { index, variant in
                Button {
                    player.switchVariant(variant)
                } label: {
                    if variant.id == player.content?.variant.id {
                        Label("\(index + 1). \(variant.label)", systemImage: "checkmark")
                    } else {
                        Text("\(index + 1). \(variant.label)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("\(player.versions.count) versions")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tuna.Palette.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .help("Switch version")
    }
}

// MARK: - Centre

struct PlayerCenterButton: View {
    let player: PlayerModel
    @State private var hovering = false

    var body: some View {
        if player.status == .playing || player.status == .paused {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 88, height: 88)
                    .tunaGlass(cornerRadius: 44)
                    .scaleEffect(hovering ? 1.06 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Tuna.Motion.hover, value: hovering)
            .help(player.status == .playing ? "Pause (Space)" : "Play (Space)")
        }
    }
}

// MARK: - Bottom bar

struct PlayerBottomBar: View {
    let player: PlayerModel
    let app: AppModel
    @Binding var showTech: Bool

    var body: some View {
        VStack(spacing: 12) {
            if player.isLive {
                PlayerLiveRow(player: player, app: app)
            } else {
                PlayerScrubber(player: player)
            }
            HStack(spacing: 10) {
                transport
                Spacer(minLength: 12)
                PlayerTrackMenu(player: player)
                PlayerIconButton(systemImage: player.isPictureInPicture ? "pip.exit" : "pip.enter",
                                 help: "Picture in Picture") {
                    player.togglePictureInPicture()
                }
                PlayerIconButton(systemImage: "info.circle", help: "Stream info (I)", isActive: showTech) {
                    showTech.toggle()
                }
                PlayerVolumeControl(player: player)
                PlayerIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Full screen (F)") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .tunaGlass(cornerRadius: 22)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var transport: some View {
        PlayerIconButton(systemImage: player.status == .playing ? "pause.fill" : "play.fill",
                         help: "Play / Pause (Space)", size: 20) {
            player.togglePlayPause()
        }
        if !player.isLive {
            PlayerIconButton(systemImage: "gobackward.10", help: "Back 10 seconds (←)") {
                player.skip(by: -10)
            }
            PlayerIconButton(systemImage: "goforward.10", help: "Forward 10 seconds (→)") {
                player.skip(by: 10)
            }
        }
        if isEpisode {
            PlayerIconButton(systemImage: "forward.end.fill", help: "Next episode") {
                player.remoteNext()
            }
        }
        if player.isLive {
            PlayerIconButton(systemImage: "chevron.up", help: "Previous channel (↑)") {
                player.zapPrevious()
            }
            PlayerIconButton(systemImage: "chevron.down", help: "Next channel (↓)") {
                player.zapNext()
            }
        }
    }

    private var isEpisode: Bool {
        if case .episode? = player.content { return true }
        return false
    }
}

/// Live row: LIVE pill (tap → go live), "−03:20 behind" when timeshifted, the programme on air.
struct PlayerLiveRow: View {
    let player: PlayerModel
    let app: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.goLive()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(atEdge ? Tuna.Palette.live : Color.white.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(1.2)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(atEdge ? Tuna.Palette.live.opacity(0.85) : Color.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Jump to live (L)")

            if !atEdge {
                Text("−\(PlayerFormat.time(player.behindLive)) behind")
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .monospacedDigit()
            }

            if let program = programme {
                Text(program.title)
                    .font(Tuna.Fonts.cardTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                ProgressLine(fraction: program.progress(at: Date()), tint: Tuna.Palette.live, height: 3)
                    .frame(maxWidth: 240)
                Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var atEdge: Bool { player.behindLive < 5 }

    private var programme: Program? {
        guard let channel = player.currentChannel else { return nil }
        return app.nowPlaying(on: channel)
    }
}

// MARK: - Scrubber

/// VOD scrubber: hover time bubble with an optional cache-backed thumbnail, drag to seek, elapsed/remaining.
struct PlayerScrubber: View {
    let player: PlayerModel
    @State private var hoverFraction: Double?
    @State private var dragFraction: Double?
    @State private var preview: CGImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewFraction: Double = -1

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                bar(width: max(1, geometry.size.width))
            }
            .frame(height: 18)
            HStack {
                Text(PlayerFormat.time(shownFraction * player.duration))
                Spacer()
                Text("−" + PlayerFormat.time(max(0, player.duration - shownFraction * player.duration)))
            }
            .font(Tuna.Fonts.mono)
            .foregroundStyle(Tuna.Palette.textSecondary)
            .monospacedDigit()
        }
    }

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.position / player.duration))
    }

    private var shownFraction: Double { dragFraction ?? progressFraction }

    private var isActive: Bool { hoverFraction != nil || dragFraction != nil }

    private func bar(width: CGFloat) -> some View {
        let fraction = CGFloat(shownFraction)
        let thickness: CGFloat = isActive ? 7 : 4
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(height: thickness)
            Capsule()
                .fill(Tuna.Gradients.accent)
                .frame(width: max(thickness, width * fraction), height: thickness)
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: Color.black.opacity(0.4), radius: 3, x: 0, y: 1)
                .offset(x: width * fraction - 7)
                .opacity(isActive ? 1 : 0)
        }
        .frame(width: width, height: 18)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
            if let bubbleFraction = dragFraction ?? hoverFraction {
                PlayerScrubBubble(time: PlayerFormat.time(bubbleFraction * player.duration), image: preview)
                    .offset(x: bubbleOffset(bubbleFraction, width: width), y: -26)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                hovered(Double(location.x / width))
            } else {
                hoverFraction = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragFraction = clamp(Double(value.location.x / width))
                }
                .onEnded { value in
                    let target = clamp(Double(value.location.x / width)) * player.duration
                    dragFraction = nil
                    player.seek(to: target)
                }
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private func bubbleOffset(_ fraction: Double, width: CGFloat) -> CGFloat {
        let bubbleWidth = PlayerScrubBubble.width
        let x = width * CGFloat(fraction) - bubbleWidth / 2
        return min(max(0, x), max(0, width - bubbleWidth))
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private func hovered(_ raw: Double) {
        let fraction = clamp(raw)
        hoverFraction = fraction
        guard player.supportsScrubPreview, player.duration > 0 else {
            if preview != nil { preview = nil }
            return
        }
        guard abs(fraction - previewFraction) > 0.003 else { return }
        previewFraction = fraction
        previewTask?.cancel()
        let seconds = fraction * player.duration
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let image = await player.scrubPreview(at: seconds)
            guard !Task.isCancelled else { return }
            preview = image
        }
    }
}

/// Time label (and thumbnail when the engine has the frame cached) floating above the scrubber.
struct PlayerScrubBubble: View {
    static let width: CGFloat = 180
    let time: String
    let image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.width)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 4)
            }
            Text(time)
                .font(Tuna.Fonts.mono)
                .foregroundStyle(Color.white)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.78)))
        }
        .frame(width: Self.width)
    }
}

// MARK: - Menus and small controls

/// Audio + subtitle tracks with checkmarks.
struct PlayerTrackMenu: View {
    let player: PlayerModel

    var body: some View {
        Menu {
            if !player.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(player.audioTracks) { track in
                        Button {
                            player.selectAudio(track.id)
                        } label: {
                            trackLabel(track)
                        }
                    }
                }
            }
            Section("Subtitles") {
                Button {
                    player.selectSubtitle(nil)
                } label: {
                    if player.subtitleTracks.contains(where: { $0.isSelected }) {
                        Text("Off")
                    } else {
                        Label("Off", systemImage: "checkmark")
                    }
                }
                ForEach(player.subtitleTracks) { track in
                    Button {
                        player.selectSubtitle(track.id)
                    } label: {
                        trackLabel(track)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 34, height: 34)
        .disabled(player.audioTracks.isEmpty && player.subtitleTracks.isEmpty)
        .help("Audio and subtitles")
    }

    @ViewBuilder
    private func trackLabel(_ track: PlayerModel.TrackOption) -> some View {
        let text = track.detail.map { "\(track.name) — \($0)" } ?? track.name
        if track.isSelected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }
}

struct PlayerVolumeControl: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 4) {
            PlayerIconButton(systemImage: symbol, help: player.isMuted ? "Unmute (M)" : "Mute (M)") {
                player.isMuted.toggle()
            }
            Slider(value: level, in: 0...1)
                .controlSize(.small)
                .tint(Color.white)
                .frame(width: 92)
        }
    }

    private var level: Binding<Double> {
        Binding(
            get: { player.isMuted ? 0 : player.volume },
            set: { newValue in
                player.volume = newValue
                if newValue > 0, player.isMuted { player.isMuted = false }
            }
        )
    }

    private var symbol: String {
        if player.isMuted || player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Round icon button used across the player chrome.
struct PlayerIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 16
    var diameter: CGFloat = 34
    var filled: Bool = false
    var isActive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? Tuna.Palette.accent : Color.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.white.opacity(background)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Tuna.Motion.snappy, value: hovering)
    }

    private var background: Double {
        if filled { return hovering ? 0.24 : 0.14 }
        return hovering ? 0.14 : 0
    }
}
