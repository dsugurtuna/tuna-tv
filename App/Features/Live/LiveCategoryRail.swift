import SwiftUI
import TunaCore

// =====================================================================================================
// LIVE TV CATEGORY RAIL. Glass sidebar (220 pt): All / Favorites / Recently watched, the iptv-org
// categories (symbol + title + count) and the provider's own groups. The selection highlight slides between
// rows (matchedGeometryEffect); provider groups collapse when there are many of them.
// =====================================================================================================

struct LiveCategoryRail: View {
    @Binding var selectionKey: String
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @Namespace private var highlightSpace
    /// Drives the sliding highlight separately from the (non-animated) channel wall update.
    @State private var highlightKey: String
    @State private var showsAllGroups = false
    @State private var catalogMemo = LiveTVMemo<LiveRailCatalogKey, LiveRailCatalog>()

    static let width: CGFloat = 220
    private static let collapsedGroupCount = 8

    init(selectionKey: Binding<String>, reduceMotion: Bool) {
        self._selectionKey = selectionKey
        self.reduceMotion = reduceMotion
        self._highlightKey = State(initialValue: LiveTVSelection(storageValue: selectionKey.wrappedValue).storageValue)
    }

    var body: some View {
        let catalog = railCatalog
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                LiveRailSectionLabel(title: "Library")
                row(.all, count: catalog.showcaseCount)
                row(.favorites, count: model.favoriteChannels.count)
                row(.recents, count: model.recentChannels.count)

                if !catalog.categories.isEmpty {
                    LiveRailSectionLabel(title: "Categories")
                        .padding(.top, 16)
                    ForEach(catalog.categories) { entry in
                        row(entry.selection, count: entry.count)
                    }
                }

                if !catalog.groups.isEmpty {
                    LiveRailSectionLabel(title: "Provider groups", trailing: catalog.groups.count.formatted())
                        .padding(.top, 16)
                    ForEach(visibleGroups(catalog.groups)) { entry in
                        row(entry.selection, count: entry.count)
                    }
                    if catalog.groups.count > LiveCategoryRail.collapsedGroupCount {
                        groupsToggle(total: catalog.groups.count)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: LiveCategoryRail.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
        .onChange(of: selectionKey) { _, newValue in
            let normalized = LiveTVSelection(storageValue: newValue).storageValue
            guard normalized != highlightKey else { return }
            withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) { highlightKey = normalized }
        }
    }

    // MARK: Rows

    private func row(_ selection: LiveTVSelection, count: Int) -> some View {
        LiveRailRow(title: selection.title,
                    symbol: selection.symbol,
                    tint: selection.tint,
                    count: count,
                    isSelected: selection.storageValue == highlightKey,
                    namespace: highlightSpace) {
            select(selection)
        }
    }

    private func select(_ selection: LiveTVSelection) {
        let key = selection.storageValue
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) { highlightKey = key }
        // The wall swaps without animation: hundreds of cards should not fly around.
        selectionKey = key
    }

    private func groupsToggle(total: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) { showsAllGroups.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsAllGroups ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                Text(showsAllGroups ? "Show fewer" : "Show all \(total.formatted())")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tuna.Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// First groups only (plus the selected one) until the user expands the section.
    private func visibleGroups(_ groups: [LiveRailEntry]) -> [LiveRailEntry] {
        guard !showsAllGroups, groups.count > LiveCategoryRail.collapsedGroupCount else { return groups }
        var visible = Array(groups.prefix(LiveCategoryRail.collapsedGroupCount))
        if let selected = groups.first(where: { $0.id == highlightKey }),
           !visible.contains(where: { $0.id == selected.id }) {
            visible.append(selected)
        }
        return visible
    }

    // MARK: Catalog

    private var railCatalog: LiveRailCatalog {
        let library = model.library
        let adult = model.adultUnlocked
        let key = LiveRailCatalogKey(library: ObjectIdentifier(library), adult: adult)
        return catalogMemo.value(for: key) {
            LiveRailCatalog.make(library: library, includeAdult: adult)
        }
    }
}

// MARK: - Catalog

struct LiveRailCatalogKey: Hashable {
    var library: ObjectIdentifier
    var adult: Bool
}

struct LiveRailEntry: Identifiable {
    let selection: LiveTVSelection
    let count: Int
    var id: String { selection.storageValue }
}

/// Rail rows derived from one library snapshot (computed once per snapshot).
struct LiveRailCatalog {
    var showcaseCount: Int
    var categories: [LiveRailEntry]
    var groups: [LiveRailEntry]

    static func make(library: Library, includeAdult: Bool) -> LiveRailCatalog {
        var categories: [LiveRailEntry] = []
        for entry in library.channelCategories where entry.count > 0 {
            if entry.category == .xxx && !includeAdult { continue }
            categories.append(LiveRailEntry(selection: .category(entry.category), count: entry.count))
        }
        var seen = Set<String>()
        var groups: [LiveRailEntry] = []
        for group in library.channelGroups where !group.channels.isEmpty {
            guard seen.insert(group.name).inserted else { continue }
            let count = includeAdult ? group.channels.count : group.channels.filter { !$0.isAdult }.count
            guard count > 0 else { continue }
            groups.append(LiveRailEntry(selection: .group(group.name), count: count))
        }
        return LiveRailCatalog(showcaseCount: library.liveShowcase.count, categories: categories, groups: groups)
    }
}

// MARK: - Row views

private struct LiveRailSectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .textCase(.uppercase)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
            }
        }
        .font(Tuna.Fonts.micro)
        .tracking(1.2)
        .foregroundStyle(Tuna.Palette.textTertiary)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

private struct LiveRailRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : tint)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(isSelected ? 0.85 : 0.16))
                    )
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Tuna.Palette.textPrimary : Tuna.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(Tuna.Fonts.monoSmall)
                    .foregroundStyle(isSelected ? Tuna.Palette.textSecondary : Tuna.Palette.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel("\(title), \(count) channels")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tuna.Palette.accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Tuna.Palette.accent.opacity(0.38), lineWidth: 1)
                )
                .matchedGeometryEffect(id: "live.rail.highlight", in: namespace)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
    }
}
