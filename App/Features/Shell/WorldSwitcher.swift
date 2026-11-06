import SwiftUI
import TunaCore

/// Top-bar button with stacked flag circles of the user's worlds; opens the world picker popover.
struct WorldSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        let worlds = model.settings.content.worlds
        let groups = WorldEditing.groups(for: worlds)
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                ShellFlagStack(codes: groups.map(\.flagCode), maxVisible: 3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(hovering || isOpen ? 0.1 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Your showcase: \(WorldEditing.summary(for: worlds))")
        .accessibilityLabel("Your showcase: \(WorldEditing.summary(for: worlds))")
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
        .animation(Tuna.Motion.snappy, value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ScrollView {
                WorldPickerPanel(style: .popover)
                    .padding(18)
            }
            .frame(width: 420, height: 580)
            .background(Tuna.Palette.surface)
            .environment(model)
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Overlapping flag circles ("🇬🇧🇹🇷 +2").
struct ShellFlagStack: View {
    let codes: [String]
    var maxVisible: Int = 3
    var diameter: CGFloat = 24

    var body: some View {
        let visible = Array(codes.prefix(maxVisible))
        HStack(spacing: -diameter * 0.32) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, code in
                ShellFlagCircle(code: code, diameter: diameter)
                    .overlay(Circle().strokeBorder(Tuna.Palette.background.opacity(0.9), lineWidth: 2))
                    .zIndex(Double(visible.count - index))
            }
            if codes.count > maxVisible {
                Text("+\(codes.count - maxVisible)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .frame(width: diameter, height: diameter)
                    .background(Circle().fill(Tuna.Palette.surfaceRaised))
                    .overlay(Circle().strokeBorder(Tuna.Palette.background.opacity(0.9), lineWidth: 2))
            }
        }
    }
}

/// Add/remove worlds: current worlds as chips, popular worlds, then every country (searchable).
/// Used by the top-bar popover and by Settings → Content.
struct WorldPickerPanel: View {
    enum Style { case popover, settings }

    @Environment(AppModel.self) private var model
    var style: Style = .popover

    @State private var query = ""

    var body: some View {
        let worlds = model.settings.content.worlds
        let groups = WorldEditing.groups(for: worlds)
        VStack(alignment: .leading, spacing: 16) {
            if style == .popover {
                VStack(alignment: .leading, spacing: 4) {
                    WorldPanelLabel(text: "Your showcase")
                    Text(WorldEditing.summary(for: worlds))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ShellFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(groups) { group in
                    WorldGroupChip(group: group, canRemove: WorldEditing.canRemove(group, from: worlds)) {
                        setWorlds(WorldEditing.removingGroup(group, from: model.settings.content.worlds))
                    }
                }
            }

            WorldPanelLabel(text: "Popular worlds")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], spacing: 6) {
                ForEach(WorldDirectory.featured) { country in
                    WorldFeaturedToggle(country: country,
                                        isSelected: WorldEditing.isLanguageWorldSelected(country, in: worlds)) {
                        setWorlds(WorldEditing.toggledLanguageWorld(country, in: model.settings.content.worlds))
                    }
                }
            }

            WorldPanelLabel(text: "All countries")
            WorldSearchField(text: $query, prompt: "Search countries or languages")
            countryList(worlds)

            Text("Everything outside your worlds is still one click away in The Vault → Other Languages.")
                .font(.system(size: 11))
                .foregroundStyle(Tuna.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func countryList(_ worlds: WorldSelection) -> some View {
        let results = WorldEditing.search(query)
        if results.isEmpty {
            Text("No country matches “\(query)”.")
                .font(.system(size: 12))
                .foregroundStyle(Tuna.Palette.textTertiary)
                .padding(.vertical, 6)
        } else if style == .popover {
            countryRows(results, worlds: worlds)
        } else {
            ScrollView {
                countryRows(results, worlds: worlds)
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        }
    }

    private func countryRows(_ results: [CountryInfo], worlds: WorldSelection) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(results) { country in
                WorldCountryRow(country: country, isSelected: worlds.includes(country: country.code)) {
                    setWorlds(WorldEditing.toggledCountry(country, in: model.settings.content.worlds))
                }
            }
        }
    }

    private func setWorlds(_ newValue: WorldSelection) {
        guard newValue != model.settings.content.worlds else { return }
        withAnimation(Tuna.Motion.snappy) {
            model.updateSettings { $0.content.worlds = newValue }
        }
    }
}

struct WorldPanelLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Tuna.Palette.textTertiary)
    }
}

struct WorldSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tuna.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct WorldGroupChip: View {
    let group: WorldEditing.WorldGroup
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ShellFlagCircle(code: group.flagCode, diameter: 20)
            Text(group.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(1)
            if group.countries.count > 1 {
                Text("\(group.countries.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove \(group.name)")
                .accessibilityLabel("Remove \(group.name)")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, canRemove ? 4 : 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .help(group.countries.map { WorldEditing.countryEnglishName($0) }.joined(separator: ", "))
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
}

struct WorldFeaturedToggle: View {
    let country: CountryInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(country.flag)
                    .font(.system(size: 17))
                Text(country.nativeName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Tuna.Palette.accent : Tuna.Palette.textTertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Tuna.Palette.accent.opacity(0.16) : Color.white.opacity(hovering ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Tuna.Palette.accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(WorldEditing.countryEnglishName(country.code))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in hovering = inside }
        .animation(Tuna.Motion.snappy, value: isSelected)
    }
}

struct WorldCountryRow: View {
    let country: CountryInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(country.flag)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(country.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    if country.nativeName != country.name && !country.nativeName.isEmpty {
                        Text(country.nativeName)
                            .font(.system(size: 11))
                            .foregroundStyle(Tuna.Palette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(languagesText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Tuna.Palette.accent : Tuna.Palette.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in hovering = inside }
    }

    private var languagesText: String {
        country.languages.prefix(2).map { WorldEditing.languageEnglishName($0) }.joined(separator: ", ")
    }
}
