import SwiftUI
import UIKit

/// Tuna TV design tokens for the big screen. Same "deep ocean" palette with the warm coral accent as the Mac
/// app (copied, not shared), with type and spacing scaled for a 10-foot view.
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
        static let remux = Color(hex: 0x6C5CE7)
        static let web = Color(hex: 0x2EC4B6)
        static let oceanTop = Color(hex: 0x0B1E3F)
        static let oceanBottom = Color(hex: 0x071022)
        static let scrim = Color.black.opacity(0.62)
        static let inkOnLight = Color(hex: 0x14090B)
    }

    enum Gradients {
        static let accent = LinearGradient(colors: [Palette.accent, Palette.accentWarm],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
        static let gold = LinearGradient(colors: [Color(hex: 0xFFE08A), Color(hex: 0xFF9E3D)],
                                         startPoint: .top, endPoint: .bottom)
        static let app = LinearGradient(colors: [Palette.backgroundTop, Palette.background],
                                        startPoint: .top, endPoint: .center)
        static let ocean = LinearGradient(colors: [Palette.oceanTop, Palette.oceanBottom],
                                          startPoint: .top, endPoint: .bottom)
        /// Bottom scrim for hero/backdrops so text stays readable.
        static let heroScrim = LinearGradient(stops: [
            .init(color: Palette.background.opacity(0), location: 0),
            .init(color: Palette.background.opacity(0.55), location: 0.55),
            .init(color: Palette.background, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        /// Left scrim for the hero text column.
        static let heroSide = LinearGradient(stops: [
            .init(color: Palette.background.opacity(0.94), location: 0),
            .init(color: Palette.background.opacity(0.6), location: 0.4),
            .init(color: Palette.background.opacity(0), location: 0.75),
        ], startPoint: .leading, endPoint: .trailing)
        static let cardScrim = LinearGradient(colors: [.clear, Color.black.opacity(0.85)],
                                              startPoint: .center, endPoint: .bottom)
        static let rankStroke = LinearGradient(colors: [Color.white.opacity(0.95), Color(hex: 0x8D94AE)],
                                               startPoint: .top, endPoint: .bottom)
        static let playerBottom = LinearGradient(colors: [.clear, Color.black.opacity(0.88)],
                                                 startPoint: .top, endPoint: .bottom)
    }

    enum Fonts {
        static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight) }
        static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static let heroTitle = Font.system(size: 76, weight: .heavy)
        static let pageTitle = Font.system(size: 52, weight: .heavy)
        static let sectionTitle = Font.system(size: 34, weight: .bold)
        static let cardTitle = Font.system(size: 24, weight: .semibold)
        static let body = Font.system(size: 26, weight: .regular)
        static let bodyLarge = Font.system(size: 30, weight: .regular)
        static let caption = Font.system(size: 22, weight: .medium)
        static let micro = Font.system(size: 18, weight: .bold)
        static let badge = Font.system(size: 18, weight: .heavy)
        static let mono = Font.system(size: 20, weight: .medium, design: .monospaced)
        static let rank = Font.system(size: 230, weight: .black, design: .rounded)
    }

    enum Metrics {
        /// tvOS safe area already insets ~80 pt horizontally; this is extra page breathing room.
        static let pageInset: CGFloat = 60
        static let posterWidth: CGFloat = 250
        static let posterAspect: CGFloat = 2.0 / 3.0
        static let landscapeWidth: CGFloat = 480
        static let channelCardWidth: CGFloat = 400
        static let top10PosterWidth: CGFloat = 220
        static let personSize: CGFloat = 170
        static let railSpacing: CGFloat = 40
        static let sectionSpacing: CGFloat = 54
        static let cardRadius: CGFloat = 16
        static let panelRadius: CGFloat = 28
        static let heroHeight: CGFloat = 820
        static let badgeHeight: CGFloat = 30
    }

    enum Motion {
        static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.9)
        static let gentle = Animation.easeInOut(duration: 0.5)
        static let heroFade = Animation.easeInOut(duration: 0.9)
        static let imageFade = Animation.easeOut(duration: 0.3)
        static let heroInterval: Double = 9
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

    /// Linear sRGB blend towards `other` (0 = self, 1 = other).
    func tunaBlend(with other: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return Color(.sRGB,
                     red: Double(r1) * (1 - t) + Double(r2) * t,
                     green: Double(g1) * (1 - t) + Double(g2) * t,
                     blue: Double(b1) * (1 - t) + Double(b2) * t,
                     opacity: Double(a1) * (1 - t) + Double(a2) * t)
    }
}

extension View {
    /// Frosted panel used for overlays and cards on the big screen.
    func tunaPanel(cornerRadius: CGFloat = Tuna.Metrics.panelRadius, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.2), in: shape)
            .overlay(shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
    }

    /// Standard page horizontal inset.
    func tunaPageInset() -> some View { padding(.horizontal, Tuna.Metrics.pageInset) }
}

/// Artwork families GenerativeArtwork can draw.
enum ArtworkKind: String, Hashable {
    case poster      // 2:3
    case backdrop    // 16:9
    case logo        // transparent title treatment
    case person      // headshot, circle
    case channel     // channel logo on a tile
    case still       // episode still 16:9
    case studio      // company logo
}

/// Soft pulsing skeleton for loading artwork (no hover, no motion-heavy effects).
struct TVShimmer: ViewModifier {
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .opacity(phase ? 0.55 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

extension View {
    func shimmering(active: Bool = true) -> some View {
        Group {
            if active { self.modifier(TVShimmer()) } else { self }
        }
    }
}
