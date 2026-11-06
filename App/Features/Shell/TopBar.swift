import SwiftUI
import TunaCore

/// Floating glass top bar: wordmark, section tabs (sliding selection pill), World Switcher, search (⌘K),
/// sync indicator, Provider Shield and Settings. Leaves 78 pt on the left for the traffic lights.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        GeometryReader { proxy in
            TopBarLayout(width: proxy.size.width,
                         reduceMotion: systemReduceMotion || model.settings.reduceMotion,
                         openSettings: { openSettings() })
        }
        .frame(height: Tuna.Metrics.topBarHeight)
    }
}

struct TopBarLayout: View {
    @Environment(AppModel.self) private var model

    let width: CGFloat
    let reduceMotion: Bool
    let openSettings: () -> Void

    private var router: Router { model.router }
    /// Below this width only the selected tab shows its title.
    private var compactTabs: Bool { width < 1240 }
    private var hidesWordmark: Bool { width < 980 }

    var body: some View {
        ZStack(alignment: .leading) {
            ShellWindowDragArea()

            HStack(spacing: 8) {
                if !router.stack.isEmpty {
                    ShellIconButton(symbol: "chevron.left", help: "Back", tint: Tuna.Palette.textPrimary) {
                        router.back()
                    }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                if !hidesWordmark {
                    Button {
                        router.select(.home)
                    } label: {
                        TunaWordmark(size: 17)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Tuna TV — Home")
                }

                ShellSectionTabs(compact: compactTabs)

                ShellWindowDragArea()
                    .frame(minWidth: 6, maxWidth: .infinity)
                    .frame(height: 34)

                WorldSwitcher()

                ShellIconButton(symbol: "magnifyingglass", help: "Search (⌘K)",
                                shortcut: KeyboardShortcut("k", modifiers: .command)) {
                    withAnimation(Tuna.Motion.snappy) { router.isSearchPresented.toggle() }
                }

                ShellSyncIndicator(phase: model.syncPhase, reduceMotion: reduceMotion, onOpenSettings: openSettings)

                ProviderShieldView(status: model.providerStatus)

                ShellIconButton(symbol: "gearshape.fill", help: "Settings (⌘,)") {
                    openSettings()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .tunaGlass(cornerRadius: 24)
            .shadow(color: Color.black.opacity(0.32), radius: 16, x: 0, y: 8)
            .padding(.leading, 78)
            .padding(.trailing, 14)
        }
        .frame(width: width, height: Tuna.Metrics.topBarHeight)
        .animation(reduceMotion ? nil : Tuna.Motion.snappy, value: router.stack.isEmpty)
    }
}

// MARK: - Section tabs

struct ShellSectionTabs: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    @Namespace private var pillNamespace
    @State private var hovered: AppSection?

    var body: some View {
        let selected = model.router.section
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { section in
                ShellSectionTab(section: section,
                                isSelected: section == selected,
                                isHovered: hovered == section,
                                showsTitle: !compact || section == selected,
                                namespace: pillNamespace) {
                    model.router.select(section)
                }
                .onHover { inside in
                    withAnimation(Tuna.Motion.hover) {
                        if inside {
                            hovered = section
                        } else if hovered == section {
                            hovered = nil
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.2)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
    }
}

struct ShellSectionTab: View {
    let section: AppSection
    let isSelected: Bool
    let isHovered: Bool
    let showsTitle: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                if showsTitle {
                    Text(section.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, showsTitle ? 12 : 10)
            .frame(height: 32)
            .background { pill }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(section.shortcut, modifiers: .command)
        .help("\(section.title) (⌘\(String(section.shortcut.character)))")
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected { return Tuna.Palette.textPrimary }
        return isHovered ? Tuna.Palette.textPrimary.opacity(0.92) : Tuna.Palette.textSecondary
    }

    @ViewBuilder private var pill: some View {
        if isSelected {
            Capsule()
                .fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Tuna.Palette.glassHighlight, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
                .matchedGeometryEffect(id: "shell-section-pill", in: namespace)
        } else if isHovered {
            Capsule().fill(Color.white.opacity(0.07))
        }
    }
}

// MARK: - Sync indicator

/// Spinning ring while a catalog sync runs (tooltip with progress); a warning button after a failed sync.
struct ShellSyncIndicator: View {
    let phase: SyncPhase
    let reduceMotion: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            if let progress = syncingProgress {
                ShellProgressRing(fraction: progress.fraction, lineWidth: 2.5, spinning: !reduceMotion)
                    .frame(width: 18, height: 18)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .help(tooltip(for: progress))
                    .accessibilityLabel("Syncing your library, \(Int((progress.fraction * 100).rounded())) percent")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if let message = failureMessage {
                ShellIconButton(symbol: "exclamationmark.arrow.triangle.2.circlepath",
                                help: "Last sync stopped: \(message)",
                                tint: Tuna.Palette.warning) {
                    onOpenSettings()
                }
                .transition(.opacity)
            }
        }
        .animation(Tuna.Motion.snappy, value: phase)
    }

    private var syncingProgress: SyncProgress? {
        if case .syncing(let progress) = phase { return progress }
        return nil
    }

    private var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private func tooltip(for progress: SyncProgress) -> String {
        var parts = ["\(ShellFormat.stageLabel(progress.stage)) · \(Int((progress.fraction * 100).rounded()))%"]
        let counts = ShellFormat.breakdown(progress.counts)
        if progress.counts.values.contains(where: { $0 > 0 }) { parts.append(counts) }
        if let wait = progress.nextRequestIn, wait > 0.05 {
            parts.append(String(format: "next request in %.1f s · protecting your account", wait))
        } else {
            parts.append("one request at a time · protecting your account")
        }
        return parts.joined(separator: "\n")
    }
}
