import SwiftUI
import TunaCore

/// Movies / Series page: header with the showcase count and quality, genre chips, sort, filters and a
/// Rails ⇄ Grid toggle. Without filters it shows the curated rails; with any filter (or in Grid mode) it shows an
/// adaptive poster grid that reflows with a spring. "Surprise me" spins a slot-machine reel and opens a great pick.
struct BrowseView: View {
    let kind: TitleKind

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var filter = BrowseFilter()
    @State private var layout: LayoutMode = .rails
    @State private var showFilters = false
    @State private var surprise: SurprisePlan?

    init(kind: TitleKind) {
        self.kind = kind
    }

    enum LayoutMode: String, Hashable {
        case rails
        case grid
    }

    // MARK: Derived state

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var reflow: Animation? { reduceMotion ? nil : Tuna.Motion.page }

    private var rails: [Rail] {
        let source = kind == .movie ? model.movieRails : model.seriesRails
        return source.filter { $0.style != .hero }
    }

    /// Filters other than genre and sort (the badge on the Filters button).
    private var panelFilterCount: Int {
        var count = 0
        if filter.decade != nil { count += 1 }
        if filter.minRating != nil { count += 1 }
        if filter.country != nil { count += 1 }
        if filter.language != nil { count += 1 }
        if filter.minQuality != nil { count += 1 }
        return count
    }

    private var isFiltering: Bool {
        filter.genre != nil || panelFilterCount > 0 || filter.sort != .recommended
    }

    private var showsRails: Bool { layout == .rails && !isFiltering }

    private var effectiveLayout: LayoutMode { showsRails ? .rails : .grid }

    private var showcaseCount: Int { model.library.showcase(kind).count }

    // MARK: Body

