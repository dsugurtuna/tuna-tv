import SwiftUI
import TunaCore

// =====================================================================================================
// LIVE TV MAIN COLUMN. Scrolls: "On Now" live events, then a pinned header (shelf title, counts,
// Wall ⇄ Guide toggle) above an adaptive wall of ChannelCards. Now/next refresh on a 30 s clock aligned to
// the wall clock; the wall only ever renders the visible cards (LazyVGrid).
// =====================================================================================================

struct LiveMainColumn: View {
    let selection: LiveTVSelection
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var clock = Date()
    @State private var events: [LiveTVEvent] = []
    @State private var hasGuideData = true
    @State private var contentWidth: CGFloat = 0
    @State private var listMemo = LiveTVMemo<LiveTVListKey, LiveTVChannelList>()

    private static let topAnchor = "live.wall.top"
    static let trailingInset: CGFloat = 28

    init(selection: LiveTVSelection, reduceMotion: Bool) {
        self.selection = selection
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        let list = LiveTVChannels.list(selection, model: model, memo: listMemo)
        let playingID = LiveTVFormat.playingChannelID(model.player.content)
        let metrics = LiveTVGridMetrics(availableWidth: contentWidth)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(LiveMainColumn.topAnchor)
                    if !events.isEmpty {
                        LiveOnNowStrip(events: events, now: clock)
                            .padding(.bottom, 14)
                    }
                    LazyVGrid(columns: metrics.columns,
                              alignment: .leading,
                              spacing: LiveTVGridMetrics.spacing,
                              pinnedViews: [.sectionHeaders]) {
                        Section {
                            if contentWidth > 0 {
                                ForEach(Array(list.channels.enumerated()), id: \.element.id) { index, channel in
                                    LiveWallCell(channel: channel,
                                                 clock: clock,
                                                 width: metrics.cardWidth,
                                                 isPlaying: channel.id == playingID,
                                                 model: model)
                                        .staggeredAppear(index: index)
                                }
                            }
                        } header: {
                            LiveWallHeader(selection: selection, list: list, hasGuideData: hasGuideData) {
                                model.router.open(.guide)
                            }
                        }
                    }
                    if list.channels.isEmpty {
                        LiveSelectionEmptyState(selection: selection)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    contentWidth = width
                }
                .padding(.trailing, LiveMainColumn.trailingInset)
                .padding(.bottom, 56)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selection) { _, _ in
                proxy.scrollTo(LiveMainColumn.topAnchor, anchor: .top)
            }
        }
        .task(id: LiveTVDataStamp(guide: ObjectIdentifier(model.guide), library: ObjectIdentifier(model.library))) {
            refreshGuideFacts()
        }
        .task {
            await runClock()
        }
    }

    // MARK: Clock & live events

    /// Ticks on every :00 / :30 second boundary so all cards change programme at the same moment.
    private func runClock() async {
        while !Task.isCancelled {
            let seconds = Date().timeIntervalSince1970
            let wait = 30 - seconds.truncatingRemainder(dividingBy: 30) + 0.05
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { return }
            clock = Date()
            events = currentEvents(at: clock)
        }
    }

    private func refreshGuideFacts() {
        clock = Date()
        hasGuideData = !model.guide.channelKeys.isEmpty
        events = currentEvents(at: clock)
    }

    private func currentEvents(at date: Date) -> [LiveTVEvent] {
        guard hasGuideData else { return [] }
        let adult = model.adultUnlocked
        var seen = Set<String>()
        var result: [LiveTVEvent] = []
        for entry in model.liveEvents(at: date) {
            if entry.channel.isAdult && !adult { continue }
            let event = LiveTVEvent(channel: entry.channel, program: entry.program)
            guard seen.insert(event.id).inserted else { continue }
            result.append(event)
            if result.count == 14 { break }
        }
        return result
    }
}

// MARK: - Grid metrics

/// Card width for the adaptive wall: the same rule SwiftUI uses for `.adaptive(minimum: 280)` columns, so
/// ChannelCard can be given the exact width of its cell.
struct LiveTVGridMetrics {
    static let minimumCardWidth: CGFloat = 280
    static let spacing: CGFloat = 18

    let columnCount: Int
    let cardWidth: CGFloat

