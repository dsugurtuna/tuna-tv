import SwiftUI
import TunaCore

/// How the other versions of a title are grouped inside its "Vault box".
enum TDVersionGroup: Int, CaseIterable, Identifiable, Hashable {
    case ultraHD, highDefinition, disc, legacy, lowGrade, otherLanguages

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ultraHD: return "Ultra HD"
        case .highDefinition: return "Full HD & HD"
        case .disc: return "Blu-ray & Disc"
        case .legacy: return "Legacy"
        case .lowGrade: return "Cam & Screeners"
        case .otherLanguages: return "Other languages"
        }
    }

    var shortTitle: String {
        switch self {
        case .ultraHD: return "4K"
        case .highDefinition: return "HD"
        case .disc: return "Disc"
        case .legacy: return "Legacy"
        case .lowGrade: return "Cam"
        case .otherLanguages: return "Languages"
        }
    }

    var symbol: String {
        switch self {
        case .ultraHD: return "sparkles.tv.fill"
        case .highDefinition: return "tv.fill"
        case .disc: return "opticaldisc.fill"
        case .legacy: return "film.stack.fill"
        case .lowGrade: return "exclamationmark.triangle.fill"
        case .otherLanguages: return "globe.europe.africa.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ultraHD: return Tuna.Palette.uhd
        case .highDefinition: return Tuna.Palette.fhd
        case .disc: return Tuna.Palette.bluray
        case .legacy: return Tuna.Palette.sd
        case .lowGrade: return Tuna.Palette.cam
        case .otherLanguages: return Tuna.Palette.accentCool
        }
    }

    static func of(_ variant: Variant) -> TDVersionGroup {
        if let source = variant.parsed.source, source.isLowGrade { return .lowGrade }
        if !variant.matchesWorld { return .otherLanguages }
        let quality = variant.effectiveQuality
        if quality == .uhd { return .ultraHD }
        if let source = variant.parsed.source, source.isDisc { return .disc }
        switch quality {
        case .uhd: return .ultraHD
        case .fhd, .hd: return .highDefinition
        case .sd, .unknown: return .legacy
        }
    }
}

struct TDGroupedVariants: Identifiable {
    let group: TDVersionGroup
    let variants: [Variant]
    var id: Int { group.rawValue }
}

/// "Versions": the default version highlighted, every other version inside a collapsible box.
struct TDVersionsSection: View {
    let title: Title
    @Binding var isOpen: Bool

    var body: some View {
        let others = title.otherVariants
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Versions", subtitle: subtitle(others.count))
            if let variant = title.defaultVariant {
                TDDefaultVersionCard(title: title, variant: variant)
            }
            if !others.isEmpty {
                TDVaultBox(title: title, variants: others, isOpen: $isOpen)
            }
        }
        .tunaPageInset()
    }

    private func subtitle(_ count: Int) -> String {
        if count == 0 { return "This is the only version your provider has." }
        return count == 1 ? "1 more version, merged from your provider's duplicates" : "\(count) more versions, merged from your provider's duplicates"
    }
}

struct TDDefaultVersionCard: View {
    let title: Title
    let variant: Variant
    @Environment(AppModel.self) private var model

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 16) {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Tuna.Gradients.accent))
                .shadow(color: Tuna.Palette.accent.opacity(0.5), radius: 12, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Playing this one:")
                        .foregroundStyle(Tuna.Palette.textSecondary)
                    Text(variant.label)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                }
                .font(.system(size: 16, weight: .bold))
                TDVariantBadges(variant: variant)
                Text(variant.parsed.original)
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            GlassButton(title: "Play", systemImage: "play.fill", style: .primary) {
                model.play(title, variant: variant)
            }
        }
        .padding(18)
        .tunaGlass(cornerRadius: 20, tint: Tuna.Palette.accent)
        .overlay(shape.strokeBorder(Tuna.Gradients.accent, lineWidth: 1.2).opacity(0.7))
    }
}

/// Quality / source / language / audio / codec badges of one variant.
struct TDVariantBadges: View {
    let variant: Variant

    var body: some View {
        let parsed = variant.parsed
        HStack(spacing: 6) {
            if variant.effectiveQuality != .unknown || parsed.hdr != nil {
                QualityBadge(quality: variant.effectiveQuality, hdr: parsed.hdr, compact: true)
            } else {
                TDTextChip(text: "Unknown quality")
            }
            if let source = parsed.source {
                SourceBadge(source: source)
            }
            if let language = parsed.languages.first {
                LanguageChip(languageCode: language)
            } else if let country = parsed.countries.first {
                FlagView(countryCode: country, size: 13, showCode: true)
            }
            if let audio = parsed.audio {
                TDTextChip(text: audio.label, symbol: TDFormat.audioSymbol(audio))
            }
            if let codec = parsed.codec {
                TDTextChip(text: codec.label, symbol: "cpu")
            }
            if parsed.highFrameRate { TDTextChip(text: "60fps") }
            if parsed.is3D { TDTextChip(text: "3D") }
            if variant.verifiedQuality != nil {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.success)
                    .help("Quality verified during playback")
            }
        }
    }
}

