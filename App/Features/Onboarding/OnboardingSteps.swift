import SwiftUI
import TunaCore

// MARK: - Step 2: provider

struct OnboardingProviderStep: View {
    @Binding var draft: ProviderSetupDraft
    @Binding var validation: ProviderValidation
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScaffold(step: .provider,
                               title: "Add your provider",
                               subtitle: "Tuna TV works with Xtream Codes logins and M3U playlists. Your password stays in your Mac's Keychain.") {
            ProviderSetupForm(draft: $draft, validation: $validation, mode: .create, checkIsDefaultAction: true)
        } actions: {
            OnboardingBackButton(action: { onBack() })
            Spacer(minLength: 12)
            if canContinueAnyway {
                Button("Continue anyway") { onContinue() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .help("Some playlists refuse a quick check but still load fine.")
            }
            GlassButton(title: "Continue", systemImage: "arrow.right", style: .primary, action: { onContinue() })
                .keyboardShortcut(validation.allowsContinue ? .defaultAction : nil)
                .disabled(!validation.allowsContinue)
        }
    }

    /// Playlists sometimes reject the quick check but load fine; let people try.
    private var canContinueAnyway: Bool {
        draft.kind == .m3u && validation.errorMessage != nil && draft.resolvedServer != nil
    }
}

// MARK: - Step 3: worlds

struct OnboardingWorldsStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var query = ""

    var body: some View {
        let worlds = model.settings.content.worlds
        OnboardingStepScaffold(step: .worlds,
                               title: "Choose your worlds",
                               subtitle: "Your showcase is built around the languages and countries you pick. Everything else waits, neatly sorted, in The Vault.",
                               maxWidth: 880) {
            VStack(alignment: .leading, spacing: 22) {
                summary(worlds)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 14)], spacing: 14) {
                    ForEach(WorldDirectory.featured) { country in
                        OnboardingWorldCard(country: country,
                                            isSelected: WorldEditing.isLanguageWorldSelected(country, in: worlds)) {
                            setWorlds(WorldEditing.toggledLanguageWorld(country, in: model.settings.content.worlds))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    WorldPanelLabel(text: "Somewhere else?")
                    WorldSearchField(text: $query, prompt: "Search more countries or languages")
                        .frame(maxWidth: 420)
                    if ShellText.clean(query) != nil {
                        searchResults(worlds)
                    }
                }
            }
        } actions: {
            OnboardingBackButton(action: { onBack() })
            Spacer(minLength: 12)
            GlassButton(title: "Continue", systemImage: "arrow.right", style: .primary, action: { onContinue() })
                .keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ worlds: WorldSelection) -> some View {
        HStack(spacing: 10) {
            ShellFlagStack(codes: WorldEditing.groups(for: worlds).map(\.flagCode), maxVisible: 5, diameter: 22)
            HStack(spacing: 5) {
                Text("Your showcase:")
                    .foregroundStyle(Tuna.Palette.textSecondary)
                Text(WorldEditing.summary(for: worlds))
                    .fontWeight(.semibold)
                    .foregroundStyle(Tuna.Palette.textPrimary)
            }
            .font(.system(size: 14))
        }
        .animation(Tuna.Motion.snappy, value: worlds)
    }

    @ViewBuilder
    private func searchResults(_ worlds: WorldSelection) -> some View {
        let results = Array(WorldEditing.search(query).prefix(30))
        if results.isEmpty {
            Text("No country matches “\(query)”.")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textTertiary)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(results) { country in
                    WorldCountryRow(country: country, isSelected: worlds.includes(country: country.code)) {
                        setWorlds(WorldEditing.toggledCountry(country, in: model.settings.content.worlds))
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
            .transition(.opacity)
        }
    }

    private func setWorlds(_ newValue: WorldSelection) {
        guard newValue != model.settings.content.worlds else { return }
        withAnimation(Tuna.Motion.snappy) {
            model.updateSettings { $0.content.worlds = newValue }
        }
    }
}

/// Big selectable country card: flag, native name, language.
struct OnboardingWorldCard: View {
    let country: CountryInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(country.flag)
                        .font(.system(size: 40))
                    Spacer(minLength: 0)
                    checkmark
                }
                Text(country.nativeName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Tuna.Palette.accent : Color.white.opacity(hovering ? 0.16 : 0.08),
                              lineWidth: isSelected ? 2 : 1))
            .shadow(color: Tuna.Palette.accent.opacity(isSelected ? 0.32 : 0), radius: 18, x: 0, y: 8)
            .scaleEffect(isSelected ? 1 : (hovering ? 1.02 : 0.98))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(country.nativeName), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
        .animation(Tuna.Motion.hover, value: isSelected)
    }

    private var checkmark: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(isSelected ? 0 : 0.25), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Tuna.Palette.inkOnLight, Tuna.Palette.accent)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Tuna.Palette.accent.opacity(0.24), Tuna.Palette.accentWarm.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.045))
        }
    }

    /// Language in English ("Turkish"), or the English country name when that says more.
    private var subtitle: String {
        let language = country.languages.first.map { WorldEditing.languageEnglishName($0) } ?? ""
        if !language.isEmpty && language != country.nativeName { return language }
        let englishName = WorldEditing.countryEnglishName(country.code)
        return englishName == country.nativeName ? country.code.uppercased() : englishName
    }
}

// MARK: - Step 4: quality

