import SwiftUI
import TunaCore

/// Section title above a rail.
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Tuna.Fonts.sectionTitle)
                .foregroundStyle(Tuna.Palette.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tunaPageInset()
    }
}

/// A horizontal, lazily built row of focusable cards. Lifted cards are never clipped.
struct HorizontalRail<Content: View>: View {
    var spacing: CGFloat = Tuna.Metrics.railSpacing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) {
                content()
            }
            .tunaPageInset()
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .focusSection()
    }
}

/// One model rail (`RailComposer` output) drawn with the card that fits its style.
struct RailSection: View {
    var rail: Rail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: rail.title, subtitle: rail.subtitle)
            HorizontalRail {
                ForEach(Array(rail.items.enumerated()), id: \.element.id) { index, item in
                    RailItemCard(item: item, style: rail.style, index: index)
                }
            }
        }
    }
}

/// Card for one rail item, chosen by the rail style (and the item kind as a fallback).
struct RailItemCard: View {
    var item: RailItem
    var style: RailStyle
    var index: Int

    var body: some View {
        switch item {
        case .title(let title):
            titleCard(title)
        case .progress(let title, let progress):
            LandscapeCard(title: title, progress: progress)
        case .channel(let channel):
            ChannelCard(channel: channel)
        case .live(let channel, let program):
            ChannelCard(channel: channel, program: program)
        case .person(let member):
            PersonCard(member: member)
        }
    }

    @ViewBuilder
    private func titleCard(_ title: Title) -> some View {
        switch style {
        case .top10:
            Top10Card(title: title, rank: index + 1)
        case .landscape, .hero, .continueWatching:
            LandscapeCard(title: title)
        case .poster, .collections, .channels, .liveNow, .people:
            PosterCard(title: title)
        }
    }
}

/// Adaptive poster grid (search results, Vault shelves, genres, filmographies).
struct PosterGrid: View {
    var titles: [Title]

    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(Tuna.Metrics.posterWidth), spacing: 48, alignment: .top),
                                            count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
            ForEach(titles) { title in
                PosterCard(title: title)
            }
        }
        .focusSection()
    }
}

/// Grid of channel tiles.
struct ChannelGrid: View {
    var channels: [Channel]

    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(Tuna.Metrics.channelCardWidth), spacing: 48, alignment: .top),
                                            count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
            ForEach(channels) { channel in
                ChannelCard(channel: channel)
            }
        }
        .focusSection()
    }
}

/// Calm empty / loading state.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(Tuna.Gradients.accent)
            Text(title)
                .font(Tuna.Fonts.sectionTitle)
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(message)
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
        .padding(60)
        .frame(maxWidth: .infinity)
    }
}
