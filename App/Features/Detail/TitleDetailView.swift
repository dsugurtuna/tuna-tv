import SwiftUI
import TunaCore

/// Full-window detail page for a movie or a series (route `.title(id)`).
struct TitleDetailView: View {
    let titleID: String
    @Environment(AppModel.self) private var model

    init(titleID: String) {
        self.titleID = titleID
    }

    var body: some View {
        if let title = model.title(titleID) {
            TDPage(title: title)
                .task(id: titleID) { await model.loadDetails(for: title) }
        } else {
            TDMissingView()
        }
    }
}

private struct TDMissingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            EmptyStateView(symbol: "film.stack",
                           title: "This title is no longer here",
                           message: "Your provider may have removed it during the last refresh.",
                           actionTitle: "Go back",
                           action: { model.router.back() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TDBackButton()
        }
    }
}

/// Adult titles stay behind the PIN even when opened from elsewhere.
private struct TDLockedView: View {
    @Environment(AppModel.self) private var model
    @State private var askPIN = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            EmptyStateView(symbol: "lock.fill",
                           title: "Locked",
                           message: model.settings.content.hideAdult
                               ? "Adult content is hidden. You can turn it on in Settings."
                               : "Enter your PIN to open this title.",
                           actionTitle: model.settings.content.hideAdult ? nil : "Unlock",
                           action: unlockAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TDBackButton()
        }
        .sheet(isPresented: $askPIN) { VaultPINSheet(onUnlocked: {}) }
    }

    private var unlockAction: (() -> Void)? {
        if model.settings.content.hideAdult { return nil }
        return { askPIN = true }
    }
}

struct TDPage: View {
    let title: Title
    @Environment(AppModel.self) private var model
    @State private var versionsOpen = false
    @State private var trailer: Trailer?
    @State private var scrolledPastHero = false

    static let versionsAnchor = "tuna.detail.versions"

    var body: some View {
        if title.isAdult && VaultAccess.isAdultBlocked(model) {
            TDLockedView()
        } else {
            page
        }
    }

    private var page: some View {
        GeometryReader { geo in
            let heroHeight = max(380, geo.size.height * 0.62)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content(heroHeight: heroHeight, proxy: proxy)
                }
                .scrollIndicators(.automatic)
                .onScrollGeometryChange(for: Bool.self) { scroll in
                    scroll.contentOffset.y + scroll.contentInsets.top > heroHeight * 0.55
                } action: { _, isPast in
                    withAnimation(Tuna.Motion.snappy) { scrolledPastHero = isPast }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            TDCompactBar(name: title.name, showsTitle: scrolledPastHero)
        }
        .sheet(item: $trailer) { item in
            TDTrailerSheet(trailer: item)
        }
    }

    private func content(heroHeight: CGFloat, proxy: ScrollViewProxy) -> some View {
        let metadata = model.metadata(for: title)
        return ZStack(alignment: .top) {
            TDHeroBackdrop(url: backdropURL(metadata), seed: title.id, name: title.name, height: heroHeight)
            VStack(alignment: .leading, spacing: Tuna.Metrics.sectionSpacing) {
                Color.clear.frame(height: max(190, heroHeight * 0.42))
                TDHeader(title: title, metadata: metadata,
                         onTrailer: { item in trailer = item },
                         onShowVersions: {
                             withAnimation(Tuna.Motion.page) {
                                 versionsOpen = true
                                 proxy.scrollTo(TDPage.versionsAnchor, anchor: .top)
                             }
                         })
                sections(metadata: metadata)
            }
            .padding(.bottom, 90)
        }
    }

    @ViewBuilder
    private func sections(metadata: MediaMetadata?) -> some View {
        if title.kind == .series {
            TDEpisodesSection(title: title)
                .staggeredAppear(index: 0)
        }
        TDVersionsSection(title: title, isOpen: $versionsOpen)
            .id(TDPage.versionsAnchor)
            .staggeredAppear(index: 1)
        if let metadata, !(metadata.cast.isEmpty && metadata.crew.isEmpty && metadata.directors.isEmpty && metadata.creators.isEmpty) {
            TDPeopleSection(metadata: metadata)
                .staggeredAppear(index: 2)
        }
        TDFactsSection(title: title, metadata: metadata)
            .staggeredAppear(index: 3)
        TDSimilarSection(title: title)
            .staggeredAppear(index: 4)
    }

    private func backdropURL(_ metadata: MediaMetadata?) -> String? {
        if let url = metadata?.backdropURL { return url }
        if let url = title.backdropURL { return url }
        if let url = metadata?.backdrops.first { return url }
        if let url = model.providerInfo(for: title)?.backdropURLs.first { return url }
        if let url = metadata?.posterURL { return url }
        return title.posterURL
    }
}

/// Back button (below the shell's top bar) + the title name once the hero has scrolled away.
private struct TDCompactBar: View {
    let name: String
    let showsTitle: Bool

    var body: some View {
        HStack(spacing: 12) {
            TDBackButton(padded: false)
            if showsTitle {
                Text(name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .tunaGlass(cornerRadius: 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.leading, 24)
        .padding(.top, Tuna.Metrics.topBarHeight + 14)
    }
}

/// Backdrop with parallax: moves slower than the content when scrolling and stretches on overscroll.
struct TDHeroBackdrop: View {
    let url: String?
    let seed: String
    let name: String
    let height: CGFloat

    var body: some View {
        let h = max(height, 1)
        TunaImage(url: url, kind: .backdrop, seed: seed, title: name)
            .frame(maxWidth: .infinity)
            .frame(height: h)
            .clipped()
            .overlay(Tuna.Gradients.heroSide)
            .overlay(Tuna.Gradients.heroScrim)
            .visualEffect { content, proxy in
                let minY = proxy.frame(in: .scrollView).minY
                let pull = max(0, minY)
                let push = max(0, -minY)
                return content
                    .scaleEffect((h + pull) / h, anchor: .bottom)
                    .offset(y: push * 0.45)
                    .opacity(1 - min(push / h, 1) * 0.55)
            }
            .allowsHitTesting(false)
    }
}
