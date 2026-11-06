import SwiftUI
import TunaCore

// =====================================================================================================
// DISCOVER (owner: home-browse). Building blocks shared by Home, Browse, See All and My List:
// layout constants, formatting, rail routing, card context menus, the adaptive poster grid, skeletons
// and small chips. Everything is namespaced under `Discover` so it never collides with other features.
// =====================================================================================================

enum Discover {}

// MARK: - Layout

extension Discover {
    /// Plain (nonisolated) constants so layout closures such as `containerRelativeFrame` may read them.
    enum Layout {
        /// The Home hero never gets shorter than this.
        static let heroMinimumHeight: CGFloat = 520
        /// How far the first Home rail slides up over the hero's bottom edge.
        static let railOverlap: CGFloat = 90
        /// Top padding for pages without a hero (content scrolls under the floating top bar).
        static let pageTop: CGFloat = Tuna.Metrics.topBarHeight + 30
        static let pageBottom: CGFloat = 72
        static let gridMinimum: CGFloat = 168
        static let gridSpacing: CGFloat = 18
        /// Muted hero trailer: mounted (invisible) after this many seconds on a slide…
        static let trailerPreload: Double = 1.5
        /// …and faded in no earlier than this, once the player reports that it is really playing.
        static let trailerReveal: Double = 4.0
        /// How long the muted hero trailer plays before the backdrop returns.
        static let trailerDwell: Double = 26
    }
}

// MARK: - Formatting

extension Discover {
    enum Format {
        /// 134 -> "2h 14m", 45 -> "45m", 120 -> "2h".
        static func runtime(minutes: Int) -> String {
            let total = max(0, minutes)
            let hours = total / 60
            let rest = total % 60
            if hours == 0 { return "\(rest)m" }
            if rest == 0 { return "\(hours)h" }
            return "\(hours)h \(rest)m"
        }

        /// "1h 12m left", "34m left".
        static func timeLeft(seconds: Double) -> String {
            guard seconds.isFinite, seconds >= 60 else { return "Less than 1m left" }
            return runtime(minutes: Int((seconds / 60).rounded())) + " left"
        }

        static func seasons(_ count: Int) -> String { count == 1 ? "1 Season" : "\(count) Seasons" }

        /// "S2 E5" for episode progress, nil for movies.
        static func episodeTag(_ progress: WatchProgress) -> String? {
            guard let season = progress.season, let episode = progress.episode else { return nil }
            return "S\(season) E\(episode)"
        }

        /// "S2 E5 · 34m left" / "1h 12m left".
        static func resumeLine(_ progress: WatchProgress) -> String {
            let left = timeLeft(seconds: progress.remaining)
            if let tag = episodeTag(progress) { return "\(tag) · \(left)" }
            return left
        }

        /// A progress worth resuming (started, not finished).
        static func isResumable(_ progress: WatchProgress?) -> Bool {
            guard let progress else { return false }
            return !progress.isFinished && progress.position > 30
        }

        static func kindTitle(_ kind: TitleKind) -> String {
            switch kind {
            case .movie: return "Movies"
            case .series: return "Series"
            }
        }

        static func kindKicker(_ kind: TitleKind) -> String {
            switch kind {
            case .movie: return "MOVIE"
            case .series: return "SERIES"
            }
        }

        /// Chip text: "4K showcase".
        static func showcaseChip(_ quality: ShowcaseQuality) -> String {
            switch quality {
            case .ultraOnly: return "4K showcase"
            case .fullHDPlus: return "Full HD+ showcase"
            case .everything: return "All qualities"
            }
        }

        /// Sentence fragment: "4K titles in your worlds".
        static func showcaseNoun(_ quality: ShowcaseQuality) -> String {
            switch quality {
            case .ultraOnly: return "4K titles"
            case .fullHDPlus: return "Full HD and 4K titles"
            case .everything: return "titles"
            }
        }

        static func sortLabel(_ sort: BrowseFilter.Sort) -> String {
            switch sort {
            case .recommended: return "Recommended"
            case .topRated: return "Top Rated"
            case .newest: return "Newest"
            case .recentlyAdded: return "Recently Added"
            case .alphabetical: return "A–Z"
            case .popularity: return "Most Popular"
            }
        }

        static func sortSymbol(_ sort: BrowseFilter.Sort) -> String {
            switch sort {
            case .recommended: return "sparkles"
            case .topRated: return "star.fill"
            case .newest: return "calendar"
            case .recentlyAdded: return "clock.arrow.circlepath"
            case .alphabetical: return "textformat"
            case .popularity: return "flame.fill"
            }
        }

        /// 1990 -> "1990s".
        static func decade(_ year: Int) -> String { "\(year)s" }

        /// 7 -> "7+", 7.5 -> "7.5+".
        static func rating(_ value: Double) -> String {
            if value.rounded() == value { return "\(Int(value))+" }
            return String(format: "%.1f+", value)
        }

        static func language(_ code: String) -> String {
            guard let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty else {
                return code.uppercased()
            }
            return name.prefix(1).uppercased() + name.dropFirst()
        }

