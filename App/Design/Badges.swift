import SwiftUI
import TunaCore

// MARK: - Quality

/// "4K", "Full HD" ... plus optional HDR/DV mark.
/// 4K: gold gradient pill with a heavy "4K"; Full HD teal; HD blue; SD grey; HDR purple; Dolby Vision black.
struct QualityBadge: View {
    var quality: Quality
    var hdr: HDRFormat? = nil
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            if quality != .unknown {
                DSQualityPill(quality: quality, compact: compact)
            }
            if let hdr {
                DSHDRPill(format: hdr, compact: compact)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if quality != .unknown { parts.append(quality.label) }
        if let hdr { parts.append(hdr.label) }
        return parts.joined(separator: ", ")
    }
}

private struct DSQualityPill: View {
    var quality: Quality
    var compact: Bool

    private var radius: CGFloat { compact ? 4 : 5 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(label)
            .font(compact ? Tuna.Fonts.badgeCompact : Tuna.Fonts.badge)
            .tracking(0.2)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 4.5 : 6.5)
            .frame(height: compact ? Tuna.Metrics.badgeCompactHeight : Tuna.Metrics.badgeHeight)
            .background { fill }
            .overlay {
                LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0)], startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5) }
            .shadow(color: shadowColor, radius: quality == .uhd ? 4 : 0)
    }

    private var label: String {
        switch quality {
        case .uhd: return "4K"
        case .fhd: return compact ? "FHD" : "Full HD"
        case .hd: return "HD"
        case .sd: return "SD"
        case .unknown: return ""
        }
    }

    @ViewBuilder
    private var fill: some View {
        switch quality {
        case .uhd: Tuna.Gradients.uhdBadge
        case .fhd: Tuna.Palette.fhd
        case .hd: Tuna.Palette.hd
        case .sd, .unknown: Tuna.Palette.sd
        }
    }

    private var foreground: Color {
        switch quality {
        case .uhd: return Color(hex: 0x2B1800)
        case .fhd: return Color(hex: 0x03271D)
        case .hd: return Color(hex: 0x081638)
        case .sd, .unknown: return Color.white
        }
    }

    private var shadowColor: Color {
        quality == .uhd ? Tuna.Palette.uhd.opacity(0.45) : Color.clear
    }
}

private struct DSHDRPill: View {
    var format: HDRFormat
    var compact: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
        Text(label)
            .font(compact ? Tuna.Fonts.badgeCompact : Tuna.Fonts.badge)
            .tracking(format == .dolbyVision ? 0.6 : 0.2)
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 4.5 : 6.5)
            .frame(height: compact ? Tuna.Metrics.badgeCompactHeight : Tuna.Metrics.badgeHeight)
            .background { fill }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(format == .dolbyVision ? 0.35 : 0.2), lineWidth: 0.5) }
    }

    private var label: String {
        switch format {
        case .dolbyVision: return compact ? "DV" : "DOLBY VISION"
        case .hdr10Plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .hdr: return "HDR"
        }
    }

    @ViewBuilder
    private var fill: some View {
        if format == .dolbyVision {
            Color.black
        } else {
            Tuna.Gradients.hdr
        }
    }
}

// MARK: - Source

/// Blu-ray / REMUX / WEB-DL / DVD ... ; CAM/TS/SCR in warning orange.
struct SourceBadge: View {
    var source: SourceTag

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(source.label)
                .font(Tuna.Fonts.badge)
                .tracking(0.2)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(height: Tuna.Metrics.badgeHeight)
        .background { fill }
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5) }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(source.label))
    }

    private var symbol: String? {
        switch source {
        case .bluray, .remux: return "opticaldisc.fill"
        case .dvd: return "opticaldisc"
        case .webdl, .webrip: return "arrow.down.circle.fill"
        case .hdtv: return "tv"
        case .cam, .telesync, .screener: return "exclamationmark.triangle.fill"
        }
    }

    private var foreground: Color {
        switch source {
        case .cam, .telesync, .screener: return Color(hex: 0x2A0E00)
        default: return Color.white
        }
    }

    @ViewBuilder
    private var fill: some View {
        switch source {
        case .bluray: Tuna.Palette.bluray
        case .remux: Tuna.Gradients.remux
        case .webdl: Tuna.Palette.web.opacity(0.9)
        case .webrip: Tuna.Palette.web.opacity(0.6)
        case .hdtv: Tuna.Palette.hdtv
        case .dvd: Tuna.Palette.dvd
        case .cam, .telesync, .screener: Tuna.Palette.cam
        }
    }
}