/// The collapsible "Vault box" holding the title's other versions. The lid opens with a 3D swing.
struct TDVaultBox: View {
    let title: Title
    let variants: [Variant]
    @Binding var isOpen: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var grouped: [TDGroupedVariants] {
        let dictionary = Dictionary(grouping: variants, by: { TDVersionGroup.of($0) })
        return TDVersionGroup.allCases.compactMap { group in
            guard let list = dictionary[group], !list.isEmpty else { return nil }
            return TDGroupedVariants(group: group, variants: list)
        }
    }

    var body: some View {
        let groups = grouped
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            lid(groups: groups)
            if isOpen {
                Rectangle()
                    .fill(Tuna.Gradients.gold)
                    .frame(height: 1)
                    .opacity(0.35)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { entry in
                        TDVersionGroupView(title: title, group: entry.group, variants: entry.variants)
                    }
                }
                .padding(18)
                .background(alignment: .top) {
                    LinearGradient(colors: [Tuna.Palette.gold.opacity(0.12), Color.clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                }
                .transition(reduceMotion ? AnyTransition.opacity
                            : AnyTransition.asymmetric(insertion: AnyTransition.opacity.combined(with: .move(edge: .top)),
                                                       removal: .opacity))
            }
        }
        .background(shape.fill(Tuna.Palette.surface.opacity(0.7)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(isOpen ? Tuna.Palette.gold.opacity(0.35) : Tuna.Palette.stroke, lineWidth: 1))
    }

    private func lid(groups: [TDGroupedVariants]) -> some View {
        Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.78)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 16) {
                TDBoxGlyph(isOpen: isOpen)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The Vault box")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text(countText)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    ForEach(groups) { entry in
                        TDTextChip(text: "\(entry.variants.count) \(entry.group.shortTitle)", symbol: entry.group.symbol, tint: entry.group.tint)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Close the box" : "Open the box")
    }

    private var countText: String {
        let count = variants.count
        let noun = count == 1 ? "version" : "versions"
        return isOpen ? "\(count) \(noun) — pick any of them" : "\(count) more \(noun) inside"
    }
}

/// Small illustrated box whose lid swings open.
struct TDBoxGlyph: View {
    var isOpen: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Tuna.Palette.gold)
                .frame(width: 30, height: 12)
                .blur(radius: 7)
                .opacity(isOpen ? 0.8 : 0)
                .offset(y: -24)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A3350), Tuna.Palette.surfaceElevated], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tuna.Palette.gold.opacity(0.6), lineWidth: 1))
                .overlay(Rectangle().fill(Tuna.Palette.gold.opacity(0.5)).frame(height: 2).offset(y: -4))
                .frame(width: 38, height: 24)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Tuna.Gradients.gold)
                .frame(width: 42, height: 8)
                .rotation3DEffect(.degrees(isOpen ? -70 : 0), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
                .rotationEffect(.degrees(isOpen ? -16 : 0), anchor: .leading)
                .offset(y: isOpen ? -30 : -24)
        }
        .frame(width: 48, height: 44)
    }
}

struct TDVersionGroupView: View {
    let title: Title
    let group: TDVersionGroup
    let variants: [Variant]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.tint)
                Text(group.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("\(variants.count)")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                if group == .lowGrade {
                    Text("Theatre captures — expect poor picture and sound")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.warning)
                }
            }
            VStack(spacing: 8) {
                ForEach(variants) { variant in
                    TDVersionRow(title: title, variant: variant, group: group)
                }
            }
        }
    }
}

struct TDVersionRow: View {
    let title: Title
    let variant: Variant
    let group: TDVersionGroup
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let failures = model.userState.failingVariants[variant.id] ?? 0
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 14) {
            if group == .otherLanguages {
                FlagView(countryCode: flagCountry, size: 24)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                TDVariantBadges(variant: variant)
                Text(variant.parsed.original)
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detailLine {
                    Text(detail)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if failures > 0 {
                Label("Failed recently", systemImage: "exclamationmark.circle")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.warning)
            }
            GlassButton(title: "Play this version", systemImage: "play.fill", style: .secondary) {
                model.play(title, variant: variant)
            }
        }
        .padding(12)
        .background(shape.fill(hovering ? Tuna.Palette.surfaceRaised : Tuna.Palette.surfaceElevated.opacity(0.6)))
        .overlay(shape.strokeBorder(hovering ? group.tint.opacity(0.4) : Tuna.Palette.stroke, lineWidth: 1))
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
    }

    private var flagCountry: String {
        if let language = variant.parsed.languages.first, let country = TDFormat.languageFlagCountry(language) { return country }
        return variant.parsed.countries.first ?? ""
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let category = TDFormat.clean(variant.raw.categoryName) { parts.append(category) }
        if model.providers.count > 1, let provider = model.providers.first(where: { $0.id == variant.ref.providerID }) {
            parts.append("via \(provider.name)")
        }
        if let ext = TDFormat.clean(variant.raw.containerExtension) { parts.append(ext.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