        static func country(_ code: String) -> String {
            Locale.current.localizedString(forRegionCode: code) ?? code.uppercased()
        }
    }
}

// MARK: - Rails

extension Discover {
    /// Default selection routing for every rail on Home and Browse.
    @MainActor
    static func open(_ item: RailItem, model: AppModel) {
        switch item {
        case .title(let title):
            model.router.open(.title(title.id))
        case .progress(let title, _):
            model.router.open(.title(title.id))
        case .channel(let channel):
            model.play(channel)
        case .live(let channel, _):
            model.play(channel)
        case .person(let member):
            model.router.open(.person(id: member.personID, name: member.name))
        }
    }

    /// Titles of a rail (for metadata requests), in rail order.
    static func titles(in rail: Rail, limit: Int = 24) -> [Title] {
        var result: [Title] = []
        for item in rail.items.prefix(limit) {
            switch item {
            case .title(let title), .progress(let title, _):
                result.append(title)
            case .channel, .live, .person:
                break
            }
        }
        return result
    }

    /// Lazy stack of `RailView`s with selection routing, "See all" and visible-first metadata requests.
    struct RailStack: View {
        let rails: [Rail]
        /// Kind passed to "See all" pages (nil on Home).
        let seeAllKind: TitleKind?

        @Environment(AppModel.self) private var model

        init(rails: [Rail], seeAllKind: TitleKind?) {
            self.rails = rails
            self.seeAllKind = seeAllKind
        }

        var body: some View {
            LazyVStack(alignment: .leading, spacing: Tuna.Metrics.sectionSpacing) {
                ForEach(Array(rails.enumerated()), id: \.element.id) { index, rail in
                    RailView(
                        rail: rail,
                        onSelect: { (item: RailItem) in Discover.open(item, model: model) },
                        onSeeAll: { (key: String) in
                            model.router.open(.seeAll(key: key, title: rail.title, kind: seeAllKind))
                        }
                    )
                    .staggeredAppear(index: min(index, 8))
                    .onAppear { model.requestMetadata(for: Discover.titles(in: rail)) }
                }
            }
        }
    }
}

// MARK: - Card context menu

extension Discover {
    /// Play / My List / More Info on any title card.
    struct TitleMenu: ViewModifier {
        let title: Title

        @Environment(AppModel.self) private var model

        init(title: Title) { self.title = title }

        func body(content: Content) -> some View {
            content.contextMenu {
                Button {
                    model.play(title)
                } label: {
                    Label(Discover.Format.isResumable(model.progress(for: title)) ? "Resume" : "Play", systemImage: "play.fill")
                }
                Button {
                    withAnimation(Tuna.Motion.snappy) { model.toggleMyList(title) }
                } label: {
                    if model.isInMyList(title) {
                        Label("Remove from My List", systemImage: "checkmark")
                    } else {
                        Label("Add to My List", systemImage: "plus")
                    }
                }
                Divider()
                Button {
                    model.router.open(.title(title.id))
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }
        }
    }
}

extension View {
    /// Context menu with Play / Add to My List / More Info for a title card.
    func discoverTitleMenu(_ title: Title) -> some View {
        modifier(Discover.TitleMenu(title: title))
    }
}

// MARK: - Poster grid

extension Discover {
    /// Adaptive poster grid (`.adaptive(minimum: 168)`, spacing 18). Cards are sized to the real column width,
    /// changes reflow with a spring, and metadata is requested in batches as rows appear.
    struct PosterGrid<Cell: View>: View {
        let titles: [Title]
        let reduceMotion: Bool
        let cell: (Title, CGFloat) -> Cell

        @Environment(AppModel.self) private var model
        @State private var availableWidth: CGFloat = 0

        init(titles: [Title], reduceMotion: Bool, @ViewBuilder cell: @escaping (Title, CGFloat) -> Cell) {
            self.titles = titles
            self.reduceMotion = reduceMotion
            self.cell = cell
        }

        /// Matches how `.adaptive` distributes the row: as many minimum-width columns as fit, then stretched.
        private var cardWidth: CGFloat {
            let minimum = Discover.Layout.gridMinimum
            let spacing = Discover.Layout.gridSpacing
            guard availableWidth > minimum else { return minimum }
            let columns = max(1, Int((availableWidth + spacing) / (minimum + spacing)))
            let width = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            return max(minimum, width.rounded(.down))
        }

        var body: some View {
            let width = cardWidth
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Discover.Layout.gridMinimum), spacing: Discover.Layout.gridSpacing, alignment: .top)],
                alignment: .leading,
                spacing: Discover.Layout.gridSpacing + 12
            ) {
                ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                    cell(title, width)
                        .staggeredAppear(index: index < 24 ? index : 0)
                        .transition(AnyTransition.scale(scale: 0.9).combined(with: .opacity))
                        .onAppear { prefetch(from: index) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                availableWidth = newWidth
            }
            .animation(reduceMotion ? nil : Tuna.Motion.page, value: titles.map(\.id))
        }

        private func prefetch(from index: Int) {
            guard index % 12 == 0, index < titles.count else { return }
            let end = min(titles.count, index + 36)
            model.requestMetadata(for: Array(titles[index..<end]))
        }
    }

    /// Standard grid cell: a `PosterCard` that opens the detail page, with the title context menu.
    struct GridPoster: View {
        let title: Title
        let width: CGFloat

        @Environment(AppModel.self) private var model

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
            .discoverTitleMenu(title)
        }
    }
}

