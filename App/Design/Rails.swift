import SwiftUI
import TunaCore

// MARK: - RailScroller

/// Horizontal rail with hover paging arrows, edge fades and lazy content.
/// Paging uses `ScrollPosition.scrollTo(x:)` computed from the live scroll geometry (≈ 80 % of the visible width).
struct RailScroller<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var position = ScrollPosition(edge: .leading)
    @State private var edges = DSRailEdges()
    @State private var metrics = DSRailMetrics()
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, subtitle: subtitle, seeAll: seeAll)
                .padding(.horizontal, Tuna.Metrics.pageInset)
            scroller
        }
        .onHover { inside in
            withAnimation(Tuna.Motion.snappy) { isHovering = inside }
        }
    }

    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Tuna.Metrics.railSpacing) {
                content()
            }
            .scrollTargetLayout()
            .padding(.horizontal, Tuna.Metrics.pageInset)
            .padding(.vertical, Tuna.Metrics.railVerticalPadding)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition($position)
        .onScrollGeometryChange(for: DSRailGeometry.self) { geometry in
            DSRailGeometry(offset: geometry.contentOffset.x,
                           contentWidth: geometry.contentSize.width,
                           containerWidth: geometry.containerSize.width)
        } action: { _, newValue in
            metrics.geometry = newValue
            let newEdges = DSRailEdges(newValue)
            if newEdges != edges {
                withAnimation(Tuna.Motion.snappy) { edges = newEdges }
            }
        }
        .mask { DSRailFadeMask(edges: edges) }
        .overlay(alignment: .leading) { chevron(isLeading: true) }
        .overlay(alignment: .trailing) { chevron(isLeading: false) }
    }

    @ViewBuilder
    private func chevron(isLeading: Bool) -> some View {
        let canScroll = isLeading ? edges.canScrollLeading : edges.canScrollTrailing
        if isHovering && canScroll {
            GlassButton(systemImage: isLeading ? "chevron.left" : "chevron.right", style: .icon) {
                page(isLeading ? -1 : 1)
            }
            .padding(.horizontal, 9)
            .transition(AnyTransition.opacity.combined(with: AnyTransition.scale(scale: 0.85)))
        }
    }

    private func page(_ direction: CGFloat) {
        let geometry = metrics.geometry
        let maxOffset = max(0, geometry.contentWidth - geometry.containerWidth)
        let proposed = geometry.offset + direction * geometry.containerWidth * 0.8
        let target = min(max(0, proposed), maxOffset)
        withAnimation(Tuna.Motion.scrollPage) {
            position.scrollTo(x: target)
        }
    }
}

struct DSRailGeometry: Equatable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
}

struct DSRailEdges: Equatable {
    var canScrollLeading = false
    var canScrollTrailing = false

    init() {}

    init(_ geometry: DSRailGeometry) {
        canScrollLeading = geometry.offset > 4
        canScrollTrailing = geometry.offset < geometry.contentWidth - geometry.containerWidth - 4
    }
}

/// Live scroll metrics kept in a reference so per-frame updates never re-render the rail.
final class DSRailMetrics {
    var geometry = DSRailGeometry()
}

private struct DSRailFadeMask: View {
    var edges: DSRailEdges

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(edges.canScrollLeading ? 0 : 1), Color.black],
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: 36)
            Color.black
            LinearGradient(colors: [Color.black, Color.black.opacity(edges.canScrollTrailing ? 0 : 1)],
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: 36)
        }
    }
}

// MARK: - RailView

/// Renders a TunaCore `Rail` in its style (poster, top10, landscape, channels, liveNow, people, continueWatching).
/// `.hero` renders nothing (Home draws its own hero).
struct RailView: View {
    var rail: Rail
    var onSelect: (RailItem) -> Void
    var onSeeAll: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if rail.style == .hero || rail.items.isEmpty {
            EmptyView()
        } else {
            RailScroller(title: rail.title, subtitle: rail.subtitle, seeAll: seeAllAction) {
                ForEach(indexedItems) { entry in
                    card(for: entry.item, index: entry.index)
                        .staggeredAppear(index: entry.index)
                }
            }
        }
    }

    private var seeAllAction: (() -> Void)? {
        guard let key = rail.seeAllKey, let onSeeAll else { return nil }
        return { onSeeAll(key) }
    }

    /// Items with their position, de-duplicated by id (ForEach needs unique ids).
    private var indexedItems: [DSIndexedRailItem] {
        var seen = Set<String>()
        var result: [DSIndexedRailItem] = []
        for item in rail.items where seen.insert(item.id).inserted {
            result.append(DSIndexedRailItem(index: result.count, item: item))
        }
        return result
    }

    @ViewBuilder
    private func card(for item: RailItem, index: Int) -> some View {
        switch item {
        case .title(let title):
            titleCard(title, progress: nil, index: index, item: item)
        case .progress(let title, let progress):
            titleCard(title, progress: progress, index: index, item: item)
        case .channel(let channel):
            ChannelCard(channel: channel,
                        now: model?.nowPlaying(on: channel),
                        next: model?.nextProgram(on: channel),
                        isPlaying: isPlaying(channel),
                        isFavorite: model?.isFavorite(channel) ?? false) {
                onSelect(item)
            }
        case .live(let channel, let program):
            ChannelCard(channel: channel,
                        now: program ?? model?.nowPlaying(on: channel),
                        next: model?.nextProgram(on: channel),
                        isPlaying: isPlaying(channel),
                        isFavorite: model?.isFavorite(channel) ?? false) {
                onSelect(item)
            }
        case .person(let member):
            PersonCard(member: member) {
                onSelect(item)
            }
        }
    }

    @ViewBuilder
    private func titleCard(_ title: Title, progress: WatchProgress?, index: Int, item: RailItem) -> some View {
        let metadata = model?.metadata[title.id]
        switch rail.style {
        case .top10:
            Top10Card(rank: index + 1, title: title, metadata: metadata) {
                onSelect(item)
            }
        case .landscape, .continueWatching:
            LandscapeCard(title: title,
                          metadata: metadata,
                          progress: progress,
                          subtitle: progress.map { RailView.progressSubtitle($0) }) {
                onSelect(item)
            }
        case .hero, .poster, .collections, .channels, .liveNow, .people:
            PosterCard(title: title, metadata: metadata, progress: progress) {
                onSelect(item)
            }
        }
    }

    private func isPlaying(_ channel: Channel) -> Bool {
        guard let player = model?.player, player.status.isActive, let content = player.content else { return false }
        if case .channel(let playing, _) = content { return playing.id == channel.id }
        return false
    }

    /// "S2 · E5" for episodes, otherwise "38 min left".
    static func progressSubtitle(_ progress: WatchProgress) -> String {
        if let season = progress.season, let episode = progress.episode {
            return "S\(season) · E\(episode)"
        }
        return DSDuration.remaining(seconds: progress.remaining)
    }
}

private struct DSIndexedRailItem: Identifiable {
    let index: Int
    let item: RailItem
    var id: String { item.id }
}
