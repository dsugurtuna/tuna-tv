import SwiftUI
import TunaCore

/// The main window. Layers, bottom to top:
/// ambient background → section content (crossfade + scale per section) → pushed pages (slide up) →
/// floating top bar → search palette → player → onboarding → boot splash → toasts.
///
/// Expects `.environment(appModel)` and a window with a hidden title bar; it does not call `model.start()`.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Set once onboarding has been shown in this session, so it stays up (curation theater, "Start watching")
    /// after `addProvider` has made `needsOnboarding` false.
    @State private var onboardingSeen = false
    /// Content under a fully presented player is hidden (keeps its state, saves GPU work).
    @State private var contentCovered = false

    private var router: Router { model.router }
    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }
    private var playerPresented: Bool { model.player?.isPresented ?? false }

    private var showsOnboarding: Bool {
        if model.needsOnboarding { return true }
        return onboardingSeen && !model.settings.hasCompletedOnboarding && !model.isDemo
    }

    private var chromeVisible: Bool { !playerPresented && !showsOnboarding }

    var body: some View {
        ZStack {
            AmbientBackground(tint: ambientTint)
                .ignoresSafeArea()
                .zIndex(0)

            ShellSectionHost(section: router.section, reduceMotion: reduceMotion)
                .scaleEffect(router.stack.isEmpty || reduceMotion ? 1 : 0.965)
                .overlay {
                    Color.black
                        .opacity(router.stack.isEmpty ? 0 : 0.55)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(router.stack.isEmpty)
                .opacity(contentCovered ? 0 : 1)
                .zIndex(1)

            ForEach(stackEntries) { entry in
                ShellRoutePage(route: entry.route, isTop: entry.isTop, reduceMotion: reduceMotion)
                    .opacity(contentCovered ? 0 : 1)
                    .zIndex(Double(10 + entry.index))
                    .transition(pageTransition)
            }

            if chromeVisible {
                TopBar()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }

            if router.isSearchPresented && chromeVisible {
                ShellScrim(opacity: 0.5) { closeSearch() }
                    .transition(.opacity)
                    .zIndex(200)
            }
            if router.isSearchPresented && chromeVisible {
                ShellSearchHost()
                    .transition(searchTransition)
                    .zIndex(201)
            }

            if playerPresented {
                PlayerView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.03)))
                    .zIndex(300)
            }

            if showsOnboarding {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(400)
            }

            if model.isBooting {
                ShellBootSplash(reduceMotion: reduceMotion)
                    .transition(.opacity)
                    .zIndex(500)
            }

            ToastHost()
                .zIndex(600)

            if escapeHandlerActive {
                ShellEscapeHandler { handleEscape() }
                    .zIndex(700)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tuna.Palette.background)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Tuna.Motion.page, value: router.section)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Tuna.Motion.page, value: playerPresented)
        .animation(Tuna.Motion.snappy, value: router.isSearchPresented)
        .animation(Tuna.Motion.gentle, value: showsOnboarding)
        .animation(Tuna.Motion.gentle, value: model.isBooting)
        .onAppear {
            if model.needsOnboarding { onboardingSeen = true }
        }
        .onChange(of: model.needsOnboarding) { _, needs in
            if needs { onboardingSeen = true }
        }
        .onChange(of: router.isSettingsPresented) { _, requested in
            guard requested else { return }
            openSettings()
            router.isSettingsPresented = false
        }
        .onChange(of: playerPresented) { _, presented in
            playerPresentationChanged(presented)
        }
    }

    // MARK: Pieces

    private var stackEntries: [ShellStackEntry] {
        let stack = router.stack
        return stack.enumerated().map { offset, route in
            ShellStackEntry(index: offset, route: route, isTop: offset == stack.count - 1)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.move(edge: .bottom).combined(with: .opacity)
    }

    private var searchTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    private var ambientTint: Color {
        switch router.section {
        case .home: return ShellTint.forSeed(model.featured.first?.id)
        case .live: return Tuna.Palette.live
        case .movies: return Tuna.Palette.accent
        case .series: return Color(hex: 0x6C7CFF)
        case .myList: return Tuna.Palette.gold
        case .vault: return Tuna.Palette.hdr
        }
    }

    // MARK: Keyboard

    private var escapeHandlerActive: Bool {
        chromeVisible && (router.isSearchPresented || !router.stack.isEmpty)
    }

    private func handleEscape() {
        if router.isSearchPresented {
            closeSearch()
        } else {
            router.back()
        }
    }

    private func closeSearch() {
        withAnimation(Tuna.Motion.snappy) { router.isSearchPresented = false }
    }

    private func playerPresentationChanged(_ presented: Bool) {
        guard presented else {
            contentCovered = false
            return
        }
        if router.isSearchPresented { router.isSearchPresented = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if model.player?.isPresented == true { contentCovered = true }
        }
    }
}

// MARK: - Sections

/// The current top-level section with a soft crossfade + scale when it changes.
struct ShellSectionHost: View {
    let section: AppSection
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            ShellSectionContent(section: section)
                .id(section)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.985)),
            removal: AnyTransition.opacity.combined(with: .scale(scale: 1.012)))
    }
}

struct ShellSectionContent: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .home: HomeView()
        case .live: LiveView()
        case .movies: BrowseView(kind: .movie)
        case .series: BrowseView(kind: .series)
        case .myList: MyListView()
        case .vault: VaultView()
        }
    }
}

// MARK: - Pushed pages

struct ShellStackEntry: Identifiable {
    let index: Int
    let route: Route
    let isTop: Bool
    var id: String { "\(index)|\(route.id)" }
}

/// One pushed page: full window, opaque, dimmed and slightly receded when another page covers it.
struct ShellRoutePage: View {
    let route: Route
    let isTop: Bool
    let reduceMotion: Bool

    var body: some View {
        ShellRouteContent(route: route)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Tuna.Palette.background
                    Tuna.Gradients.app.opacity(0.6)
                }
                .ignoresSafeArea()
            }
            .overlay {
                Color.black
                    .opacity(isTop ? 0 : 0.5)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isTop || reduceMotion ? 1 : 0.97)
            .allowsHitTesting(isTop)
            .accessibilityHidden(!isTop)
    }
}

struct ShellRouteContent: View {
    let route: Route

    var body: some View {
        switch route {
        case .title(let id):
            TitleDetailView(titleID: id)
        case .person(let id, let name):
            PersonView(personID: id, name: name)
        case .seeAll(let key, let title, let kind):
            SeeAllView(key: key, title: title, kind: kind)
        case .vaultShelf(let shelf):
            VaultShelfView(shelf: shelf)
        case .guide:
            GuideView()
        case .insights:
            InsightsView()
        }
    }
}

// MARK: - Escape

/// Invisible button that owns the Escape key while there is something to close.
struct ShellEscapeHandler: View {
    let action: () -> Void

    var body: some View {
        Button("Close", action: action)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