// MARK: - Skeletons

extension Discover {
    /// Shimmering placeholder rail shown while the library boots.
    struct SkeletonRail: View {
        enum Kind { case poster, landscape }

        var kind: Kind = .poster
        var cards: Int = 10

        private var cardSize: CGSize {
            switch kind {
            case .poster:
                return CGSize(width: Tuna.Metrics.posterWidth, height: Tuna.Metrics.posterWidth / Tuna.Metrics.posterAspect)
            case .landscape:
                return CGSize(width: Tuna.Metrics.landscapeWidth, height: Tuna.Metrics.landscapeWidth * 9 / 16)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 200, height: 18)
                    .padding(.horizontal, Tuna.Metrics.pageInset)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tuna.Metrics.railSpacing) {
                        ForEach(0..<cards, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Tuna.Metrics.cardRadius, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: cardSize.width, height: cardSize.height)
                        }
                    }
                    .padding(.horizontal, Tuna.Metrics.pageInset)
                }
                .scrollDisabled(true)
            }
            .shimmering()
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Chips, counters, menus

extension Discover {
    /// Selectable capsule (filters, jump links).
    struct ChoiceChip: View {
        let label: String
        var systemImage: String? = nil
        var isSelected: Bool = false
        let action: () -> Void

        @State private var isHovering = false

        init(_ label: String, systemImage: String? = nil, isSelected: Bool = false, action: @escaping () -> Void) {
            self.label = label
            self.systemImage = systemImage
            self.isSelected = isSelected
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(label)
                        .font(Tuna.Fonts.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Tuna.Palette.background : Tuna.Palette.textPrimary)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Tuna.Palette.textPrimary : Color.white.opacity(isHovering ? 0.13 : 0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Tuna.Palette.stroke, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHovering = hovering }
            .animation(Tuna.Motion.snappy, value: isSelected)
            .animation(Tuna.Motion.snappy, value: isHovering)
        }
    }

    /// "1,234 titles" with a rolling-digits transition.
    struct CountText: View {
        let count: Int
        var singular: String = "title"
        var plural: String = "titles"

        var body: some View {
            Text("\(count) \(count == 1 ? singular : plural)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .animation(Tuna.Motion.snappy, value: count)
        }
    }

    /// Sort picker (BrowseFilter.Sort) in a glass capsule.
    struct SortMenu: View {
        @Binding var selection: BrowseFilter.Sort

        init(selection: Binding<BrowseFilter.Sort>) {
            self._selection = selection
        }

        var body: some View {
            Menu {
                Picker("Sort by", selection: $selection) {
                    ForEach(BrowseFilter.Sort.allCases, id: \.self) { sort in
                        Label(Discover.Format.sortLabel(sort), systemImage: Discover.Format.sortSymbol(sort))
                            .tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Discover.Format.sortLabel(selection), systemImage: "arrow.up.arrow.down")
                    .font(Tuna.Fonts.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .tunaGlass(cornerRadius: 16)
            .help("Sort order")
        }
    }

    /// "✦ 4K showcase" chip reflecting the showcase quality setting (opens Settings when tapped).
    struct ShowcaseChip: View {
        let quality: ShowcaseQuality
        let relaxed: Bool
        let action: () -> Void

        init(quality: ShowcaseQuality, relaxed: Bool, action: @escaping () -> Void) {
            self.quality = quality
            self.relaxed = relaxed
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Tuna.Gradients.uhdBadge)
                    Text(Discover.Format.showcaseChip(quality))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    if relaxed {
                        Text("· topped up")
                            .foregroundStyle(Tuna.Palette.warning)
                    }
                }
                .font(Tuna.Fonts.caption)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(Tuna.Palette.uhd.opacity(0.10)))
                .overlay(Capsule(style: .continuous).strokeBorder(Tuna.Palette.uhd.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(relaxed
                  ? "Your showcase was topped up with the next quality tier because there were not enough titles. Change it in Settings."
                  : "Only the best versions in your worlds make the showcase. Everything else is in The Vault.")
        }
    }

    /// Compact dashed "nothing here yet" card for page sections.
    struct InlineEmpty: View {
        let symbol: String
        let title: String
        let message: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil

        var body: some View {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tuna.Gradients.accent)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Tuna.Fonts.cardTitle)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text(message)
                        .font(Tuna.Fonts.body)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let actionTitle, let action {
                    GlassButton(title: actionTitle, style: .secondary, action: action)
                }
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous)
                    .fill(Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous)
                    .strokeBorder(Tuna.Palette.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            )
        }
    }

    /// Opaque page background for pages pushed over a section (See all).
    struct PageBackground: View {
        var body: some View {
            ZStack(alignment: .top) {
                Tuna.Palette.background
                Tuna.Gradients.app
                    .frame(height: 560)
            }
            .ignoresSafeArea()
        }
    }
}
