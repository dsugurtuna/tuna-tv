import SwiftUI
import TunaCore

enum VaultShelfTab: String, CaseIterable, Identifiable, Hashable {
    case movies, series, channels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        case .channels: return "Channels"
        }
    }
}

/// One Vault shelf (route `.vaultShelf(shelf)`): Movies / Series / Channels grids, each card says why it is here.
struct VaultShelfView: View {
    let shelf: VaultShelf
    @Environment(AppModel.self) private var model
    @AppStorage(VaultLook.languageStorageKey) private var preferredLanguage: String = ""
    @State private var tab: VaultShelfTab = .movies
    @State private var languageLabel: String?
    @State private var askPIN = false

    init(shelf: VaultShelf) {
        self.shelf = shelf
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 28) {
                    VaultShelfHeader(shelf: shelf)
                    if shelf == .adult && VaultAccess.isAdultBlocked(model) {
                        lockedState
                    } else {
                        VaultShelfContent(shelf: shelf, tab: $tab, languageLabel: $languageLabel)
                    }
                }
                .padding(.top, Tuna.Metrics.topBarHeight + 76)
                .padding(.bottom, 80)
            }
            TDBackButton()
        }
        .sheet(isPresented: $askPIN) { VaultPINSheet(onUnlocked: {}) }
        .onAppear {
            if shelf == .otherLanguages, !preferredLanguage.isEmpty {
                languageLabel = VaultShelfContent.languageLabel(preferredLanguage)
                preferredLanguage = ""
            }
        }
    }

    @ViewBuilder
    private var lockedState: some View {
        if model.settings.content.hideAdult {
            EmptyStateView(symbol: "eye.slash.fill",
                           title: "Adult content is hidden",
                           message: "You can show it in Settings › Content.")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            EmptyStateView(symbol: "lock.fill",
                           title: "This shelf is locked",
                           message: "Enter your PIN to open it.",
                           actionTitle: "Unlock",
                           action: { askPIN = true })
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }
}

private struct VaultShelfHeader: View {
    let shelf: VaultShelf

    var body: some View {
        HStack(spacing: 22) {
            VaultShelfLogo(shelf: shelf, size: 72, glowing: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("THE VAULT")
                    .font(Tuna.Fonts.micro)
                    .tracking(2)
                    .foregroundStyle(Tuna.Palette.gold)
                Text(shelf.title)
                    .font(Tuna.Fonts.pageTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text(shelf.subtitle)
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .tunaPageInset()
    }
}

private struct VaultShelfContent: View {
    let shelf: VaultShelf
    @Binding var tab: VaultShelfTab
    @Binding var languageLabel: String?
    @Environment(AppModel.self) private var model

    static func languageLabel(_ code: String) -> String {
        let flag = TDFormat.languageFlagCountry(code).map { Flags.emoji(for: $0) } ?? ""
        let name = TDFormat.languageNativeName(code)
        return flag.isEmpty ? name : "\(flag) \(name)"
    }

    var body: some View {
        let movies = model.library.vault(shelf, kind: .movie)
        let series = model.library.vault(shelf, kind: .series)
        let channels = model.library.vaultChannels(shelf)
        let available = availableTabs(movies: movies.count, series: series.count, channels: channels.count)
        let current = available.contains(tab) ? tab : (available.first ?? .movies)
        VStack(alignment: .leading, spacing: 22) {
            if available.isEmpty {
                EmptyStateView(symbol: shelf.symbol, title: "Nothing here", message: "This shelf is empty right now.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                if available.count > 1 {
                    Picker("Kind", selection: $tab) {
                        ForEach(available) { item in
                            Text("\(item.title) · \(count(item, movies.count, series.count, channels.count))").tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)
                    .tunaPageInset()
                }
                switch current {
                case .movies: titleGrid(kind: .movie, all: movies)
                case .series: titleGrid(kind: .series, all: series)
                case .channels: channelGrid(channels)
                }
            }
        }
    }

    private func availableTabs(movies: Int, series: Int, channels: Int) -> [VaultShelfTab] {
        var out: [VaultShelfTab] = []
        if movies > 0 { out.append(.movies) }
        if series > 0 { out.append(.series) }
        if channels > 0 { out.append(.channels) }
        return out
    }

    private func count(_ tab: VaultShelfTab, _ movies: Int, _ series: Int, _ channels: Int) -> String {
        switch tab {
        case .movies: return movies.formatted()
        case .series: return series.formatted()
        case .channels: return channels.formatted()
        }
    }

    @ViewBuilder
    private func titleGrid(kind: TitleKind, all: [Title]) -> some View {
        let groups = shelf == .otherLanguages ? model.library.otherLanguageGroups(kind: kind) : []
        let labels = groups.map { VaultShelfContent.languageLabel($0.language) }
        let filtered = filteredTitles(all: all, groups: groups, labels: labels)
        VStack(alignment: .leading, spacing: 18) {
            if labels.count > 1 {
                ChipBar(items: labels, selection: $languageLabel, allLabel: "All languages")
                    .tunaPageInset()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tuna.Metrics.posterWidth, maximum: Tuna.Metrics.posterWidth + 28),
                                         spacing: 20, alignment: .top)],
                      alignment: .leading, spacing: 28) {
                ForEach(filtered) { item in
                    VaultTitleCell(title: item, shelf: shelf)
                }
            }
            .tunaPageInset()
        }
    }

    private func filteredTitles(all: [Title], groups: [(language: String, titles: [Title])], labels: [String]) -> [Title] {
        guard let languageLabel, let index = labels.firstIndex(of: languageLabel), index < groups.count else { return all }
        return groups[index].titles
    }

    @ViewBuilder
    private func channelGrid(_ channels: [Channel]) -> some View {
        let codes = shelf == .otherLanguages ? languageCodes(channels) : []
        let labels = codes.map { VaultShelfContent.languageLabel($0) }
        let selectedCode: String? = languageLabel.flatMap { label in labels.firstIndex(of: label).map { codes[$0] } }
        let shown = selectedCode.map { code in channels.filter { $0.languages.first?.lowercased() == code } } ?? channels
        VStack(alignment: .leading, spacing: 18) {
            if labels.count > 1 {
                ChipBar(items: labels, selection: $languageLabel, allLabel: "All languages")
                    .tunaPageInset()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tuna.Metrics.channelCardWidth, maximum: Tuna.Metrics.channelCardWidth + 40),
                                         spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 18) {
                ForEach(shown) { channel in
                    ChannelCard(channel: channel,
                                now: model.nowPlaying(on: channel),
                                next: model.nextProgram(on: channel),
                                isPlaying: isPlaying(channel),
                                isFavorite: model.isFavorite(channel)) {
                        model.play(channel)
                    }
                }
            }
            .tunaPageInset()
        }
    }

