import SwiftUI
import TunaCore

/// My List: saved titles (grid, remove on hover or from the context menu), Continue Watching (landscape cards
/// with progress and time left; click resumes) and recently watched channels (click tunes in).
struct MyListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init() {}

    private enum JumpTarget: String, Hashable, CaseIterable {
        case saved
        case resume
        case channels
    }

    /// Continue Watching entry with a stable identity.
    struct ResumeItem: Identifiable {
        let title: Title
        let progress: WatchProgress
        var id: String { "\(title.id)|\(progress.episodeRef?.id ?? "")" }
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    var body: some View {
        let saved = model.myList
        let resume = model.continueWatching.map { ResumeItem(title: $0.title, progress: $0.progress) }
        let channels = model.recentChannels
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Tuna.Metrics.sectionSpacing + 6) {
                    header(saved: saved.count, resume: resume.count, channels: channels.count, proxy: proxy)
                        .tunaPageInset()
                    if saved.isEmpty && resume.isEmpty && channels.isEmpty {
                        EmptyStateView(
                            symbol: "plus.rectangle.on.rectangle",
                            title: "Your list is waiting",
                            message: "Save movies and series with + to watch them later. What you start watching and the channels you tune in to will show up here too.",
                            actionTitle: "Browse Movies"
                        ) {
                            model.router.select(.movies)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        savedSection(saved)
                            .id(JumpTarget.saved)
                        resumeSection(resume)
                            .id(JumpTarget.resume)
                        channelSection(channels)
                            .id(JumpTarget.channels)
                    }
                }
                .padding(.top, Discover.Layout.pageTop)
                .padding(.bottom, Discover.Layout.pageBottom)
                .animation(reduceMotion ? nil : Tuna.Motion.page, value: saved.map(\.id))
                .animation(reduceMotion ? nil : Tuna.Motion.page, value: resume.map(\.id))
            }
            .ignoresSafeArea(edges: .top)
        }
        .task(id: saved.map(\.id)) {
            await requestMetadata(saved + resume.map { $0.title })
        }
    }

    // MARK: Header

    private func header(saved: Int, resume: Int, channels: Int, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("My List")
                .font(Tuna.Fonts.pageTitle)
                .tracking(-0.6)
                .foregroundStyle(Tuna.Palette.textPrimary)
            HStack(spacing: 8) {
                jump("Saved", count: saved, symbol: "plus.rectangle.on.rectangle", to: .saved, proxy: proxy)
                jump("Continue Watching", count: resume, symbol: "play.circle", to: .resume, proxy: proxy)
                jump("Channels", count: channels, symbol: "dot.radiowaves.left.and.right", to: .channels, proxy: proxy)
            }
        }
    }

    private func jump(_ label: String, count: Int, symbol: String, to section: JumpTarget, proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Tuna.Motion.page) {
                proxy.scrollTo(section, anchor: .top)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                Text(label)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("\(count)")
                    .font(Tuna.Fonts.micro)
                    .monospacedDigit()
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Tuna.Motion.snappy, value: count)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.55 : 1)
    }

    // MARK: Sections

    private func savedSection(_ saved: [Title]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Saved", subtitle: saved.isEmpty ? nil : "Hover a poster to remove it")
            if saved.isEmpty {
                Discover.InlineEmpty(
                    symbol: "plus",
                    title: "Nothing saved yet",
                    message: "Hit + on any movie or series and it will wait for you here.",
                    actionTitle: "Explore Series",
                    action: { model.router.select(.series) }
                )
            } else {
                Discover.PosterGrid(titles: saved, reduceMotion: reduceMotion) { (item: Title, width: CGFloat) in
                    MyListView.SavedCell(title: item, width: width)
                }
            }
        }
        .tunaPageInset()
    }

    @ViewBuilder
    private func resumeSection(_ items: [ResumeItem]) -> some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Continue Watching")
                Discover.InlineEmpty(
                    symbol: "play.circle",
                    title: "Nothing in progress",
                    message: "Start a movie or an episode and you can pick it up right here, to the second."
                )
            }
            .tunaPageInset()
        } else {
            RailScroller(title: "Continue Watching", subtitle: "Pick up right where you left off") {
                ForEach(items) { item in
                    LandscapeCard(
                        title: item.title,
                        metadata: model.metadata(for: item.title),
                        progress: item.progress,
                        subtitle: Discover.Format.resumeLine(item.progress)
                    ) {
                        model.play(item.title)
                    }
                    .discoverTitleMenu(item.title)
                    .transition(AnyTransition.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private func channelSection(_ channels: [Channel]) -> some View {
        if channels.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Recently Watched Channels")
                Discover.InlineEmpty(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "No channels yet",
                    message: "Channels you watch on Live TV show up here for a one-click return.",
                    actionTitle: "Open Live TV",
                    action: { model.router.select(.live) }
                )
            }
            .tunaPageInset()
        } else {
            RailScroller(title: "Recently Watched Channels", subtitle: "Tune back in") {
                ForEach(channels) { channel in
                    MyListView.ChannelCell(channel: channel)
                }
            }
        }
    }

    private func requestMetadata(_ titles: [Title]) async {
        guard !titles.isEmpty else { return }
        model.requestMetadata(for: titles)
    }
}

// MARK: - Cells

extension MyListView {
    /// Saved poster with a remove button that appears on hover (plus the standard context menu).
    struct SavedCell: View {
        let title: Title
        let width: CGFloat

        @Environment(AppModel.self) private var model
        @State private var isHovering = false

        init(title: Title, width: CGFloat) {
            self.title = title
            self.width = width
        }

        var body: some View {
            PosterCard(
                title: title,
                metadata: model.metadata(for: title),
                progress: model.progress(for: title),
                width: width
            ) {
                model.router.open(.title(title.id))
            }
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Tuna.Palette.strokeStrong, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from My List")
                .padding(8)
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(isHovering ? 1 : 0.6)
                .animation(Tuna.Motion.snappy, value: isHovering)
            }
            .onHover { hovering in isHovering = hovering }
            .contextMenu {
                Button {
                    model.play(title)
                } label: {
                    Label(Discover.Format.isResumable(model.progress(for: title)) ? "Resume" : "Play", systemImage: "play.fill")
                }
                Button(action: remove) {
                    Label("Remove from My List", systemImage: "minus.circle")
                }
                Divider()
                Button {
                    model.router.open(.title(title.id))
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }
        }

        private func remove() {
            withAnimation(Tuna.Motion.snappy) {
                if model.isInMyList(title) { model.toggleMyList(title) }
            }
            model.showToast("Removed \(title.name) from My List", style: .info)
        }
    }

    /// Recently watched channel with now/next, live state and favourite toggle in the context menu.
    struct ChannelCell: View {
        let channel: Channel

        @Environment(AppModel.self) private var model

        init(channel: Channel) {
            self.channel = channel
        }

        private var isPlaying: Bool {
            guard let content = model.player?.content else { return false }
            if case .channel(let playing, _) = content { return playing.id == channel.id }
            return false
        }

        var body: some View {
            ChannelCard(
                channel: channel,
                now: model.nowPlaying(on: channel),
                next: model.nextProgram(on: channel),
                isPlaying: isPlaying,
                isFavorite: model.isFavorite(channel)
            ) {
                model.play(channel)
            }
            .contextMenu {
                Button {
                    model.play(channel)
                } label: {
                    Label("Watch", systemImage: "play.fill")
                }
                Button {
                    withAnimation(Tuna.Motion.snappy) { model.toggleFavorite(channel) }
                } label: {
                    if model.isFavorite(channel) {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    } else {
                        Label("Add to Favorites", systemImage: "star")
                    }
                }
            }
        }
    }
}
