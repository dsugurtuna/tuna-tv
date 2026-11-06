import SwiftUI
import TunaCore

/// Full-bleed Home hero (~78% of the window height).
///
/// - Crossfading backdrops (new slide fades in on top, so there is no brightness dip) with a slow Ken Burns drift
///   that alternates direction per slide, plus a gentle scroll parallax. Both are off with reduce motion.
/// - Per-slide info column (kicker, logo or title, badges, meta line, tagline, overview, buttons) that animates in
///   with a stagger.
/// - Slide pills with live progress for the current slide; arrows on hover; auto-advance every
///   `Tuna.Motion.heroInterval` seconds, paused while hovered, scrolled away, covered by a page/player/sheet,
///   while the window is inactive and while a trailer plays.
/// - After a few seconds on a slide, a MUTED YouTube trailer fades in over the backdrop (only once it is really
///   playing; never for demo keys) when `settings.playback.heroTrailers` is on.
/// - A soft ambient colour bleed of the current backdrop spills under the first rails.
struct HeroCarousel: View {
    let titles: [Title]
    /// Freeze everything (e.g. while Home shows the trailer lightbox).
    var suspended: Bool
    /// Plays a trailer with sound. When nil, the trailer opens on YouTube.
    var onPlayTrailer: ((TrailerRequest) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openURL) private var openURL

    @State private var index = 0
    /// Increments on every slide change; drives slide identity, z-order and Ken Burns direction.
    @State private var serial = 0
    /// Auto-advance clock: time already spent on this slide before the current running segment.
    @State private var bankedTime: TimeInterval = 0
    @State private var segmentStart = Date()
    @State private var isHovering = false
    @State private var isOnScreen = true
    // Muted ambient trailer.
    @State private var ambientKey: String?
    @State private var ambientPlaying = false
    @State private var ambientRevealed = false
    @State private var trailerFinishedSlide: String?

    init(titles: [Title], suspended: Bool = false, onPlayTrailer: ((TrailerRequest) -> Void)? = nil) {
        self.titles = titles
        self.suspended = suspended
        self.onPlayTrailer = onPlayTrailer
    }

    /// A trailer the user asked to watch with sound.
    struct TrailerRequest: Identifiable, Equatable {
        let youtubeKey: String
        let titleName: String
        var id: String { youtubeKey }
    }

    var body: some View {
        if let current = currentTitle {
            stage(for: current)
        }
    }

    // MARK: - Derived state

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var safeIndex: Int {
        guard !titles.isEmpty else { return 0 }
        return min(max(0, index), titles.count - 1)
    }

    private var currentTitle: Title? { titles.isEmpty ? nil : titles[safeIndex] }

    /// Something sits on top of Home (a pushed page, search, settings, the player) or the window is inactive.
    private var isCovered: Bool {
        let router = model.router
        if router.section != .home || !router.stack.isEmpty || router.isSearchPresented || router.isSettingsPresented {
            return true
        }
        if controlActiveState == .inactive { return true }
        return model.player?.isPresented ?? false
    }

    private var ambientVisible: Bool { ambientKey != nil && ambientPlaying && ambientRevealed }

    private var isPaused: Bool { isHovering || !isOnScreen || suspended || isCovered || ambientVisible }

    private var currentTrailerKey: String? {
        guard let current = currentTitle else { return nil }
        return Self.playableTrailerKey(model.metadata(for: current))
    }

    private var trailerEligible: Bool {
        model.settings.playback.heroTrailers && !reduceMotion && isOnScreen && !suspended && !isCovered
            && currentTrailerKey != nil
    }

    /// A real YouTube key (demo content uses "demo…" keys that must never be embedded).
    static func playableTrailerKey(_ metadata: MediaMetadata?) -> String? {
        guard let key = metadata?.bestTrailer?.youtubeKey.tunaTrimmed, !key.isEmpty,
              !key.lowercased().hasPrefix("demo") else { return nil }
        return key
    }

    // MARK: - Stage