    private func languageCodes(_ channels: [Channel]) -> [String] {
        var counts: [String: Int] = [:]
        for channel in channels {
            if let code = channel.languages.first?.lowercased() { counts[code, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key }
    }

    private func isPlaying(_ channel: Channel) -> Bool {
        if case .channel(let playing, _)? = model.player?.content { return playing.id == channel.id }
        return false
    }
}

/// Poster + a badge row explaining why the title sits in the Vault (hidden while the card's own info reveal shows).
private struct VaultTitleCell: View {
    let title: Title
    let shelf: VaultShelf
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        PosterCard(title: title, metadata: model.metadata(for: title), progress: model.progress(for: title)) {
            model.router.open(.title(title.id))
        }
        .overlay(alignment: .topTrailing) {
            VaultReasonBadge(title: title, shelf: shelf)
                .padding(8)
                .opacity(hovering ? 0 : 1)
                .allowsHitTesting(false)
        }
        .onHover { inside in
            withAnimation(Tuna.Motion.snappy) { hovering = inside }
        }
    }
}

private struct VaultReasonBadge: View {
    let title: Title
    let shelf: VaultShelf

    var body: some View {
        let variant = title.defaultVariant
        HStack(spacing: 4) {
            reason(variant)
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    @ViewBuilder
    private func reason(_ variant: Variant?) -> some View {
        switch shelf {
        case .disc:
            if let source = variant?.parsed.source {
                SourceBadge(source: source)
            } else {
                TDTextChip(text: "Disc", symbol: "opticaldisc.fill", tint: Tuna.Palette.bluray)
            }
        case .highDefinition:
            QualityBadge(quality: variant?.effectiveQuality ?? title.bestQuality, hdr: variant?.parsed.hdr, compact: true)
        case .legacy:
            let quality = variant?.effectiveQuality ?? title.bestQuality
            if quality == .unknown {
                TDTextChip(text: "Unknown quality", tint: Tuna.Palette.sd)
            } else {
                QualityBadge(quality: quality, compact: true)
            }
        case .lowQuality:
            if let source = variant?.parsed.source {
                SourceBadge(source: source)
            } else {
                TDTextChip(text: "CAM", symbol: "video.slash.fill", tint: Tuna.Palette.cam)
            }
        case .otherLanguages:
            if let language = variant?.parsed.languages.first ?? title.languages.first {
                LanguageChip(languageCode: language)
            } else if let country = variant?.parsed.countries.first ?? title.countries.first {
                FlagView(countryCode: country, size: 13, showCode: true)
            } else {
                TDTextChip(text: "Foreign", symbol: "globe", tint: Tuna.Palette.accentCool)
            }
        case .unsorted:
            TDTextChip(text: "Unsorted", symbol: "questionmark", tint: Tuna.Palette.hdr)
        case .adult:
            TDTextChip(text: "18+", symbol: "lock.fill", tint: Color(hex: 0xFF4F8B))
        }
    }
}
