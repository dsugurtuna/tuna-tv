import SwiftUI
import AppKit

/// Tuna TV design tokens. Dark-first "deep ocean" palette with a warm coral accent.
/// Every name below is used by screens; add new tokens freely, never rename existing ones.
enum Tuna {
    enum Palette {
        static let background = Color(hex: 0x06080D)
        static let backgroundTop = Color(hex: 0x0A1426)
        static let surface = Color(hex: 0x0E1220)
        static let surfaceElevated = Color(hex: 0x151A2B)
        static let surfaceRaised = Color(hex: 0x1C2236)
        static let stroke = Color.white.opacity(0.08)
        static let strokeStrong = Color.white.opacity(0.16)

        static let textPrimary = Color(hex: 0xF4F6FB)
        static let textSecondary = Color(hex: 0xA7AEC4)
        static let textTertiary = Color(hex: 0x6E7590)

        /// Tuna coral (primary accent).
        static let accent = Color(hex: 0xFF5B5F)
        static let accentWarm = Color(hex: 0xFF8A4C)
        /// Bluefin cyan (secondary accent).
        static let accentCool = Color(hex: 0x3CC8F0)
        static let gold = Color(hex: 0xFFC24B)
        static let live = Color(hex: 0xFF3B47)
        static let success = Color(hex: 0x4ADE9B)
        static let warning = Color(hex: 0xFFB547)
        static let danger = Color(hex: 0xFF5A52)

        // Badge colours
        static let uhd = Color(hex: 0xFFC857)
        static let fhd = Color(hex: 0x5FD3A9)
        static let hd = Color(hex: 0x7CA4FF)
        static let sd = Color(hex: 0x8B90A3)
        static let hdr = Color(hex: 0x9B6BFF)
        static let dolbyVision = Color(hex: 0xE9E9F2)
        static let bluray = Color(hex: 0x2F7CF6)
        static let cam = Color(hex: 0xFF6B3D)
        static let tmdb = Color(hex: 0x01B4E4)
        static let imdb = Color(hex: 0xF5C518)
        static let rottenTomatoes = Color(hex: 0xFA320A)
        static let metacritic = Color(hex: 0x66CC33)

        // Added by the design system
        /// Source badges.
        static let remux = Color(hex: 0x6C5CE7)
        static let web = Color(hex: 0x2EC4B6)
        static let hdtv = Color(hex: 0x5B7A99)
        static let dvd = Color(hex: 0x8E83B5)
        /// Metacritic mixed / negative scores.
        static let metacriticMixed = Color(hex: 0xFFCC33)
        static let metacriticBad = Color(hex: 0xFF4D4D)
        /// Brand mark ocean.
        static let oceanTop = Color(hex: 0x0B1E3F)
        static let oceanBottom = Color(hex: 0x071022)
        /// Thin highlight used on the top edge of glass/pills.
        static let glassHighlight = Color.white.opacity(0.22)
        /// Dark veil for text over artwork.
        static let scrim = Color.black.opacity(0.62)
        /// Ink used on light pills (4K gold, selected chips).
        static let inkOnLight = Color(hex: 0x14090B)
    }