    private func stage(for current: Title) -> some View {
        let metadata = model.metadata(for: current)
        let backdropURL = metadata?.backdropURL ?? current.backdropURL
        return ZStack(alignment: .bottomLeading) {
            backdrop(current, url: backdropURL)
            scrims
            HeroCarousel.AmbientGlow(title: current, imageURL: backdropURL, serial: serial)
            info(current, metadata: metadata)
            controls
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { length, _ in
            max(Discover.Layout.heroMinimumHeight, length * Tuna.Metrics.heroHeightRatio)
        }
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .onScrollVisibilityChange(threshold: 0.3) { visible in isOnScreen = visible }
        .onChange(of: isPaused) { _, paused in clockPauseChanged(paused) }
        .onChange(of: titles.map(\.id)) { _, _ in titlesChanged() }
        .task(id: ClockKey(serial: serial, paused: isPaused, count: titles.count)) {
            await runClock()
        }
        .task(id: TrailerKey(serial: serial, slide: current.id, eligible: trailerEligible)) {
            await runAmbientTrailer()
        }
    }

    private var slideTransition: AnyTransition {
        let fade = reduceMotion ? 0.45 : 1.1
        return AnyTransition.asymmetric(
            insertion: AnyTransition.opacity.animation(.easeInOut(duration: fade)),
            // The outgoing slide stays opaque underneath until the new one has fully faded in.
            removal: AnyTransition.opacity.animation(.linear(duration: 0.2).delay(fade))
        )
    }

    private func backdrop(_ current: Title, url: String?) -> some View {
        let parallax: CGFloat = reduceMotion ? 0 : 0.35
        return ZStack {
            Tuna.Palette.background
            HeroCarousel.Backdrop(title: current, imageURL: url, flipped: serial % 2 == 1, drifting: !reduceMotion)
                .id("\(serial)|\(current.id)")
                .zIndex(Double(serial) + 1)
                .transition(slideTransition)
            if let key = ambientKey {
                HeroCarousel.TrailerWebView(youtubeKey: key, muted: true, interactive: false) { (event: TrailerEvent) in
                    trailerEvent(event)
                }
                .id(key)
                .opacity(ambientRevealed ? 1 : 0.001)
                .allowsHitTesting(false)
                .zIndex(Double(serial) + 1.5)
                .transition(AnyTransition.opacity.animation(.easeInOut(duration: 1.0)))
            }
        }
        .visualEffect { content, proxy in
            content.offset(y: max(0, -proxy.frame(in: .scrollView).minY) * parallax)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var scrims: some View {
        ZStack(alignment: .top) {
            Tuna.Gradients.heroSide
            Tuna.Gradients.heroScrim
            LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
        }
        .allowsHitTesting(false)
    }

    private func info(_ current: Title, metadata: MediaMetadata?) -> some View {
        let trailerKey = Self.playableTrailerKey(metadata)
        let actions = InfoActions(
            play: { model.play(current) },
            moreInfo: { model.router.open(.title(current.id)) },
            toggleList: { withAnimation(Tuna.Motion.snappy) { model.toggleMyList(current) } },
            trailer: { if let trailerKey { playTrailer(key: trailerKey, title: current) } }
        )
        return ZStack(alignment: .bottomLeading) {
            HeroCarousel.InfoColumn(
                title: current,
                metadata: metadata,
                rank: topRank(of: current),
                progress: model.progress(for: current),
                isInMyList: model.isInMyList(current),
                hasTrailer: trailerKey != nil,
                reduceMotion: reduceMotion,
                actions: actions
            )
            .id(current.id)
            .transition(AnyTransition.asymmetric(
                insertion: AnyTransition.identity,
                removal: AnyTransition.opacity.animation(.easeOut(duration: 0.22))
            ))
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.leading, Tuna.Metrics.pageInset)
        .padding(.trailing, 24)
        .padding(.bottom, Discover.Layout.railOverlap + 52)
    }

    private var controls: some View {
        ZStack(alignment: .bottomTrailing) {
            if titles.count > 1 {
                HStack {
                    GlassButton(systemImage: "chevron.left", style: .icon) { show(safeIndex - 1) }
                        .help("Previous")
                    Spacer(minLength: 0)
                    GlassButton(systemImage: "chevron.right", style: .icon) { show(safeIndex + 1) }
                        .help("Next")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, Discover.Layout.railOverlap)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(isHovering ? 1 : 0)
                .animation(Tuna.Motion.snappy, value: isHovering)
            }
            HStack(spacing: 10) {
                if ambientVisible, let key = ambientKey, let current = currentTitle {
                    GlassButton(systemImage: "speaker.slash.fill", style: .icon) {
                        playTrailer(key: key, title: current)
                    }
                    .help("Watch the trailer with sound")
                    .transition(AnyTransition.scale(scale: 0.8).combined(with: .opacity))
                }
                if titles.count > 1 {
                    HeroCarousel.Pills(
                        count: titles.count,
                        index: safeIndex,
                        bankedTime: bankedTime,
                        segmentStart: segmentStart,
                        paused: isPaused,
                        interval: Tuna.Motion.heroInterval
                    ) { (target: Int) in
                        show(target)
                    }
                }
            }
            .animation(Tuna.Motion.snappy, value: ambientVisible)
            .padding(.trailing, Tuna.Metrics.pageInset)
            .padding(.bottom, Discover.Layout.railOverlap + 58)
        }
    }

    // MARK: - Ranking

    /// "#2 in Movies Today" when the title sits in a Top 10 rail on Home.
    private func topRank(of title: Title) -> RankInfo? {
        for rail in model.homeRails where rail.style == .top10 {
            for (offset, item) in rail.items.enumerated() {
                switch item {
                case .title(let candidate), .progress(let candidate, _):
                    if candidate.id == title.id {
                        return RankInfo(rank: offset + 1, label: "#\(offset + 1) in \(Discover.Format.kindTitle(title.kind)) Today")
                    }
                case .channel, .live, .person:
                    continue
                }
            }
        }
        return nil
    }

    // MARK: - Slides

    private func show(_ requested: Int) {
        let count = titles.count
        guard count > 1 else { return }
        let target = ((requested % count) + count) % count
        guard target != safeIndex else { return }
        bankedTime = 0
        segmentStart = Date()
        withAnimation(reduceMotion ? Animation.easeInOut(duration: 0.45) : Tuna.Motion.heroFade) {
            serial += 1
            index = target
            ambientKey = nil
        }
    }

    private func titlesChanged() {
        if index >= titles.count { index = 0 }
    }

    // MARK: - Auto-advance clock

    private struct ClockKey: Hashable {
        var serial: Int
        var paused: Bool
        var count: Int
    }

    private func clockPauseChanged(_ paused: Bool) {
        let now = Date()
        if paused { bankedTime += max(0, now.timeIntervalSince(segmentStart)) }
        segmentStart = now
    }

    private func runClock() async {
        guard titles.count > 1, !isPaused else { return }
        let elapsed = bankedTime + max(0, Date().timeIntervalSince(segmentStart))
        let remaining = max(0.1, Tuna.Motion.heroInterval - elapsed)
        guard await Self.sleep(remaining) else { return }
        show(safeIndex + 1)
    }

    // MARK: - Ambient trailer

    private struct TrailerKey: Hashable {
        var serial: Int
        var slide: String
        var eligible: Bool
    }

    private func runAmbientTrailer() async {
        guard trailerEligible, let current = currentTitle, let key = currentTrailerKey,
              trailerFinishedSlide != current.id else {
            hideAmbientTrailer()
            return
        }
        if ambientKey != key {
            ambientPlaying = false
            ambientRevealed = false
            guard await Self.sleep(Discover.Layout.trailerPreload) else { return }
            ambientKey = key // mounted invisibly so YouTube can buffer
            guard await Self.sleep(Discover.Layout.trailerReveal - Discover.Layout.trailerPreload) else { return }
        }
        // Reveal only once the embed reports real playback (no spinners, no "video unavailable" slates).
        var waited: Double = 0
        while !ambientPlaying {
            if waited >= 8 {
                hideAmbientTrailer()
                return
            }
            guard await Self.sleep(0.25) else { return }
            waited += 0.25
        }
        withAnimation(.easeInOut(duration: 1.4)) { ambientRevealed = true }
        guard await Self.sleep(Discover.Layout.trailerDwell) else { return }
        trailerFinishedSlide = current.id
        hideAmbientTrailer()
    }

    private func trailerEvent(_ event: TrailerEvent) {
        switch event {
        case .playing:
            ambientPlaying = true
        case .ended:
            break
        case .failed:
            hideAmbientTrailer()
        }
    }

    private func hideAmbientTrailer() {
        guard ambientKey != nil else { return }
        withAnimation(.easeInOut(duration: 1.0)) { ambientKey = nil }
    }

    private func playTrailer(key: String, title: Title) {
        if let onPlayTrailer {
            hideAmbientTrailer()
            onPlayTrailer(TrailerRequest(youtubeKey: key, titleName: title.name))
        } else if let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
            openURL(url)
        }
    }

    /// Cancel-safe sleep: false when the surrounding task was cancelled.
    private static func sleep(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Backdrop slide

extension HeroCarousel {
    /// One backdrop with a slow Ken Burns drift (scale 1.0 → 1.1 plus a small pan over ~20 s).
    struct Backdrop: View {
        let title: Title
        let imageURL: String?
        let flipped: Bool
        let drifting: Bool

        @State private var drifted = false

        init(title: Title, imageURL: String?, flipped: Bool, drifting: Bool) {
            self.title = title
            self.imageURL = imageURL
            self.flipped = flipped
            self.drifting = drifting
        }

        var body: some View {
            GeometryReader { proxy in
                TunaImage(url: imageURL, kind: .backdrop, seed: title.id, title: title.name)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(drifted ? 1.1 : 1.0, anchor: flipped ? .bottomTrailing : .topLeading)
                    .offset(x: drifted ? (flipped ? 16 : -16) : 0, y: drifted ? (flipped ? -8 : 8) : 0)
                    .clipped()
            }
            .onAppear {
                guard drifting else { return }
                withAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true)) { drifted = true }
            }
        }
    }

    /// Blurred, low-opacity copy of the backdrop that bleeds from the hero's lower half into the rails below.
    struct AmbientGlow: View {
        let title: Title
        let imageURL: String?
        let serial: Int

        var body: some View {
            GeometryReader { proxy in
                let height = proxy.size.height * 0.5 + 420
                ZStack {
                    TunaImage(url: imageURL, kind: .backdrop, seed: title.id, title: title.name)
                        .frame(width: proxy.size.width, height: height)
                        .clipped()
                        .blur(radius: 72, opaque: false)
                        .saturation(1.35)
                        .id("\(serial)|\(title.id)")
                        .transition(AnyTransition.opacity)
                }
                .frame(width: proxy.size.width, height: height)
                .mask {
                    LinearGradient(stops: [
                        .init(color: Color.black.opacity(0), location: 0),
                        .init(color: Color.black.opacity(0.55), location: 0.38),
                        .init(color: Color.black.opacity(0.4), location: 0.62),
                        .init(color: Color.black.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .opacity(0.45)
                .offset(y: proxy.size.height * 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Info column

extension HeroCarousel {
    struct RankInfo: Equatable {
        let rank: Int
        let label: String
    }

    struct InfoActions {
        var play: () -> Void
        var moreInfo: () -> Void
        var toggleList: () -> Void
        var trailer: () -> Void
    }

    fileprivate enum MetaPart: Hashable {
        case text(String)
        case certification(String)
    }

    struct InfoColumn: View {
        let title: Title
        let metadata: MediaMetadata?
        let rank: RankInfo?
        let progress: WatchProgress?
        let isInMyList: Bool
        let hasTrailer: Bool
        let reduceMotion: Bool
        let actions: InfoActions

        @State private var revealed = false

        init(title: Title, metadata: MediaMetadata?, rank: RankInfo?, progress: WatchProgress?, isInMyList: Bool,
             hasTrailer: Bool, reduceMotion: Bool, actions: InfoActions) {
            self.title = title
            self.metadata = metadata
            self.rank = rank
            self.progress = progress
            self.isInMyList = isInMyList
            self.hasTrailer = hasTrailer
            self.reduceMotion = reduceMotion
            self.actions = actions
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                reveal(kicker, step: 0)
                reveal(titleArt, step: 1)
                reveal(badges, step: 2)
                reveal(metaLine, step: 3)
                reveal(synopsis, step: 4)
                reveal(buttons, step: 5)
                    .padding(.top, 8)
            }
            .onAppear { revealed = true }
        }

        private func reveal<V: View>(_ view: V, step: Int) -> some View {
            view
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed || reduceMotion ? 0 : 18)
                .blur(radius: revealed || reduceMotion ? 0 : 6)
                .animation(
                    reduceMotion ? Animation.easeOut(duration: 0.3) : Tuna.Motion.page.delay(0.16 + Double(step) * 0.07),
                    value: revealed
                )
        }

        private var kicker: some View {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Tuna.Gradients.accent)
                    .frame(width: 18, height: 4)
                Text(Discover.Format.kindKicker(title.kind))
                    .font(Tuna.Fonts.micro)
                    .tracking(2.4)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                if let platform = title.platform?.nonEmpty {
                    PlatformChip(name: platform)
                }
            }
        }

        @ViewBuilder
        private var titleArt: some View {
            if let logo = metadata?.logoURL?.nonEmpty {
                TunaImage(url: logo, kind: .logo, seed: title.id, title: title.name, contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: 150, alignment: .bottomLeading)
                    .shadow(color: Color.black.opacity(0.45), radius: 18, y: 6)
                    .accessibilityLabel(title.name)
            } else {
                Text(title.name)
                    .font(Tuna.Fonts.heroTitle)
                    .tracking(-1.4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .shadow(color: Color.black.opacity(0.5), radius: 16, y: 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private var hasExternalRating: Bool {
            (metadata?.voteAverage ?? 0) > 0 || (metadata?.imdbRating ?? 0) > 0 || (metadata?.rottenTomatoes ?? 0) > 0
        }

        private var badges: some View {
            HStack(spacing: 8) {
                QualityBadge(quality: title.bestQuality, hdr: title.hdr)
                if let rank {
                    HeroCarousel.RankChip(rank: rank)
                }
                if let vote = metadata?.voteAverage, vote > 0 {
                    RatingChip(source: .tmdb, value: vote, votes: metadata?.voteCount)
                }
                if let imdb = metadata?.imdbRating, imdb > 0 {
                    RatingChip(source: .imdb, value: imdb, votes: metadata?.imdbVotes)
                }
                if let tomatoes = metadata?.rottenTomatoes, tomatoes > 0 {
                    RatingChip(source: .rottenTomatoes, value: Double(tomatoes))
                }
                if !hasExternalRating, let own = title.providerRating, own > 0 {
                    RatingChip(source: .provider, value: own)
                }
            }
        }

        private var metaParts: [MetaPart] {
            var parts: [MetaPart] = []
            if let year = metadata?.year ?? title.year {
                parts.append(.text(String(year)))
            }
            if title.kind == .series, let seasons = metadata?.seasonCount, seasons > 0 {
                parts.append(.text(Discover.Format.seasons(seasons)))
            } else if let minutes = metadata?.runtimeMinutes, minutes > 0 {
                parts.append(.text(Discover.Format.runtime(minutes: minutes)))
            }
            if let certification = metadata?.certification?.nonEmpty {
                parts.append(.certification(certification))
            }
            let metadataGenres = metadata?.genres ?? []
            let genres = metadataGenres.isEmpty ? title.genres : metadataGenres
            if !genres.isEmpty {
                parts.append(.text(genres.prefix(3).joined(separator: " · ")))
            }
            return parts
        }

        private var metaLine: some View {
            HStack(spacing: 10) {
                ForEach(Array(metaParts.enumerated()), id: \.offset) { offset, part in
                    HStack(spacing: 10) {
                        if offset > 0 {
                            Circle()
                                .fill(Tuna.Palette.textTertiary)
                                .frame(width: 3, height: 3)
                        }
                        switch part {
                        case .text(let value):
                            Text(value)
                        case .certification(let value):
                            CertificationBadge(text: value)
                        }
                    }
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Tuna.Palette.textSecondary)
            .lineLimit(1)
        }

        private var synopsis: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let tagline = metadata?.tagline?.nonEmpty {
                    Text(tagline)
                        .font(Tuna.Fonts.bodyLarge.italic())
                        .foregroundStyle(Tuna.Palette.textPrimary.opacity(0.92))
                        .lineLimit(1)
                }
                if let overview = (metadata?.overview ?? title.plot)?.nonEmpty {
                    Text(overview)
                        .font(Tuna.Fonts.bodyLarge)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .shadow(color: Color.black.opacity(0.35), radius: 8, y: 2)
        }

        private var playLabel: String {
            guard let progress, Discover.Format.isResumable(progress) else { return "Play" }
            return "Resume · " + Discover.Format.resumeLine(progress)
        }

        private var buttons: some View {
            HStack(spacing: 12) {
                GlassButton(title: playLabel, systemImage: "play.fill", style: .primary, action: actions.play)
                GlassButton(title: "More Info", systemImage: "info.circle", style: .secondary, action: actions.moreInfo)
                GlassButton(systemImage: isInMyList ? "checkmark" : "plus", style: .icon, action: actions.toggleList)
                    .contentTransition(.symbolEffect(.replace))
                    .help(isInMyList ? "Remove from My List" : "Add to My List")
                if hasTrailer {
                    GlassButton(title: "Trailer", systemImage: "play.rectangle.fill", style: .secondary, action: actions.trailer)
                }
            }
        }
    }

    /// "TOP 10 · #2 in Movies Today".
    struct RankChip: View {
        let rank: RankInfo

        var body: some View {
            HStack(spacing: 7) {
                VStack(spacing: -2) {
                    Text("TOP")
                        .font(.system(size: 7, weight: .black))
                    Text("10")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Tuna.Gradients.gold, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(rank.label)
                    .font(Tuna.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous).strokeBorder(Tuna.Palette.gold.opacity(0.35), lineWidth: 1))
        }
    }
}

// MARK: - Slide pills

extension HeroCarousel {
    /// Slide indicators; the current one fills up as the slide's time runs (frozen while paused).
    struct Pills: View {
        let count: Int
        let index: Int
        let bankedTime: TimeInterval
        let segmentStart: Date
        let paused: Bool
        let interval: Double
        let onSelect: (Int) -> Void

        private var activeWidth: CGFloat { 34 }

        var body: some View {
            HStack(spacing: 7) {
                ForEach(0..<count, id: \.self) { slide in
                    Button {
                        onSelect(slide)
                    } label: {
                        pill(slide)
                            .frame(height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Slide \(slide + 1) of \(count)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .tunaGlass(cornerRadius: 13)
            .animation(Tuna.Motion.snappy, value: index)
        }

        @ViewBuilder
        private func pill(_ slide: Int) -> some View {
            if slide == index {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
                    let progress = fraction(at: context.date)
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white)
                                .frame(width: max(6, activeWidth * progress))
                        }
                }
                .frame(width: activeWidth, height: 6)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.38))
                    .frame(width: 6, height: 6)
            }
        }

        private func fraction(at date: Date) -> CGFloat {
            let running = paused ? 0 : max(0, date.timeIntervalSince(segmentStart))
            guard interval > 0 else { return 1 }
            return CGFloat(min(1, max(0, (bankedTime + running) / interval)))
        }
    }
}
