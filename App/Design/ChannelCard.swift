import SwiftUI
import TunaCore

/// Live channel tile: logo on a colour-sampled gradient, now/next with progress, quality badge, flag.
/// LIVE pill when the current programme is live, heart when favourite, coral glow ring while playing.
struct ChannelCard: View {
    var channel: Channel
    var now: Program?
    var next: Program?
    var isPlaying: Bool = false
    var isFavorite: Bool = false
    var width: CGFloat = Tuna.Metrics.channelCardWidth
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isHovering = false

    private var tileHeight: CGFloat { (width * 0.5).rounded() }
    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                DSChannelTile(channel: channel,
                              isLive: now?.isLive ?? false,
                              isPlaying: isPlaying,
                              isFavorite: isFavorite,
                              isHovering: isHovering,
                              animated: !reduceMotion)
                    .frame(width: width, height: tileHeight)
                DSChannelInfo(channel: channel, now: now, next: next)
                    .padding(.horizontal, 2)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSCardPressStyle())
        .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
        .zIndex(isHovering ? 10 : 0)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { isHovering = inside }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [channel.name]
        if let now { parts.append("now: \(now.title)") }
        if isPlaying { parts.append("playing") }
        return parts.joined(separator: ", ")
    }
}

private struct DSChannelTile: View {
    var channel: Channel
    var isLive: Bool
    var isPlaying: Bool
    var isFavorite: Bool
    var isHovering: Bool
    var animated: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tuna.Metrics.cardRadius, style: .continuous)
        let source = DSImageSource(channel.logoURL)
        let artSeed = source.demoSeed ?? channel.id
        ZStack {
            DSRemoteArtwork(source: source, kind: .channel, seed: artSeed) { loaded in
                DSChannelLogoTile(image: loaded.image, traits: loaded.traits, seed: artSeed)
            } fallback: {
                GenerativeArtwork(kind: .channel, seed: artSeed, title: channel.name)
            }
            DSChannelTileChrome(channel: channel, isLive: isLive, isPlaying: isPlaying, isFavorite: isFavorite,
                                animated: animated)
        }
        .clipShape(shape)
        .overlay { ring(shape) }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowOffset)
    }

    private var shadowColor: Color {
        if isPlaying { return Tuna.Palette.accent.opacity(0.5) }
        return Color.black.opacity(isHovering ? 0.45 : 0.2)
    }

    private var shadowRadius: CGFloat {
        if isPlaying { return 16 }
        return isHovering ? 18 : 6
    }

    private var shadowOffset: CGFloat {
        if isPlaying { return 0 }
        return isHovering ? 10 : 3
    }

    @ViewBuilder
    private func ring(_ shape: RoundedRectangle) -> some View {
        if isPlaying {
            shape.strokeBorder(Tuna.Gradients.accent, lineWidth: 2.5)
        } else {
            shape.strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.08), lineWidth: 1)
        }
    }
}

/// Real logo fitted on a gradient sampled from the logo's own colours (dark logos get a light tile).
private struct DSChannelLogoTile: View {
    var image: Image
    var traits: ImagePipeline.Traits?
    var seed: String

    private var prefersLightTile: Bool { (traits?.luminance ?? 0.6) < 0.26 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                tileBackground
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width * 0.56, height: proxy.size.height * 0.5)
                    .shadow(color: Color.black.opacity(prefersLightTile ? 0.1 : 0.35), radius: 6, x: 0, y: 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private var tileBackground: some View {
        if prefersLightTile {
            LinearGradient(colors: [Color(white: 0.97), Color(white: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            let base = traits?.color ?? DSArtPalette.forSeed(seed).sky[2]
            ZStack {
                LinearGradient(colors: [base.tunaBlend(with: Color.black, amount: 0.35),
                                        base.tunaBlend(with: Tuna.Palette.background, amount: 0.8)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                RadialGradient(colors: [base.opacity(0.4), Color.clear], center: .topTrailing, startRadius: 0, endRadius: 240)
            }
        }
    }
}

/// Badges drawn on top of the tile.
private struct DSChannelTileChrome: View {
    var channel: Channel
    var isLive: Bool
    var isPlaying: Bool
    var isFavorite: Bool
    var animated: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if isLive {
                    LiveBadge(compact: true)
                }
                Spacer(minLength: 0)
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Tuna.Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .overlay { Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5) }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 5) {
                if let country = channel.countries.first {
                    FlagView(countryCode: country, size: 13)
                }
                if channel.bestQuality != .unknown {
                    QualityBadge(quality: channel.bestQuality, compact: true)
                }
                if let days = channel.catchupDays, days > 0 {
                    DSCatchupBadge(days: days)
                }
                Spacer(minLength: 0)
                if isPlaying {
                    DSPlayingBadge(animated: animated)
                }
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}

private struct DSCatchupBadge: View {
    var days: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 8.5, weight: .bold))
            Text(String(days) + "d")
                .font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 5)
        .frame(height: Tuna.Metrics.badgeCompactHeight)
        .background(Color.black.opacity(0.45), in: Capsule())
        .help("Catch-up: \(days) days")
    }
}

private struct DSPlayingBadge: View {
    var animated: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animated)
            Text("Playing")
                .font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 7)
        .frame(height: 17)
        .background(Tuna.Gradients.accent, in: Capsule())
    }
}

/// Channel name, now (title + progress) and next.
private struct DSChannelInfo: View {
    var channel: Channel
    var now: Program?
    var next: Program?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(channel.name)
                    .font(Tuna.Fonts.cardTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let number = channel.number {
                    Text(String(number))
                        .font(Tuna.Fonts.monoSmall)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                }
            }
            if let now {
                Text(now.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ProgressLine(fraction: now.progress(at: context.date), tint: Tuna.Palette.accent, height: 3)
                }
                .frame(height: 3)
            } else {
                Text(fallbackLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
            if let next {
                Text(nextLine(next))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var fallbackLine: String {
        if let group = channel.groupName, !group.isEmpty { return group }
        if let category = channel.categories.first { return category.title }
        return "Live channel"
    }

    private func nextLine(_ program: Program) -> String {
        "Next: " + program.start.formatted(date: .omitted, time: .shortened) + " · " + program.title
    }
}
