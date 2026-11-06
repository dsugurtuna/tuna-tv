import SwiftUI
import TunaCore

/// Home: the hero carousel, then the curated rails (overlapping the hero's bottom edge), then a gentle pointer to
/// The Vault. Shows a shimmering skeleton while the library boots and a friendly explanation when nothing made the
/// showcase yet.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Trailer playing with sound in the lightbox.
    @State private var trailer: HeroCarousel.TrailerRequest?

    init() {}

    private enum Phase: Hashable {
        case loading
        case empty
        case feed
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var contentRails: [Rail] { model.homeRails.filter { $0.style != .hero } }

    private var phase: Phase {
        if model.isBooting { return .loading }
        if model.featured.isEmpty && contentRails.isEmpty { return .empty }
        return .feed
    }

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                HomeView.LoadingState()
                    .transition(AnyTransition.opacity)
            case .empty:
                HomeView.EmptyLibrary()
                    .transition(AnyTransition.opacity)
            case .feed:
                feed
                    .transition(AnyTransition.opacity)
            }
        }
        .animation(reduceMotion ? nil : Tuna.Motion.gentle, value: phase)
        .overlay {
            if let trailer {
                HomeView.TrailerLightbox(request: trailer) {
                    withAnimation(Tuna.Motion.page) { self.trailer = nil }
                }
                .transition(AnyTransition.opacity)
            }
        }
    }

    private var feed: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if model.featured.isEmpty {
                    Color.clear
                        .frame(height: Discover.Layout.pageTop)
                } else {
                    HeroCarousel(titles: model.featured, suspended: trailer != nil) { (request: HeroCarousel.TrailerRequest) in
                        withAnimation(Tuna.Motion.page) { trailer = request }
                    }
                }
                Discover.RailStack(rails: contentRails, seeAllKind: nil)
                    .padding(.top, model.featured.isEmpty ? 0 : -Discover.Layout.railOverlap)
                    .zIndex(1)
                HomeView.VaultTeaser()
                    .padding(.top, Tuna.Metrics.sectionSpacing + 12)
                    .zIndex(1)
            }
            .padding(.bottom, Discover.Layout.pageBottom)
        }
        .ignoresSafeArea(edges: .top)
        .task(id: model.featured.map(\.id)) {
            await requestVisibleMetadata()
        }
    }

    /// Hero + the first rails, visible-first (cheap: the model dedupes).
    private func requestVisibleMetadata() async {
        var batch = model.featured
        for rail in contentRails.prefix(3) {
            batch.append(contentsOf: Discover.titles(in: rail, limit: 12))
        }
        guard !batch.isEmpty else { return }
        model.requestMetadata(for: batch)
    }
}

// MARK: - Loading

extension HomeView {
    /// Shimmering hero + skeleton rails while the cached catalog loads.
    struct LoadingState: View {
        var body: some View {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    HomeView.HeroSkeleton()
                        .containerRelativeFrame(.vertical) { length, _ in
                            max(Discover.Layout.heroMinimumHeight, length * Tuna.Metrics.heroHeightRatio)
                        }
                    VStack(alignment: .leading, spacing: Tuna.Metrics.sectionSpacing) {
                        Discover.SkeletonRail(kind: .poster)
                        Discover.SkeletonRail(kind: .landscape, cards: 6)
                        Discover.SkeletonRail(kind: .poster)
                    }
                    .padding(.top, -Discover.Layout.railOverlap)
                }
            }
            .scrollDisabled(true)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    struct HeroSkeleton: View {
        var body: some View {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Tuna.Palette.surfaceRaised, Tuna.Palette.surface, Tuna.Palette.background],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                Tuna.Gradients.heroScrim
                VStack(alignment: .leading, spacing: 16) {
                    bar(width: 110, height: 10)
                    bar(width: 430, height: 58)
                    HStack(spacing: 8) {
                        bar(width: 46, height: 22)
                        bar(width: 64, height: 22)
                        bar(width: 64, height: 22)
                    }
                    bar(width: 300, height: 14)
                    VStack(alignment: .leading, spacing: 8) {
                        bar(width: 560, height: 12)
                        bar(width: 520, height: 12)
                        bar(width: 360, height: 12)
                    }
                    HStack(spacing: 12) {
                        bar(width: 132, height: 44)
                        bar(width: 132, height: 44)
                        bar(width: 44, height: 44)
                    }
                    .padding(.top, 8)
                }
                .shimmering()
                .padding(.leading, Tuna.Metrics.pageInset)
                .padding(.bottom, Discover.Layout.railOverlap + 52)
            }
            .accessibilityHidden(true)
        }

        private func bar(width: CGFloat, height: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: min(10, height / 2), style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: width, height: height)
        }
    }
}

// MARK: - Empty library

extension HomeView {
    /// Nothing in the showcase: explain why (no provider / still curating / everything is in The Vault).
    struct EmptyLibrary: View {
        @Environment(AppModel.self) private var model

        init() {}

