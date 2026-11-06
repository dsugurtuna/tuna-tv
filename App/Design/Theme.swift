import SwiftUI

/// Tuna TV design tokens. Dark-first "deep ocean" palette with a warm coral accent.
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
}

extension View {
    /// Glass panel: Liquid Glass on macOS 26 (when built with the macOS 26 SDK), material elsewhere.
    @ViewBuilder
    func tunaGlass(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
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

    func tunaMaterialPanel(cornerRadius: CGFloat, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background((tint ?? .clear).opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
    }

    /// Standard page horizontal inset.
    func tunaPageInset() -> some View { padding(.horizontal, Tuna.Metrics.pageInset) }
}