    init(availableWidth: CGFloat) {
        let minimum = LiveTVGridMetrics.minimumCardWidth
        let spacing = LiveTVGridMetrics.spacing
        let width = max(availableWidth, minimum)
        let count = max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
        columnCount = count
        let raw = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        cardWidth = max(minimum, raw.rounded(.down))
    }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: LiveTVGridMetrics.minimumCardWidth), spacing: LiveTVGridMetrics.spacing, alignment: .top)]
    }
}

// MARK: - Cells

private struct LiveWallCell: View {
    let channel: Channel
    let clock: Date
    let width: CGFloat
    let isPlaying: Bool
    let model: AppModel

    var body: some View {
        ChannelCard(channel: channel,
                    now: model.nowPlaying(on: channel, at: clock),
                    next: model.nextProgram(on: channel, at: clock),
                    isPlaying: isPlaying,
                    isFavorite: model.isFavorite(channel),
                    width: width) {
            model.play(channel)
        }
        .contextMenu {
            LiveTVChannelMenu(channel: channel, model: model)
        }
    }
}

// MARK: - Header

private struct LiveWallHeader: View {
    let selection: LiveTVSelection
    let list: LiveTVChannelList
    let hasGuideData: Bool
    let onGuide: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: selection.symbol)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(selection.tint)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(selection.tint.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(Tuna.Fonts.pageTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                Text(summary)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !hasGuideData {
                ViewThatFits(in: .horizontal) {
                    guideHint
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .help("Guide data appears after the first daily download")
                }
            }
            LiveModeToggle(onGuide: onGuide)
        }
        .padding(.vertical, 14)
        .background(alignment: .top) { backdrop }
    }

    private var summary: String {
        var parts = [LiveTVFormat.channelCount(list.channels.count)]
        if list.ultraHDCount > 0 { parts.append("\(list.ultraHDCount.formatted()) in 4K") }
        if list.catchupCount > 0 { parts.append("\(list.catchupCount.formatted()) with replay") }
        return parts.joined(separator: " · ")
    }

    private var guideHint: some View {
        Label("Guide data appears after the first daily download", systemImage: "calendar.badge.clock")
            .font(Tuna.Fonts.caption)
            .foregroundStyle(Tuna.Palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .tunaGlass(cornerRadius: 12)
    }

    /// Opaque at the top, fading below, so cards scroll away cleanly under the pinned header.
    private var backdrop: some View {
        LinearGradient(stops: [
            .init(color: Tuna.Palette.background.opacity(0.97), location: 0),
            .init(color: Tuna.Palette.background.opacity(0.9), location: 0.72),
            .init(color: Tuna.Palette.background.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .padding(.bottom, -22)
        .padding(.horizontal, -14)
        .allowsHitTesting(false)
    }
}

/// "Wall | Guide" segmented capsule. The wall is this screen; Guide opens the full TV guide page.
private struct LiveModeToggle: View {
    let onGuide: () -> Void

    @State private var isHoveringGuide = false

    var body: some View {
        HStack(spacing: 2) {
            Label("Wall", systemImage: "square.grid.2x2.fill")
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .background(Capsule().fill(Tuna.Palette.accent.opacity(0.24)))
                .overlay(Capsule().strokeBorder(Tuna.Palette.accent.opacity(0.45), lineWidth: 1))
                .accessibilityAddTraits(.isSelected)
            Button(action: onGuide) {
                Label("Guide", systemImage: "calendar.day.timeline.left")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(isHoveringGuide ? Tuna.Palette.textPrimary : Tuna.Palette.textSecondary)
                    .background(Capsule().fill(Color.white.opacity(isHoveringGuide ? 0.09 : 0)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringGuide = $0 }
            .help("Open the TV Guide")
        }
        .font(.system(size: 12, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .padding(3)
        .tunaGlass(cornerRadius: 20)
    }
}

// MARK: - Empty shelf

private struct LiveSelectionEmptyState: View {
    let selection: LiveTVSelection

    var body: some View {
        switch selection {
        case .favorites:
            EmptyStateView(symbol: "star",
                           title: "No favorites yet",
                           message: "Right-click any channel and choose Add to Favorites. They will be waiting for you here.")
        case .recents:
            EmptyStateView(symbol: "clock.arrow.circlepath",
                           title: "Nothing watched yet",
                           message: "Channels you watch show up here, newest first.")
        case .all, .category, .group:
            EmptyStateView(symbol: "tv",
                           title: "No channels here",
                           message: "This shelf is empty right now. Pick another category on the left.")
        }
    }
}
