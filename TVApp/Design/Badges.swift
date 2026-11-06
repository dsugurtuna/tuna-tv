import SwiftUI
import TunaCore

/// Small capsule tag ("4K", "HDR10", "REMUX", "EN").
struct TagBadge: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(Tuna.Fonts.badge)
            .foregroundStyle(filled ? Tuna.Palette.inkOnLight : color)
            .padding(.horizontal, 10)
            .frame(height: Tuna.Metrics.badgeHeight)
            .background(filled ? color : color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(filled ? 0 : 0.55), lineWidth: 1.5))
            .fixedSize()
    }
}

/// Quality tier badge: 4K gold, Full HD green, HD blue, SD grey. Nothing for unknown quality.
struct QualityBadge: View {
    var quality: Quality

    var body: some View {
        switch quality {
        case .uhd: TagBadge(text: "4K", color: Tuna.Palette.uhd, filled: true)
        case .fhd: TagBadge(text: "FULL HD", color: Tuna.Palette.fhd)
        case .hd: TagBadge(text: "HD", color: Tuna.Palette.hd)
        case .sd: TagBadge(text: "SD", color: Tuna.Palette.sd)
        case .unknown: EmptyView()
        }
    }
}

struct HDRBadge: View {
    var format: HDRFormat

    var body: some View {
        switch format {
        case .dolbyVision: TagBadge(text: "DOLBY VISION", color: Tuna.Palette.dolbyVision)
        case .hdr10Plus: TagBadge(text: "HDR10+", color: Tuna.Palette.hdr)
        case .hdr10: TagBadge(text: "HDR10", color: Tuna.Palette.hdr)
        case .hlg: TagBadge(text: "HLG", color: Tuna.Palette.hdr)
        case .hdr: TagBadge(text: "HDR", color: Tuna.Palette.hdr)
        }
    }
}

struct SourceBadge: View {
    var source: SourceTag

    var body: some View {
        TagBadge(text: source.label.uppercased(), color: color)
    }

    private var color: Color {
        if source.isLowGrade { return Tuna.Palette.cam }
        if source == .remux { return Tuna.Palette.remux }
        if source.isDisc { return Tuna.Palette.bluray }
        return Tuna.Palette.web
    }
}

/// "TMDB 7.8" / "IMDb 8.1" chip.
struct RatingChip: View {
    enum Source { case tmdb, imdb }
    var source: Source
    var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(source == .tmdb ? "TMDB" : "IMDb")
                .font(Tuna.Fonts.badge)
                .foregroundStyle(Tuna.Palette.inkOnLight)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(source == .tmdb ? Tuna.Palette.tmdb : Tuna.Palette.imdb,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(String(format: "%.1f", value))
                .font(Tuna.Fonts.rounded(24, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
        }
        .fixedSize()
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.white).frame(width: 9, height: 9)
            Text("LIVE").font(Tuna.Fonts.badge)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .frame(height: Tuna.Metrics.badgeHeight)
        .background(Tuna.Palette.live, in: Capsule())
        .fixedSize()
    }
}

/// Thin progress bar (watch progress, programme progress).
struct ProgressLine: View {
    var fraction: Double
    var height: CGFloat = 6
    var tint: Color = Tuna.Palette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint)
                    .frame(width: max(height, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
    }
}

/// Every badge that describes one version: quality, HDR, source, codec, languages.
struct VariantBadges: View {
    var variant: Variant

    var body: some View {
        HStack(spacing: 8) {
            QualityBadge(quality: variant.effectiveQuality)
            if let hdr = variant.parsed.hdr { HDRBadge(format: hdr) }
            if let source = variant.parsed.source { SourceBadge(source: source) }
            if let codec = variant.parsed.codec { TagBadge(text: codec.label.uppercased(), color: Tuna.Palette.textSecondary) }
            if let audio = variant.parsed.audio { TagBadge(text: audio.label.uppercased(), color: Tuna.Palette.textSecondary) }
            ForEach(Array(variant.parsed.languages.prefix(3)), id: \.self) { code in
                TagBadge(text: LanguageLabel.short(code), color: Tuna.Palette.accentCool)
            }
            if variant.verifiedQuality != nil {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Tuna.Palette.success)
            }
        }
    }
}

enum LanguageLabel {
    /// "en" -> "🇬🇧 EN".
    static func short(_ code: String) -> String {
        if let info = WorldDirectory.language(code) { return "\(info.flag) \(code.uppercased())" }
        return code.uppercased()
    }

    static func name(_ code: String) -> String {
        WorldDirectory.language(code)?.name ?? code.uppercased()
    }
}