struct OnboardingQualityStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        let current = model.settings.content.showcaseQuality
        OnboardingStepScaffold(step: .quality,
                               title: "Only the best makes the showcase",
                               subtitle: "Pick the quality bar for Home, Movies, Series and Live.",
                               maxWidth: 880) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(ShowcaseQuality.allCases, id: \.self) { quality in
                        OnboardingQualityCard(quality: quality, isSelected: quality == current) {
                            withAnimation(Tuna.Motion.snappy) {
                                model.updateSettings { $0.content.showcaseQuality = quality }
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(Tuna.Palette.hdr)
                    Text("Everything else goes to The Vault.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                }
                Toggle(isOn: autoRelaxBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fill thin shelves automatically")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        Text("If your worlds have little 4K, the next tier steps in for that shelf — and Tuna TV tells you.")
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Tuna.Palette.accent)
            }
        } actions: {
            OnboardingBackButton(action: { onBack() })
            Spacer(minLength: 12)
            GlassButton(title: "Continue", systemImage: "arrow.right", style: .primary, action: { onContinue() })
                .keyboardShortcut(.defaultAction)
        }
    }

    private var autoRelaxBinding: Binding<Bool> {
        Binding(
            get: { model.settings.content.autoRelaxShowcase },
            set: { newValue in model.updateSettings { $0.content.autoRelaxShowcase = newValue } })
    }
}

struct OnboardingQualityCard: View {
    let quality: ShowcaseQuality
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text(ShowcaseCopy.badge(quality))
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(badgeStyle)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Tuna.Palette.accent : Tuna.Palette.textTertiary)
                        .symbolEffect(.bounce, value: isSelected)
                }
                Text(ShowcaseCopy.title(quality))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ShowcaseCopy.detail(quality))
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if quality == .ultraOnly {
                    ShellTag(text: "Recommended", tint: Tuna.Palette.gold)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? Tuna.Palette.accent.opacity(0.14) : Color.white.opacity(hovering ? 0.075 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Tuna.Palette.accent : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1))
            .shadow(color: Tuna.Palette.accent.opacity(isSelected ? 0.28 : 0), radius: 20, x: 0, y: 10)
            .scaleEffect(isSelected ? 1 : (hovering ? 1.015 : 0.985))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShowcaseCopy.title(quality))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
        .animation(Tuna.Motion.hover, value: isSelected)
    }

    private var badgeStyle: AnyShapeStyle {
        switch quality {
        case .ultraOnly: return AnyShapeStyle(Tuna.Gradients.uhdBadge)
        case .fullHDPlus: return AnyShapeStyle(Tuna.Palette.fhd)
        case .everything: return AnyShapeStyle(Tuna.Palette.textPrimary)
        }
    }
}

// MARK: - Step 5: metadata (optional)

struct OnboardingMetadataStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var tmdbKey = ""
    @State private var omdbKey = ""
    @State private var isSaving = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case tmdb, omdb }

    private var hasInput: Bool { ShellText.clean(tmdbKey) != nil || ShellText.clean(omdbKey) != nil }

    var body: some View {
        OnboardingStepScaffold(step: .metadata,
                               title: "Make every title shine",
                               subtitle: "Optional: add your own free TMDB key and Tuna TV dresses your library with real artwork, cast and ratings. You can do this later in Settings.") {
            VStack(alignment: .leading, spacing: 22) {
                unlocks
                VStack(alignment: .leading, spacing: 8) {
                    ProviderTextField(label: "TMDB API key or Read Access Token",
                                      prompt: model.hasTMDBKey ? "Saved — paste a new key to replace it" : "Paste your key",
                                      text: $tmdbKey,
                                      systemImage: "key.fill",
                                      isFocused: focus == .tmdb,
                                      monospaced: true)
                        .focused($focus, equals: .tmdb)
                    Link(destination: ShellLinks.tmdbKey) {
                        Label("Get a free key", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Tuna.Palette.accentCool)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ProviderTextField(label: "OMDb key (optional: IMDb, Rotten Tomatoes, Metacritic)",
                                      prompt: model.hasOMDbKey ? "Saved — paste a new key to replace it" : "Paste your key",
                                      text: $omdbKey,
                                      systemImage: "star.square.fill",
                                      isFocused: focus == .omdb,
                                      monospaced: true)
                        .focused($focus, equals: .omdb)
                    Link(destination: ShellLinks.omdbKey) {
                        Label("Get a free OMDb key", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Tuna.Palette.accentCool)
                }
                Label("Keys stay in your Mac's Keychain. Lookups go to TMDB and OMDb — never to your IPTV provider.",
                      systemImage: "lock.shield.fill")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingBackButton(action: { onBack() })
            Spacer(minLength: 12)
            if hasInput {
                GlassButton(title: isSaving ? "Saving…" : "Save & continue", systemImage: "checkmark",
                            style: .primary, action: { save() })
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            } else {
                GlassButton(title: "Skip for now", systemImage: "arrow.right", style: .secondary, action: { onContinue() })
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var unlocks: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            OnboardingUnlockTile(symbol: "photo.stack.fill", title: "Posters & backdrops", tint: Tuna.Palette.accent)
            OnboardingUnlockTile(symbol: "person.crop.circle.fill", title: "Cast photos", tint: Tuna.Palette.accentCool)
            OnboardingUnlockTile(symbol: "play.rectangle.fill", title: "Trailers", tint: Tuna.Palette.live)
            OnboardingUnlockTile(symbol: "star.fill", title: "Ratings", tint: Tuna.Palette.gold)
        }
    }

    private func save() {
        let tmdb = ShellText.clean(tmdbKey)
        let omdb = ShellText.clean(omdbKey)
        guard tmdb != nil || omdb != nil, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            await model.setMetadataKeys(tmdb: tmdb, omdb: omdb)
            isSaving = false
            onContinue()
        }
    }
}

struct OnboardingUnlockTile: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
