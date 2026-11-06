import SwiftUI
import TunaCore

/// Pages pushed inside a tab's NavigationStack.
enum TVRoute: Hashable {
    case title(String)
    case person(id: Int, name: String)
    case shelf(VaultShelf)
    case genre(kind: TitleKind, genre: String)
}

// MARK: - Poster

/// 2:3 poster that lifts with the tvOS card effect; the caption sits below the card.
struct PosterCard: View {
    @Environment(TVModel.self) private var model
    var title: Title
    var width: CGFloat = Tuna.Metrics.posterWidth
    var showsCaption: Bool = true

    var body: some View {
        let display = TitleDisplay(title, model.metadata(for: title))
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: TVRoute.title(title.id)) {
                PosterArt(title: title, display: display)
                    .frame(width: width, height: width / Tuna.Metrics.posterAspect)
            }
            .buttonStyle(.card)
            if showsCaption {
                VStack(alignment: .leading, spacing: 4) {
                    Text(display.name)
                        .font(Tuna.Fonts.cardTitle)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    Text(display.caption)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .onAppear { model.requestMetadata(for: [title]) }
    }
}

/// The poster image with its quality corner badge.
struct PosterArt: View {
    var title: Title
    var display: TitleDisplay

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TVImage(url: display.posterURL, kind: .poster, seed: title.id, title: display.name, caption: display.caption)
            if title.bestQuality == .uhd {
                QualityBadge(quality: .uhd).padding(12)
            }
        }
    }
}

// MARK: - Landscape / Continue Watching

/// 16:9 backdrop card. With `progress` it resumes playback directly (Continue Watching).
struct LandscapeCard: View {
    @Environment(TVModel.self) private var model
    var title: Title
    var progress: WatchProgress? = nil
    var width: CGFloat = Tuna.Metrics.landscapeWidth

    var body: some View {
        let display = TitleDisplay(title, model.metadata(for: title))
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if progress != nil {
                    Button { model.play(title) } label: { art(display) }
                } else {
                    NavigationLink(value: TVRoute.title(title.id)) { art(display) }
                }
            }
            .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(display.name)
                    .font(Tuna.Fonts.cardTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle(display))
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .onAppear { model.requestMetadata(for: [title]) }
    }

    private func art(_ display: TitleDisplay) -> some View {
        ZStack(alignment: .bottomLeading) {
            TVImage(url: display.backdropURL, kind: .backdrop, seed: title.id, title: display.name)
            if let progress {
                LinearGradient(colors: [.clear, Color.black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 22, weight: .bold))
                    ProgressLine(fraction: progress.fraction, height: 7)
                }
                .foregroundStyle(Color.white)
                .padding(18)
            }
        }
        .frame(width: width, height: width * 9 / 16)
    }

    private func subtitle(_ display: TitleDisplay) -> String {
        guard let progress else { return display.caption }
        var parts: [String] = []
        if let code = TVFormat.episodeCode(season: progress.season, episode: progress.episode) { parts.append(code) }
        if progress.duration > 0 { parts.append(TVFormat.remaining(progress.remaining)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Top 10

/// Giant outlined numeral + poster.
struct Top10Card: View {
    var title: Title
    var rank: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: -36) {
            Text("\(rank)")
                .font(Tuna.Fonts.rank)
                .foregroundStyle(Tuna.Gradients.rankStroke)
                .shadow(color: .black.opacity(0.6), radius: 10)
                .frame(minWidth: rank >= 10 ? 230 : 130, alignment: .trailing)
                .offset(y: 30)
            PosterCard(title: title, width: Tuna.Metrics.top10PosterWidth, showsCaption: false)
        }
    }
}

// MARK: - Channel

/// Live channel tile: logo, name, now playing with progress. Selecting it plays the channel.
struct ChannelCard: View {
    @Environment(TVModel.self) private var model
    var channel: Channel
    var program: Program? = nil
    var width: CGFloat = Tuna.Metrics.channelCardWidth

    var body: some View {
        let now = program ?? model.nowPlaying(on: channel)
        VStack(alignment: .leading, spacing: 14) {
            Button { model.play(channel) } label: {
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Tuna.Palette.surfaceRaised, Tuna.Palette.surface],
                                   startPoint: .top, endPoint: .bottom)
                    TVImage(url: channel.logoURL, kind: .channel, seed: channel.id, title: channel.name, contentMode: .fit)
                        .padding(.horizontal, width * 0.18)
                        .padding(.vertical, width * 0.12)
                    if now.map({ LiveEventDetector.isLiveEvent($0) }) == true {
                        LiveBadge().padding(14)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(model.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites") {
                    model.toggleFavorite(channel)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(channel.name)
                    .font(Tuna.Fonts.cardTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                if let now {
                    Text(now.title)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                    ProgressLine(fraction: now.progress(at: Date()), height: 5, tint: Tuna.Palette.live)
                } else {
                    Text(channel.groupName ?? " ")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - Person

/// Round headshot with name and character.
struct PersonCard: View {
    var member: CastMember

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink(value: TVRoute.person(id: member.personID, name: member.name)) {
                TVImage(url: member.profileURL, kind: .person, seed: "person:\(member.personID)", title: member.name)
                    .frame(width: Tuna.Metrics.personSize, height: Tuna.Metrics.personSize)
                    .clipShape(Circle())
            }
            .buttonStyle(.card)
            .clipShape(Circle())
            Text(member.name)
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(1)
            if let character = member.character?.nonEmpty {
                Text(character)
                    .font(Tuna.Fonts.micro)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: Tuna.Metrics.personSize + 30)
    }
}

// MARK: - Row button style

/// List-row style for the focus engine: the row brightens, scales a little and gets a coral edge when focused.
struct TVRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVRowBody(configuration: configuration, selected: selected)
    }
}

private struct TVRowBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isFocused ? Tuna.Palette.accent : Color.clear, lineWidth: 3))
            .scaleEffect(isFocused ? 1.03 : (configuration.isPressed ? 0.98 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .animation(Tuna.Motion.snappy, value: isFocused)
    }

    private var background: Color {
        if isFocused { return Tuna.Palette.surfaceRaised }
        if selected { return Tuna.Palette.accent.opacity(0.18) }
        return Tuna.Palette.surface.opacity(0.6)
    }
}
