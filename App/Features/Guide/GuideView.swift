import SwiftUI
import TunaCore

// =====================================================================================================
// TV GUIDE (owner: live-guide-search). Entry point `GuideView()`, pushed as `Route.guide`.
// Full page: back button, date/time, "Now" jump, category chips (shared with the Live TV rail), then the
// EPG timeline (GuideTimeline.swift). Typing a channel number works here too.
// =====================================================================================================

struct GuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(LiveTVSelection.storageKey) private var storedSelection: String = "all"
    @State private var chip: String?
    @State private var window: TVGuideWindow
    @State private var hasGuideData = true
    @State private var nowRequest = 0
    @State private var listMemo = LiveTVMemo<LiveTVListKey, LiveTVChannelList>()

    init() {
        let stored = UserDefaults.standard.string(forKey: LiveTVSelection.storageKey) ?? "all"
        _chip = State(initialValue: TVGuideChips.chip(for: LiveTVSelection(storageValue: stored)))
        _window = State(initialValue: TVGuideWindow(around: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(.top, Tuna.Metrics.topBarHeight + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(ChannelNumberEntryModifier(isActive: isFrontmost))
        .task(id: ObjectIdentifier(model.guide)) {
            hasGuideData = !model.guide.channelKeys.isEmpty
        }
        .onChange(of: chip) { _, newValue in
            storedSelection = TVGuideChips.selection(for: newValue).storageValue
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                GlassButton(systemImage: "chevron.left", style: .icon) {
                    model.router.back()
                }
                .help("Back")
                VStack(alignment: .leading, spacing: 2) {
                    Text("TV Guide")
                        .font(Tuna.Fonts.pageTitle)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(subtitle(at: context.date))
                            .font(Tuna.Fonts.caption)
                            .monospacedDigit()
                            .foregroundStyle(Tuna.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 16)
                ViewThatFits(in: .horizontal) {
                    TVGuideLegend()
                    Color.clear.frame(width: 0, height: 0)
                }
                GlassButton(title: "Now", systemImage: "scope", style: .secondary) {
                    nowRequest += 1
                }
                .help("Jump to the current time")
            }
            ChipBar(items: chipItems, selection: $chip, allLabel: "All")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    private func subtitle(at date: Date) -> String {
        LiveTVFormat.longDay(date) + " · " + LiveTVFormat.clock(date) + " · " + LiveTVFormat.channelCount(currentList.channels.count)
    }

    private var chipItems: [String] {
        var items: [String] = []
        if !model.favoriteChannels.isEmpty { items.append(TVGuideChips.favorites) }
        let adult = model.adultUnlocked
        for entry in model.library.channelCategories where entry.count > 0 {
            if entry.category == .xxx && !adult { continue }
            items.append(entry.category.title)
        }
        return items
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.library.liveShowcase.isEmpty && model.library.channels.isEmpty {
            EmptyStateView(symbol: "dot.radiowaves.left.and.right",
                           title: "No channels yet",
                           message: "Add your IPTV provider in Settings and the guide fills itself.",
                           actionTitle: "Open Settings") {
                model.router.isSettingsPresented = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasGuideData {
            EmptyStateView(symbol: "calendar.badge.clock",
                           title: "No guide data yet",
                           message: "Guide data appears after the first daily download.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let channels = currentList.channels
            if channels.isEmpty {
                EmptyStateView(symbol: chip == TVGuideChips.favorites ? "star" : "tv",
                               title: "No channels here",
                               message: "Pick another category above.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TVGuideGrid(channels: channels, window: window, nowRequest: nowRequest, reduceMotion: reduceMotion)
                    .clipShape(RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous)
                            .strokeBorder(Tuna.Palette.stroke, lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
    }

    private var currentList: LiveTVChannelList {
        LiveTVChannels.list(TVGuideChips.selection(for: chip), model: model, memo: listMemo)
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var isFrontmost: Bool {
        let router = model.router
        return router.top == .guide
            && !router.isSearchPresented
            && !router.isSettingsPresented
            && !model.player.isPresented
    }
}

// MARK: - Chips

/// Maps guide chips to the shared Live TV selection ("Favorites" + category titles; nil = All).
enum TVGuideChips {
    static let favorites = "Favorites"

    static func chip(for selection: LiveTVSelection) -> String? {
        switch selection {
        case .favorites: return favorites
        case .category(let category): return category.title
        case .all, .recents, .group: return nil
        }
    }

    static func selection(for chip: String?) -> LiveTVSelection {
        guard let chip else { return .all }
        if chip == favorites { return .favorites }
        if let category = ChannelCategory.allCases.first(where: { $0.title == chip }) { return .category(category) }
        return .all
    }
}

// MARK: - Decoration

private struct TVGuideLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            swatch("Sports", Tuna.Palette.success)
            swatch("News", Tuna.Palette.accentCool)
            swatch("Movies", Tuna.Palette.hdr)
            swatch("Series", Tuna.Palette.hd)
            swatch("Kids", Tuna.Palette.gold)
            HStack(spacing: 4) {
                Image(systemName: "gobackward")
                    .foregroundStyle(Tuna.Palette.accentCool)
                Text("Replay")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Tuna.Palette.textTertiary)
        .fixedSize()
    }

    private func swatch(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }
}
