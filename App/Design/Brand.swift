import SwiftUI

/// The Tuna TV brand mark: a deep-ocean squircle holding a stylized tuna (a rounded "play" triangle body with a
/// forked tail and a small eye), with a soft coral glow.
struct TunaLogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        let radius = size * 0.29
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Tuna.Gradients.ocean)
            shape.fill(RadialGradient(colors: [Tuna.Palette.accentCool.opacity(0.24), Color.clear],
                                      center: UnitPoint(x: 0.28, y: 0.12),
                                      startRadius: 0,
                                      endRadius: size * 0.85))
            DSTunaFish()
                .frame(width: size * 0.8, height: size * 0.8)
                .shadow(color: Tuna.Palette.accent.opacity(0.55), radius: size * 0.09)
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.03)],
                                              startPoint: .top,
                                              endPoint: .bottom),
                               lineWidth: max(0.5, size * 0.03))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// TunaLogoMark + "tuna" in heavy rounded type + "tv" in coral.
struct TunaWordmark: View {
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.38) {
            TunaLogoMark(size: size * 1.45)
            HStack(spacing: 0) {
                Text(verbatim: "tuna")
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text(verbatim: "tv")
                    .foregroundStyle(Tuna.Gradients.accent)
            }
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-size * 0.025)
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Tuna TV"))
    }
}

// MARK: - Fish drawing

private struct DSTunaFish: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                DSTunaTailShape()
                    .fill(LinearGradient(colors: [Color(hex: 0xFF9A4C), Color(hex: 0xE8454F)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                DSTunaBodyShape()
                    .fill(LinearGradient(colors: [Tuna.Palette.accent, Tuna.Palette.accentWarm],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                DSTunaBodyShape()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0)],
                                         startPoint: .top,
                                         endPoint: .center))
                Circle()
                    .fill(Color.white)
                    .frame(width: side * 0.105, height: side * 0.105)
                    .position(x: side * 0.62, y: side * 0.45)
                Circle()
                    .fill(Tuna.Palette.oceanTop)
                    .frame(width: side * 0.046, height: side * 0.046)
                    .position(x: side * 0.633, y: side * 0.45)
            }
            .frame(width: side, height: side)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Rounded play-triangle pointing right.
private struct DSTunaBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.20)
        let b = CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.50)
        let c = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.80)
        let radius = rect.width * 0.11
        var path = Path()
        path.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        path.addArc(tangent1End: a, tangent2End: b, radius: radius)
        path.addArc(tangent1End: b, tangent2End: c, radius: radius * 0.8)
        path.addArc(tangent1End: c, tangent2End: a, radius: radius)
        path.closeSubpath()
        return path
    }
}

/// Forked tail on the left of the body.
private struct DSTunaTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.37, 0.41))
        path.addLine(to: point(0.09, 0.20))
        path.addQuadCurve(to: point(0.19, 0.50), control: point(0.17, 0.35))
        path.addQuadCurve(to: point(0.09, 0.80), control: point(0.17, 0.65))
        path.addLine(to: point(0.37, 0.59))
        path.closeSubpath()
        return path
    }
}
