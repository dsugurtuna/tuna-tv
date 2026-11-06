import SwiftUI
import TunaCore

/// The Vault section: one box holding everything that is not showcase material.
struct VaultView: View {
    @Environment(AppModel.self) private var model
    @State private var askPIN = false

    init() {}

    private var visibleShelves: [VaultShelf] {
        let counts = model.library.vaultCounts
        return VaultShelf.allCases.filter { shelf in
            (counts[shelf] ?? 0) > 0 && VaultLook.isVisible(shelf, settings: model.settings)
        }
    }

    var body: some View {
        let shelves = visibleShelves
        let counts = model.library.vaultCounts
        let total = shelves.reduce(0) { $0 + (counts[$1] ?? 0) }
        let languageCount = shelves.contains(.otherLanguages) ? model.library.otherLanguageGroups(kind: nil).count : 0
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                VaultHero(total: total, shelves: shelves.count, languages: languageCount)
                    .staggeredAppear(index: 0)
                if shelves.isEmpty {
                    EmptyStateView(symbol: "shippingbox",
                                   title: "Your Vault is empty",
                                   message: "Everything in your library made the showcase. Nice provider!")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Shelves", subtitle: "Pick a shelf — every title keeps all its versions")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 20, alignment: .top)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(Array(shelves.enumerated()), id: \.element) { item in
                                VaultShelfTile(shelf: item.element, count: counts[item.element] ?? 0) {
                                    open(item.element)
                                }
                                .staggeredAppear(index: item.offset + 1)
                            }
                        }
                    }
                    .tunaPageInset()
                    if shelves.contains(.otherLanguages) {
                        VaultLanguagesSection()
                            .staggeredAppear(index: shelves.count + 1)
                    }
                }
            }
            .padding(.top, Tuna.Metrics.topBarHeight + 28)
            .padding(.bottom, 80)
        }
        .sheet(isPresented: $askPIN) {
            VaultPINSheet { model.router.open(.vaultShelf(.adult)) }
        }
    }

    private func open(_ shelf: VaultShelf) {
        if shelf == .adult && VaultAccess.needsPIN(model) {
            askPIN = true
            return
        }
        model.router.open(.vaultShelf(shelf))
    }
}

struct VaultPreview: Identifiable {
    let id: String
    let url: String?
    let kind: ArtworkKind
    let name: String
}

/// Shelf tile: glowing logo on tinted glass, title, subtitle, count and a fan of three mini posters.
struct VaultShelfTile: View {
    let shelf: VaultShelf
    let count: Int
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let tint = VaultLook.tint(shelf)
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let locked = shelf == .adult && VaultAccess.needsPIN(model)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VaultShelfLogo(shelf: shelf, size: 62, glowing: hovering)
                    Spacer(minLength: 8)
                    VaultPosterStrip(previews: previews, tint: tint, locked: shelf == .adult)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(shelf.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tint)
                        }
                    }
                    Text(shelf.subtitle)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(count.formatted())
                        .font(Tuna.Fonts.rounded(26, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(Tuna.Motion.snappy, value: count)
                    Text(count == 1 ? "item" : "items")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .offset(x: hovering ? 4 : 0)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            .tunaGlass(cornerRadius: 24, tint: tint)
            .overlay(shape.strokeBorder(tint.opacity(hovering ? 0.65 : 0.22), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: tint.opacity(hovering ? 0.35 : 0), radius: 24, x: 0, y: 10)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
        .accessibilityLabel(Text("\(shelf.title), \(count) items"))
    }

    /// Never shows adult artwork on the landing page.
    private var previews: [VaultPreview] {
        if shelf == .adult { return [] }
        let titles = model.library.vault(shelf, kind: nil).prefix(3)
        if !titles.isEmpty {
            return titles.map { item in
                VaultPreview(id: item.id, url: model.metadata(for: item)?.posterURL ?? item.posterURL, kind: .poster, name: item.name)
            }
        }
        return model.library.vaultChannels(shelf).prefix(3).map { channel in
            VaultPreview(id: channel.id, url: channel.logoURL, kind: .channel, name: channel.name)
        }
    }
}

struct VaultPosterStrip: View {
    let previews: [VaultPreview]
    let tint: Color
    let locked: Bool

    var body: some View {
        HStack(spacing: -18) {
            if locked || previews.isEmpty {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: locked ? "lock.fill" : "sparkles").foregroundStyle(tint.opacity(0.8)))
                        .frame(width: 50, height: 75)
                        .rotationEffect(.degrees(Double(index - 1) * 7), anchor: .bottom)
                }
            } else {
                ForEach(Array(previews.enumerated()), id: \.element.id) { item in
                    TunaImage(url: item.element.url, kind: item.element.kind, seed: item.element.id, title: item.element.name)
                        .frame(width: 50, height: item.element.kind == .poster ? 75 : 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 4)
                        .rotationEffect(.degrees(Double(item.offset - 1) * 7), anchor: .bottom)
                        .zIndex(Double(3 - item.offset))
                }
            }
        }
        .padding(.trailing, 6)
        .allowsHitTesting(false)
    }
}

struct VaultLanguageGroup: Identifiable, Hashable {
    let code: String
    let count: Int
    var id: String { code }
}

/// "Other languages": one flag card per language outside the user's worlds.
struct VaultLanguagesSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(VaultLook.languageStorageKey) private var preferredLanguage: String = ""

    var body: some View {
        let groups = model.library.otherLanguageGroups(kind: nil)
            .map { VaultLanguageGroup(code: $0.language, count: $0.titles.count) }
            .filter { $0.count > 0 }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Other languages",
                              subtitle: "Outside your worlds. Add a language and its titles join your showcase.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VaultLanguageCard(group: group,
                                          onOpen: { open(group.code) },
                                          onAdd: { add(group.code) })
                    }
                }
            }
            .tunaPageInset()
        }
    }

    private func open(_ code: String) {
        preferredLanguage = code
        model.router.open(.vaultShelf(.otherLanguages))
    }

    private func add(_ code: String) {
        let language = code.lowercased()
        let country = TDFormat.languageFlagCountry(language) ?? language.uppercased()
        let name = TDFormat.languageName(language)
        model.updateSettings { settings in
            settings.content.worlds = settings.content.worlds.adding(country: country, language: language)
        }
        model.showToast("\(name) is now one of your worlds. Re-curating your showcase…", style: .success)
    }
}

struct VaultLanguageCard: View {
    let group: VaultLanguageGroup
    var onOpen: () -> Void
    var onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = WorldDirectory.language(group.code.lowercased())
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    if let info, !info.flag.isEmpty {
                        FlagView(countryCode: info.flagCountry, size: 34)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Tuna.Palette.accentCool)
                    }
                    Spacer()
                    Text(group.count.formatted())
                        .font(Tuna.Fonts.rounded(20, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Tuna.Palette.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.nativeName ?? group.code.uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    Text(info?.name ?? "Language code \(group.code.uppercased())")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 30)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            .tunaGlass(cornerRadius: 18, tint: hovering ? Tuna.Palette.accentCool : nil)
            .overlay(shape.strokeBorder(hovering ? Tuna.Palette.accentCool.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            Button(action: onAdd) {
                Label("Add to my worlds", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tuna.Palette.accentCool)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bring this language into your showcase")
            .padding(16)
        }
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
    }
}