// MARK: - Flags & languages

/// Emoji flag (+ optional code/name).
struct FlagView: View {
    var countryCode: String
    var size: CGFloat = 14
    var showCode: Bool = false

    var body: some View {
        let code = DSFlagCode.normalize(countryCode)
        let emoji = Flags.emoji(for: code)
        HStack(spacing: 4) {
            if emoji.isEmpty {
                Text(code.isEmpty ? "?" : code)
                    .font(.system(size: max(7, size * 0.6), weight: .heavy))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .padding(.horizontal, 3)
                    .frame(height: size)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Text(emoji)
                    .font(.system(size: size))
            }
            if showCode, !emoji.isEmpty {
                Text(code)
                    .font(.system(size: max(9, size * 0.72), weight: .bold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(WorldDirectory.country(code)?.name ?? code))
    }
}

enum DSFlagCode {
    /// Upper-cases and fixes common non-ISO country tags seen in IPTV names ("UK" -> "GB").
    static func normalize(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch upper {
        case "UK": return "GB"
        case "EL": return "GR"
        default: return upper
        }
    }
}

/// Language chip: flag + native name (or the code when compact / unknown).
struct LanguageChip: View {
    var languageCode: String
    var compact: Bool = true

    var body: some View {
        let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let info = WorldDirectory.language(code)
        let flag = info?.flag ?? ""
        let text = compact ? code.uppercased() : (info?.nativeName ?? code.uppercased())
        HStack(spacing: 5) {
            if !flag.isEmpty {
                Text(flag).font(.system(size: compact ? 11 : 13))
            }
            Text(text)
                .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary.opacity(0.9))
        }
        .padding(.horizontal, compact ? 7 : 10)
        .frame(height: compact ? 20 : 26)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay { Capsule().strokeBorder(Tuna.Palette.stroke, lineWidth: 1) }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(info?.name ?? code.uppercased()))
    }
}

// MARK: - Ratings

/// TMDB teal "TMDB 7.8", IMDb yellow box "IMDb 8.1", Rotten Tomatoes "🍅 92%", Metacritic green square "81",
/// provider star "★ 7.4". Text only, never brand logos.
struct RatingChip: View {
    var source: RatingSource
    /// tmdb/imdb/provider: 0-10; rottenTomatoes/metacritic: 0-100.
    var value: Double
    var votes: Int? = nil