        var body: some View {
            VStack(spacing: 20) {
                content
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, Tuna.Metrics.pageInset)
            .padding(.top, Tuna.Metrics.topBarHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                RadialGradient(
                    colors: [Tuna.Palette.accentCool.opacity(0.14), Color.clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 620
                )
                .frame(height: 620)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .top)
        }

        @ViewBuilder
        private var content: some View {
            if model.providers.isEmpty && !model.isDemo {
                EmptyStateView(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: "Connect your IPTV subscription",
                    message: "Tuna TV turns any Xtream or M3U subscription into a curated streaming service. Add yours in Settings, or take the demo for a spin first.",
                    actionTitle: "Open Settings"
                ) {
                    model.router.isSettingsPresented = true
                }
                GlassButton(title: "Try the demo", systemImage: "sparkles.tv", style: .secondary) {
                    Task { await model.startDemo() }
                }
            } else if case .syncing(let progress) = model.syncPhase {
                HomeView.CurationCard(progress: progress)
            } else {
                EmptyStateView(
                    symbol: "shippingbox.fill",
                    title: "Nothing made the showcase yet",
                    message: vaultMessage,
                    actionTitle: "Open The Vault"
                ) {
                    model.router.select(.vault)
                }
                GlassButton(title: "Showcase Settings", systemImage: "slider.horizontal.3", style: .secondary) {
                    model.router.isSettingsPresented = true
                }
            }
        }

        private var vaultMessage: String {
            let noun = Discover.Format.showcaseNoun(model.settings.content.showcaseQuality)
            return "Home only shows the very best: \(noun) in your worlds. Everything else (HD versions, other languages, "
                + "older rips) is waiting in The Vault. You can also widen your showcase or add worlds in Settings."
        }
    }

    /// First sync in progress: the curator is still sorting the catalog.
    struct CurationCard: View {
        let progress: SyncProgress

        var body: some View {
            VStack(spacing: 18) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Tuna.Gradients.accent)
                    .symbolEffect(.pulse)
                Text("Curating your library")
                    .font(Tuna.Fonts.pageTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text(progress.message)
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                ProgressLine(fraction: progress.fraction, tint: Tuna.Palette.accent, height: 4)
                    .frame(width: 320)
                    .animation(Tuna.Motion.gentle, value: progress.fraction)
                Text("Your provider is contacted gently, one request at a time.")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            .padding(36)
            .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
        }
    }
}

// MARK: - Vault teaser

extension HomeView {
    /// "Looking for something else?" card at the end of Home.
    struct VaultTeaser: View {
        @Environment(AppModel.self) private var model

        init() {}

        private var vaultCount: Int {
            model.library.vaultCounts
                .filter { $0.key != .adult }
                .reduce(0) { $0 + $1.value }
        }

        var body: some View {
            if vaultCount > 0 {
                HStack(spacing: 20) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Tuna.Gradients.gold)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Tuna.Palette.gold.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Looking for something else?")
                            .font(Tuna.Fonts.sectionTitle)
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        Text("\(vaultCount) more titles and channels wait in The Vault: HD versions, other languages, classics and more.")
                            .font(Tuna.Fonts.body)
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .contentTransition(.numericText(value: Double(vaultCount)))
                    }
                    Spacer(minLength: 16)
                    GlassButton(title: "Open The Vault", systemImage: "arrow.right", style: .secondary) {
                        model.router.select(.vault)
                    }
                }
                .padding(22)
                .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
                .tunaPageInset()
            }
        }
    }
}

// MARK: - Trailer lightbox

extension HomeView {
    /// Trailer with sound, centred over a dimmed Home. Esc or a click outside closes it.
    struct TrailerLightbox: View {
        let request: HeroCarousel.TrailerRequest
        let onClose: () -> Void

        @State private var appeared = false

        init(request: HeroCarousel.TrailerRequest, onClose: @escaping () -> Void) {
            self.request = request
            self.onClose = onClose
        }

        var body: some View {
            GeometryReader { proxy in
                let width = max(320, min(1180, proxy.size.width * 0.84, (proxy.size.height - 170) * 16 / 9))
                ZStack {
                    Color.black.opacity(0.82)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onClose)
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        HeroCarousel.TrailerWebView(youtubeKey: request.youtubeKey, muted: false, interactive: true)
                            .frame(width: width, height: width * 9 / 16)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous)
                                    .strokeBorder(Tuna.Palette.stroke, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.6), radius: 40, y: 20)
                    }
                    .frame(width: width)
                    .scaleEffect(appeared ? 1 : 0.94)
                    .opacity(appeared ? 1 : 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(Tuna.Motion.page) { appeared = true }
            }
        }

        private var header: some View {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TRAILER")
                        .font(Tuna.Fonts.micro)
                        .tracking(2.4)
                        .foregroundStyle(Tuna.Palette.accent)
                    Text(request.titleName)
                        .font(Tuna.Fonts.sectionTitle)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .overlay(Circle().strokeBorder(Tuna.Palette.strokeStrong, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
        }
    }
}
