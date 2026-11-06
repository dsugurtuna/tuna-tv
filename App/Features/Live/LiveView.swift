import SwiftUI
import TunaCore

// =====================================================================================================
// LIVE TV (owner: live-guide-search). Entry point `LiveView()`.
//
//   ┌ rail (glass, 220) ┐ ┌ On Now: live events strip ─────────────────────────────────┐
//   │ All / Favorites   │ │ [pinned] Sports · 124 channels · 12 in 4K   [Wall|Guide]    │
//   │ Recently watched  │ │ ChannelCard ChannelCard ChannelCard ChannelCard …           │
//   │ Categories …      │ │ (LazyVGrid, now/next refreshed every 30 s)                  │
//   └ Provider groups … ┘ └─────────────────────────────────────────────────────────────┘
//
// Typing digits anywhere on the page shows "Go to 104" and tunes to that channel number.
// =====================================================================================================

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(LiveTVSelection.storageKey) private var storedSelection: String = "all"

    init() {}

    var body: some View {
        content
            .padding(.top, Tuna.Metrics.topBarHeight + 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(ChannelNumberEntryModifier(isActive: isFrontmost))
    }

    @ViewBuilder
    private var content: some View {
        if model.library.liveShowcase.isEmpty {
            emptyLibrary
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 22) {
                LiveCategoryRail(selectionKey: $storedSelection, reduceMotion: reduceMotion)
                    .padding(.bottom, 20)
                LiveMainColumn(selection: LiveTVSelection(storageValue: storedSelection), reduceMotion: reduceMotion)
            }
            .padding(.leading, 24)
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if model.isBooting {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Tuning in…")
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
        } else if !model.library.channels.isEmpty {
            EmptyStateView(symbol: "shippingbox.fill",
                           title: "Your channels are in The Vault",
                           message: "None of your channels match your languages and countries yet. Browse them in The Vault, or add a world in Settings.",
                           actionTitle: "Open The Vault") {
                model.router.select(.vault)
            }
        } else {
            EmptyStateView(symbol: "dot.radiowaves.left.and.right",
                           title: "No live channels yet",
                           message: "Add your IPTV provider in Settings. Tuna TV merges every feed of a channel into one tile and sorts them for you.",
                           actionTitle: "Open Settings") {
                model.router.isSettingsPresented = true
            }
        }
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    /// Number entry only listens while Live TV is the visible, uncovered screen.
    private var isFrontmost: Bool {
        let router = model.router
        return router.section == .live
            && router.top == nil
            && !router.isSearchPresented
            && !router.isSettingsPresented
            && !model.player.isPresented
    }
}