    var body: some View {
        HStack(spacing: 5) {
            mark
            Text(valueText)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Tuna.Palette.textPrimary)
            if let votesText {
                Text(votesText)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder
    private var mark: some View {
        switch source {
        case .tmdb:
            Text(verbatim: "TMDB")
                .font(.system(size: 9.5, weight: .black))
                .tracking(0.3)
                .foregroundStyle(Color(hex: 0x0D253F))
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Tuna.Gradients.tmdb, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .imdb:
            Text(verbatim: "IMDb")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(Tuna.Palette.imdb, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .rottenTomatoes:
            Text(verbatim: value >= 60 ? "🍅" : "🥀")
                .font(.system(size: 12))
        case .metacritic:
            Text(String(Int(value.rounded())))
                .font(.system(size: 11, weight: .black))
                .monospacedDigit()
                .foregroundStyle(metacriticInk)
                .frame(minWidth: 20)
                .frame(height: 18)
                .padding(.horizontal, 2)
                .background(metacriticColor, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .provider:
            Image(systemName: "star.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Tuna.Palette.gold)
        }
    }

    private var valueText: String {
        switch source {
        case .tmdb, .imdb, .provider: return String(format: "%.1f", min(10, max(0, value)))
        case .rottenTomatoes: return "\(Int(value.rounded()))%"
        case .metacritic: return ""
        }
    }

    private var votesText: String? {
        guard let votes, votes > 0 else { return nil }
        switch source {
        case .tmdb, .imdb, .provider: return DSNumberFormat.compact(votes)
        case .rottenTomatoes, .metacritic: return nil
        }
    }

    private var metacriticColor: Color {
        if value >= 61 { return Tuna.Palette.metacritic }
        if value >= 40 { return Tuna.Palette.metacriticMixed }
        return Tuna.Palette.metacriticBad
    }

    private var metacriticInk: Color { value >= 40 ? Color.black : Color.white }

    private var accessibilityText: String {
        switch source {
        case .tmdb: return "TMDB rating \(valueText)"
        case .imdb: return "IMDb rating \(valueText)"
        case .rottenTomatoes: return "Rotten Tomatoes \(valueText)"
        case .metacritic: return "Metacritic \(Int(value.rounded()))"
        case .provider: return "Rating \(valueText)"
        }
    }
}

enum DSNumberFormat {
    /// 950 -> "950", 12_400 -> "12.4K", 1_250_000 -> "1.3M".
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 10_000 { return String(format: "%.0fK", number / 1_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return String(value)
    }
}

// MARK: - Small chips

/// Outlined certification ("PG-13", "TV-MA", "12").
struct CertificationBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Tuna.Palette.textSecondary)
            .padding(.horizontal, 5)
            .frame(height: Tuna.Metrics.badgeHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Tuna.Palette.textSecondary.opacity(0.7), lineWidth: 1)
            }
            .fixedSize()
            .accessibilityLabel(Text("Rated \(text)"))
    }
}

/// Text chip for a streaming platform tag ("Netflix", "Exxen"); text only, never brand logos.
struct PlatformChip: View {
    var name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(Tuna.Palette.textPrimary.opacity(0.88))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(Tuna.Palette.strokeStrong, lineWidth: 0.75) }
            .fixedSize()
    }
}

// MARK: - Live

/// Pulsing red "LIVE" pill.
struct LiveBadge: View {
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            DSLiveDot(size: compact ? 5 : 6, animated: !reduceMotion)
            Text(verbatim: "LIVE")
                .font(.system(size: compact ? 9 : 10, weight: .heavy))
                .tracking(0.9)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: compact ? 16 : 20)
        .background(Tuna.Gradients.live, in: Capsule())
        .shadow(color: Tuna.Palette.live.opacity(0.5), radius: compact ? 4 : 6)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live"))
    }
}

/// White dot with an expanding "ping" ring.
private struct DSLiveDot: View {
    var size: CGFloat
    var animated: Bool

    var body: some View {
        ZStack {
            if animated {
                PhaseAnimator([0, 1, 2]) { phase in
                    Circle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: size, height: size)
                        .scaleEffect(phase == 2 ? 2.6 : 1)
                        .opacity(phase == 1 ? 0.9 : 0)
                } animation: { phase in
                    DSLiveDot.animation(for: phase)
                }
            }
            Circle()
                .fill(Color.white)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }

    static func animation(for phase: Int) -> Animation {
        switch phase {
        case 1: return .easeIn(duration: 0.15)
        case 2: return .easeOut(duration: 1.1)
        default: return .linear(duration: 0.25)
        }
    }
}

// MARK: - Progress

/// Thin progress bar (watch progress / programme progress).
struct ProgressLine: View {
    var fraction: Double
    var tint: Color = Tuna.Palette.accent
    var height: CGFloat = 3

    var body: some View {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                if clamped > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, proxy.size.width * CGFloat(clamped)))
                        .shadow(color: tint.opacity(0.45), radius: 3)
                }
            }
        }
        .frame(height: height)
        .animation(Tuna.Motion.snappy, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text("\(Int((clamped * 100).rounded())) percent"))
    }
}