    var body: some View {
        let gridTitles: [Title] = showsRails ? [] : model.grid(kind, filter: filter)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                header(shown: showsRails ? showcaseCount : gridTitles.count)
                    .tunaPageInset()
                genreBar
                if isFiltering {
                    activeFilters
                        .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                }
                content(gridTitles)
            }
            .padding(.top, Discover.Layout.pageTop)
            .padding(.bottom, Discover.Layout.pageBottom)
            .animation(reflow, value: isFiltering)
        }
        .ignoresSafeArea(edges: .top)
        .overlay {
            if let surprise {
                BrowseView.SurpriseReel(
                    plan: surprise,
                    reduceMotion: reduceMotion,
                    onFinish: { (pick: Title) in finishSurprise(pick) },
                    onCancel: { cancelSurprise() }
                )
                .transition(AnyTransition.opacity)
            }
        }
        .onChange(of: kind) { _, _ in
            filter = BrowseFilter()
            layout = .rails
            surprise = nil
        }
    }

    // MARK: Header

    private func header(shown: Int) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Discover.Format.kindTitle(kind))
                    .font(Tuna.Fonts.pageTitle)
                    .tracking(-0.6)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                HStack(spacing: 12) {
                    Discover.CountText(count: shown)
                        .font(Tuna.Fonts.bodyLarge.weight(.medium))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                    if !showsRails && shown != showcaseCount {
                        Text("of \(showcaseCount)")
                            .font(Tuna.Fonts.bodyLarge)
                            .foregroundStyle(Tuna.Palette.textTertiary)
                            .transition(AnyTransition.opacity)
                    }
                    Discover.ShowcaseChip(
                        quality: model.settings.content.showcaseQuality,
                        relaxed: model.library.stats.showcaseRelaxed
                    ) {
                        model.router.isSettingsPresented = true
                    }
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                GlassButton(title: "Surprise me", systemImage: "die.face.5.fill", style: .secondary) {
                    startSurprise()
                }
                .help("Spin the reel for a great pick")
                Discover.SortMenu(selection: $filter.sort.animation(reflow))
                filtersButton
                BrowseView.LayoutToggle(selection: effectiveLayout) { (mode: LayoutMode) in
                    selectLayout(mode)
                }
            }
        }
    }

    private var filtersButton: some View {
        GlassButton(title: "Filters", systemImage: "line.3.horizontal.decrease.circle", style: .secondary) {
            showFilters.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if panelFilterCount > 0 {
                Text("\(panelFilterCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(Tuna.Palette.accent))
                    .offset(x: 6, y: -6)
                    .transition(AnyTransition.scale.combined(with: .opacity))
            }
        }
        .animation(Tuna.Motion.snappy, value: panelFilterCount)
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            BrowseView.FiltersPanel(
                filter: $filter.animation(reflow),
                countries: countryOptions,
                languages: languageOptions
            )
        }
    }

    @ViewBuilder
    private var genreBar: some View {
        let genres = model.genres(kind).map { $0.genre }
        if !genres.isEmpty {
            ChipBar(items: genres, selection: $filter.genre.animation(reflow), allLabel: "All")
                .tunaPageInset()
        }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filter.sort != .recommended {
                    token(Discover.Format.sortLabel(filter.sort), systemImage: Discover.Format.sortSymbol(filter.sort)) {
                        filter.sort = .recommended
                    }
                }
                if let genre = filter.genre {
                    token(genre, systemImage: "theatermasks.fill") { filter.genre = nil }
                }
                if let decade = filter.decade {
                    token(Discover.Format.decade(decade), systemImage: "calendar") { filter.decade = nil }
                }
                if let rating = filter.minRating {
                    token(Discover.Format.rating(rating), systemImage: "star.fill") { filter.minRating = nil }
                }
                if let country = filter.country {
                    token("\(Flags.emoji(for: country)) \(Discover.Format.country(country))", systemImage: nil) {
                        filter.country = nil
                    }
                }
                if let language = filter.language {
                    token(Discover.Format.language(language), systemImage: "character.bubble") { filter.language = nil }
                }
                if let quality = filter.minQuality {
                    token("\(quality.label)+", systemImage: "sparkles.tv") { filter.minQuality = nil }
                }
                Button("Clear all") { clearFilters() }
                    .buttonStyle(.plain)
                    .font(Tuna.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Tuna.Palette.accent)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, Tuna.Metrics.pageInset)
        }
    }

    private func token(_ label: String, systemImage: String?, remove: @escaping () -> Void) -> some View {
        Button {
            withAnimation(reflow) { remove() }
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
                Text(label)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Tuna.Palette.accent.opacity(0.14)))
            .overlay(Capsule(style: .continuous).strokeBorder(Tuna.Palette.accent.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Remove filter")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ gridTitles: [Title]) -> some View {
        if showsRails {
            if rails.isEmpty {
                emptyShowcase
            } else {
                Discover.RailStack(rails: rails, seeAllKind: kind)
                    .transition(AnyTransition.opacity)
            }
        } else if gridTitles.isEmpty {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing matches",
                message: "Try fewer filters. More versions and languages are waiting in The Vault.",
                actionTitle: "Clear filters"
            ) {
                clearFilters()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .transition(AnyTransition.opacity)
        } else {
            Discover.PosterGrid(titles: gridTitles, reduceMotion: reduceMotion) { (item: Title, width: CGFloat) in
                Discover.GridPoster(title: item, width: width)
            }
            .tunaPageInset()
            .transition(AnyTransition.opacity)
        }
    }

    private var emptyShowcase: some View {
        EmptyStateView(
            symbol: "shippingbox.fill",
            title: "No \(Discover.Format.kindTitle(kind).lowercased()) in your showcase yet",
            message: "Only \(Discover.Format.showcaseNoun(model.settings.content.showcaseQuality)) in your worlds appear here. Everything else is in The Vault.",
            actionTitle: "Open The Vault"
        ) {
            model.router.select(.vault)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Actions

    private func selectLayout(_ mode: LayoutMode) {
        withAnimation(reflow) {
            if mode == .rails {
                // Rails are the unfiltered, curated view.
                filter = BrowseFilter()
            }
            layout = mode
        }
    }

    private func clearFilters() {
        withAnimation(reflow) {
            filter = BrowseFilter()
        }
    }

    /// Countries present in this showcase, most common first (flags in the Filters panel).
    private var countryOptions: [String] {
        var counts: [String: Int] = [:]
        for title in model.library.showcase(kind) {
            for code in title.countries where code.count == 2 {
                counts[code.uppercased(), default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(48)
        .map { $0.key }
    }

    /// Languages present in this showcase, most common first.
    private var languageOptions: [String] {
        var counts: [String: Int] = [:]
        for title in model.library.showcase(kind) {
            for code in title.languages where !code.isEmpty {
                counts[code.lowercased(), default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(24)
        .map { $0.key }
    }

    // MARK: Surprise me

    private func startSurprise() {
        guard surprise == nil else { return }
        var topFilter = filter
        topFilter.sort = .topRated
        var pool = model.grid(kind, filter: topFilter)
        if pool.count < 6 {
            pool = model.grid(kind, filter: BrowseFilter(sort: .topRated))
        }
        let top = Array(pool.prefix(60))
        let acclaimed = top.filter { (model.metadata(for: $0)?.voteAverage ?? 0) >= 7 }
        guard let pick = (acclaimed.isEmpty ? top : acclaimed).randomElement() else {
            model.showToast("Nothing to pick from yet", style: .info)
            return
        }
        let fillers = model.library.showcase(kind).filter { $0.id != pick.id }.shuffled().prefix(19)
        var reel = Array(fillers)
        if reel.isEmpty { reel = [pick] }
        reel.append(pick)
        model.requestMetadata(for: Array(reel.suffix(6)))
        withAnimation(reduceMotion ? nil : Tuna.Motion.page) {
            surprise = SurprisePlan(reel: reel, pick: pick)
        }
    }

    private func finishSurprise(_ pick: Title) {
        model.router.open(.title(pick.id))
        withAnimation(Tuna.Motion.gentle) { surprise = nil }
    }

    private func cancelSurprise() {
        withAnimation(Tuna.Motion.snappy) { surprise = nil }
    }
}

// MARK: - Layout toggle

extension BrowseView {
    /// Rails ⇄ Grid segmented toggle with a sliding highlight.
    struct LayoutToggle: View {
        let selection: LayoutMode
        let onSelect: (LayoutMode) -> Void

        @Namespace private var highlight

        init(selection: LayoutMode, onSelect: @escaping (LayoutMode) -> Void) {
            self.selection = selection
            self.onSelect = onSelect
        }

        var body: some View {
            HStack(spacing: 2) {
                option(.rails, symbol: "rectangle.grid.1x2", help: "Rails: the curated view")
                option(.grid, symbol: "square.grid.3x2", help: "Grid: everything, sortable and filterable")
            }
            .padding(3)
            .tunaGlass(cornerRadius: 14)
            .animation(Tuna.Motion.snappy, value: selection)
        }

        private func option(_ mode: LayoutMode, symbol: String, help: String) -> some View {
            Button {
                onSelect(mode)
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selection == mode ? Tuna.Palette.textPrimary : Tuna.Palette.textTertiary)
                    .frame(width: 36, height: 30)
                    .background {
                        if selection == mode {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "layout", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

// MARK: - Filters panel

extension BrowseView {
    /// Popover: decade, minimum rating, country (flags), language and minimum quality.
    struct FiltersPanel: View {
        @Binding var filter: BrowseFilter
        let countries: [String]
        let languages: [String]

        init(filter: Binding<BrowseFilter>, countries: [String], languages: [String]) {
            self._filter = filter
            self.countries = countries
            self.languages = languages
        }

        private static let decades: [Int] = [1960, 1970, 1980, 1990, 2000, 2010, 2020]
        private static let qualities: [Quality] = [.hd, .fhd, .uhd]

        var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Filters")
                            .font(Tuna.Fonts.sectionTitle)
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        Spacer()
                        Button("Reset") {
                            filter = BrowseFilter(sort: filter.sort, genre: filter.genre)
                        }
                        .buttonStyle(.plain)
                        .font(Tuna.Fonts.caption.weight(.semibold))
                        .foregroundStyle(Tuna.Palette.accent)
                    }
                    group("Decade") { decadePicker }
                    group("Minimum rating") { ratingSlider }
                    if !countries.isEmpty {
                        group("Country") { countryPicker }
                    }
                    if !languages.isEmpty {
                        group("Language") { languagePicker }
                    }
                    group("Minimum quality") { qualityPicker }
                }
                .padding(22)
            }
            .frame(width: 400)
            .frame(maxHeight: 560)
            .preferredColorScheme(.dark)
        }

        private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(Tuna.Fonts.micro)
                    .tracking(1.6)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                content()
            }
        }

        private var decadePicker: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], alignment: .leading, spacing: 8) {
                Discover.ChoiceChip("Any", isSelected: filter.decade == nil) { filter.decade = nil }
                ForEach(Self.decades, id: \.self) { decade in
                    Discover.ChoiceChip(Discover.Format.decade(decade), isSelected: filter.decade == decade) {
                        filter.decade = filter.decade == decade ? nil : decade
                    }
                }
            }
        }

        private var ratingSlider: some View {
            let binding = Binding<Double>(
                get: { filter.minRating ?? 0 },
                set: { newValue in filter.minRating = newValue >= 0.5 ? newValue : nil }
            )
            return HStack(spacing: 14) {
                Image(systemName: "star.fill")
                    .foregroundStyle(Tuna.Palette.gold)
                Slider(value: binding, in: 0...9, step: 0.5)
                    .tint(Tuna.Palette.accent)
                Text(filter.minRating.map { Discover.Format.rating($0) } ?? "Any")
                    .font(Tuna.Fonts.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .frame(width: 44, alignment: .trailing)
            }
        }

        private var countryPicker: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(countries, id: \.self) { code in
                    let selected = filter.country == code
                    Button {
                        filter.country = selected ? nil : code
                    } label: {
                        FlagView(countryCode: code, size: 22)
                            .frame(width: 40, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selected ? Tuna.Palette.accent.opacity(0.22) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(selected ? Tuna.Palette.accent : Tuna.Palette.stroke, lineWidth: selected ? 1.5 : 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Discover.Format.country(code))
                }
            }
        }

        private var languagePicker: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                Discover.ChoiceChip("Any", isSelected: filter.language == nil) { filter.language = nil }
                ForEach(languages, id: \.self) { code in
                    Discover.ChoiceChip(Discover.Format.language(code), isSelected: filter.language == code) {
                        filter.language = filter.language == code ? nil : code
                    }
                }
            }
        }

        private var qualityPicker: some View {
            HStack(spacing: 8) {
                Discover.ChoiceChip("Any", isSelected: filter.minQuality == nil) { filter.minQuality = nil }
                ForEach(Self.qualities, id: \.self) { quality in
                    Discover.ChoiceChip("\(quality.label)+", systemImage: quality == .uhd ? "sparkles" : nil,
                                        isSelected: filter.minQuality == quality) {
                        filter.minQuality = filter.minQuality == quality ? nil : quality
                    }
                }
            }
        }
    }
}

// MARK: - Surprise me

extension BrowseView {
    struct SurprisePlan: Identifiable, Equatable {
        let id = UUID()
        /// Posters to spin through; the last one is the pick.
        let reel: [Title]
        let pick: Title
    }

    /// Slot-machine reel: posters flick past with decelerating timing, land on the pick with a glow, then the
    /// detail page opens. Reduce motion: a simple crossfade to the pick.
    struct SurpriseReel: View {
        let plan: SurprisePlan
        let reduceMotion: Bool
        let onFinish: (Title) -> Void
        let onCancel: () -> Void

        @Environment(AppModel.self) private var model
        @State private var position = 0
        @State private var landed = false
        @State private var appeared = false

        init(plan: SurprisePlan, reduceMotion: Bool, onFinish: @escaping (Title) -> Void, onCancel: @escaping () -> Void) {
            self.plan = plan
            self.reduceMotion = reduceMotion
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        private var current: Title {
            plan.reel[min(max(0, position), plan.reel.count - 1)]
        }

        var body: some View {
            ZStack {
                Color.black.opacity(0.8)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)
                VStack(spacing: 26) {
                    VStack(spacing: 6) {
                        Text(landed ? "TONIGHT'S PICK" : "SPINNING THE REEL")
                            .font(Tuna.Fonts.micro)
                            .tracking(2.6)
                            .foregroundStyle(landed ? Tuna.Palette.gold : Tuna.Palette.textTertiary)
                            .contentTransition(.opacity)
                        Text(landed ? plan.pick.name : "Finding something great…")
                            .font(Tuna.Fonts.sectionTitle)
                            .foregroundStyle(Tuna.Palette.textPrimary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    reelWindow
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(Tuna.Fonts.caption.weight(.semibold))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .keyboardShortcut(.cancelAction)
                        .opacity(landed ? 0 : 1)
                }
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
            }
            .ignoresSafeArea()
            .task { await spin() }
        }

        private var reelWindow: some View {
            ZStack {
                poster(current)
                    .id(position)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.push(from: .bottom))
            }
            .frame(width: 236, height: 354)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(landed ? Tuna.Palette.gold : Tuna.Palette.strokeStrong, lineWidth: landed ? 2 : 1)
            )
            .shadow(color: landed ? Tuna.Palette.accent.opacity(0.55) : Color.black.opacity(0.5), radius: landed ? 46 : 22, y: 12)
            .scaleEffect(landed && !reduceMotion ? 1.06 : 1)
            .background {
                // Reel housing: two soft light bars that brighten when the reel lands.
                HStack(spacing: 236 + 36) {
                    Capsule().fill(Tuna.Gradients.accent)
                    Capsule().fill(Tuna.Gradients.accent)
                }
                .frame(height: 300)
                .frame(width: 236 + 36 + 8)
                .opacity(landed ? 0.9 : 0.35)
                .blur(radius: landed ? 10 : 4)
            }
        }

        private func poster(_ title: Title) -> some View {
            TunaImage(
                url: model.metadata(for: title)?.posterURL ?? title.posterURL,
                kind: .poster,
                seed: title.id,
                title: title.name
            )
            .frame(width: 236, height: 354)
            .clipped()
        }

        private func spin() async {
            withAnimation(Tuna.Motion.page) { appeared = true }
            let last = plan.reel.count - 1
            if !reduceMotion && last > 0 {
                for step in 1...last {
                    let progress = Double(step) / Double(last)
                    let delay = 0.05 + 0.36 * pow(progress, 2.6)
                    withAnimation(.easeOut(duration: min(0.32, delay * 0.92))) { position = step }
                    guard await Self.sleep(delay) else { return }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { position = max(0, last) }
                guard await Self.sleep(0.35) else { return }
            }
            withAnimation(Tuna.Motion.hover) { landed = true }
            guard await Self.sleep(1.0) else { return }
            onFinish(plan.pick)
        }

        private static func sleep(_ seconds: Double) async -> Bool {
            do {
                try await Task.sleep(for: .seconds(seconds))
                return true
            } catch {
                return false
            }
        }
    }
}