    enum Gradients {
        static let accent = LinearGradient(colors: [Palette.accent, Palette.accentWarm], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let cool = LinearGradient(colors: [Palette.accentCool, Color(hex: 0x6C7CFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let gold = LinearGradient(colors: [Color(hex: 0xFFE08A), Color(hex: 0xFF9E3D)], startPoint: .top, endPoint: .bottom)
        static let uhdBadge = LinearGradient(colors: [Color(hex: 0xFFE08A), Color(hex: 0xFFAA3B)], startPoint: .topLeading, endPoint: .bottomTrailing)
        /// Bottom scrim for hero/backdrops so text stays readable.
        static let heroScrim = LinearGradient(stops: [
            .init(color: Palette.background.opacity(0), location: 0),
            .init(color: Palette.background.opacity(0.55), location: 0.55),
            .init(color: Palette.background, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        /// Left scrim for hero text column.
        static let heroSide = LinearGradient(stops: [
            .init(color: Palette.background.opacity(0.92), location: 0),
            .init(color: Palette.background.opacity(0.55), location: 0.38),
            .init(color: Palette.background.opacity(0), location: 0.7),
        ], startPoint: .leading, endPoint: .trailing)
        static let cardScrim = LinearGradient(colors: [.clear, Color.black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        static let app = LinearGradient(colors: [Palette.backgroundTop, Palette.background], startPoint: .top, endPoint: .center)

        // Added by the design system
        /// Brand mark background (0x0B1E3F -> 0x071022).
        static let ocean = LinearGradient(colors: [Palette.oceanTop, Palette.oceanBottom], startPoint: .top, endPoint: .bottom)
        /// Hover info reveal over the lower half of a poster.
        static let revealScrim = LinearGradient(stops: [
            .init(color: Color.black.opacity(0), location: 0),
            .init(color: Color.black.opacity(0.62), location: 0.32),
            .init(color: Color.black.opacity(0.92), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        /// Small footer scrim on cards (rating / year / progress).
        static let footerScrim = LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        /// Text-only TMDB chip.
        static let tmdb = LinearGradient(colors: [Color(hex: 0x90CEA1), Color(hex: 0x01B4E4)], startPoint: .leading, endPoint: .trailing)
        static let danger = LinearGradient(colors: [Color(hex: 0xFF6B5E), Color(hex: 0xE5383B)], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let remux = LinearGradient(colors: [Palette.bluray, Palette.remux], startPoint: .leading, endPoint: .trailing)
        static let hdr = LinearGradient(colors: [Color(hex: 0xB28BFF), Palette.hdr], startPoint: .top, endPoint: .bottom)
        static let live = LinearGradient(colors: [Color(hex: 0xFF5560), Palette.live], startPoint: .top, endPoint: .bottom)
        /// Fill + outline of the giant Top 10 numerals.
        static let rankFill = LinearGradient(colors: [Color(hex: 0x1F2741), Palette.background], startPoint: .top, endPoint: .bottom)
        static let rankStroke = LinearGradient(colors: [Color.white.opacity(0.92), Color(hex: 0x8D94AE)], startPoint: .top, endPoint: .bottom)
    }

    enum Fonts {
        static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight, design: .default) }
        static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }
        static let heroTitle = Font.system(size: 56, weight: .heavy)
        static let pageTitle = Font.system(size: 34, weight: .heavy)
        static let sectionTitle = Font.system(size: 21, weight: .bold)
        static let cardTitle = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let bodyLarge = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 10, weight: .bold)
        static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let rank = Font.system(size: 170, weight: .black, design: .rounded)

        // Added by the design system
        static let badge = Font.system(size: 10, weight: .heavy)
        static let badgeCompact = Font.system(size: 9, weight: .heavy)
        static let chip = Font.system(size: 13, weight: .semibold)
        static let button = Font.system(size: 14, weight: .semibold)
        static let buttonProminent = Font.system(size: 14, weight: .bold)
        static let monoSmall = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    }

    enum Metrics {
        static let pageInset: CGFloat = 56
        static let topBarHeight: CGFloat = 64
        static let posterWidth: CGFloat = 172
        static let posterAspect: CGFloat = 2.0 / 3.0
        static let landscapeWidth: CGFloat = 320
        static let channelCardWidth: CGFloat = 288
        static let railSpacing: CGFloat = 16
        static let sectionSpacing: CGFloat = 38
        static let cardRadius: CGFloat = 14
        static let panelRadius: CGFloat = 22
        static let heroHeightRatio: CGFloat = 0.78

        // Added by the design system
        /// Poster width inside a Top 10 card (the numeral adds ~60–150 pt on the left).
        static let top10PosterWidth: CGFloat = 150
        /// Headshot diameter of a PersonCard.
        static let personSize: CGFloat = 112
        static let personCardWidth: CGFloat = 128
        /// GlassButton height (capsules) and diameter (icon buttons).
        static let buttonHeight: CGFloat = 38
        static let iconButtonSize: CGFloat = 38
        static let chipHeight: CGFloat = 30
        static let badgeHeight: CGFloat = 18
        static let badgeCompactHeight: CGFloat = 15
        /// Vertical breathing room inside rails so hover-lifted cards are never clipped.
        static let railVerticalPadding: CGFloat = 22
    }

    enum Motion {
        /// Page/overlay transitions.
        static let page = Animation.spring(response: 0.5, dampingFraction: 0.86)
        /// Card hover lift.
        static let hover = Animation.spring(response: 0.32, dampingFraction: 0.72)
        /// Small UI state changes.
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
        static let gentle = Animation.easeInOut(duration: 0.6)
        /// Hero background crossfade.
        static let heroFade = Animation.easeInOut(duration: 1.1)
        /// Per-item delay for staggered appearance.
        static let stagger: Double = 0.035
        static let heroInterval: Double = 8.5
        static let hoverPreviewDelay: Double = 0.65

        // Added by the design system
        /// In-place info reveal on posters.
        static let reveal = Animation.spring(response: 0.38, dampingFraction: 0.84)
        /// Fade + rise of staggered items.
        static let appear = Animation.spring(response: 0.55, dampingFraction: 0.88)
        /// Image fade-in once loaded.
        static let imageFade = Animation.easeOut(duration: 0.32)
        /// Rail paging (chevrons).
        static let scrollPage = Animation.spring(response: 0.6, dampingFraction: 0.9)
        /// Cursor-following 3D tilt.
        static let tilt = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.78)
        /// Items beyond this index appear without the stagger animation.
        static let staggerCap: Int = 16
    }
}

extension Color {
    /// 0xRRGGBB
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Linear sRGB blend towards `other` (0 = self, 1 = other). Works on every macOS 15 SDK (no `Color.mix`).
    func tunaBlend(with other: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        guard let a = NSColor(self).usingColorSpace(.sRGB), let b = NSColor(other).usingColorSpace(.sRGB) else { return self }
        let red = Double(a.redComponent) * (1 - t) + Double(b.redComponent) * t
        let green = Double(a.greenComponent) * (1 - t) + Double(b.greenComponent) * t
        let blue = Double(a.blueComponent) * (1 - t) + Double(b.blueComponent) * t
        let alpha = Double(a.alphaComponent) * (1 - t) + Double(b.alphaComponent) * t
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Relative luminance (0 dark … 1 light) in sRGB, alpha ignored.
    var tunaLuminance: Double {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
    }
}

/// How render-server-only effects are drawn.
enum DSRenderMode {
    /// True in offscreen CI snapshot runs: glass/backdrop effects are replaced by static fills there.
    static let staticGlass: Bool = AppLaunchOptions.isSnapshotRun
}

extension View {
    /// Glass panel: Liquid Glass on macOS 26 (when built with the macOS 26 SDK), material elsewhere.
    /// Offscreen snapshot runs (`--snapshots`) get a static, fully drawn panel instead: `cacheDisplay` cannot
    /// capture Liquid Glass / backdrop layers, and a tinted glass panel made everything drawn beneath it in the
    /// window (hero, text, page background) come out transparent in the PNG.
    @ViewBuilder
    func tunaGlass(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        if DSRenderMode.staticGlass {
            self.tunaStaticPanel(cornerRadius: cornerRadius, tint: tint)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if let tint {
                    self.glassEffect(.regular.tint(tint.opacity(0.35)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                self.tunaMaterialPanel(cornerRadius: cornerRadius, tint: tint)
            }
            #else
            self.tunaMaterialPanel(cornerRadius: cornerRadius, tint: tint)
            #endif
        }
    }

    /// Material-free look-alike of the glass panel (plain fills only), for offscreen rendering.
    func tunaStaticPanel(cornerRadius: CGFloat, tint: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background((tint ?? .clear).opacity(0.22), in: shape)
            .background(Tuna.Palette.surfaceElevated.opacity(0.72), in: shape)
            .overlay(shape.strokeBorder(Tuna.Palette.strokeStrong, lineWidth: 1))
    }

    func tunaMaterialPanel(cornerRadius: CGFloat, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background((tint ?? .clear).opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
    }

    /// Standard page horizontal inset.
    func tunaPageInset() -> some View { padding(.horizontal, Tuna.Metrics.pageInset) }
}
