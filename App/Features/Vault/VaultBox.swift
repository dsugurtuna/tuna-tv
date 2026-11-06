import SwiftUI
import TunaCore

/// Vault landing hero: the signature box-opening illustration + title, subtitle and counts.
struct VaultHero: View {
    let total: Int
    let shelves: Int
    let languages: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius + 6, style: .continuous)
        HStack(alignment: .center, spacing: 36) {
            VaultBoxIllustration()
                .frame(width: 320, height: 280)
            VStack(alignment: .leading, spacing: 14) {
                Text("ONE BOX. EVERYTHING ELSE.")
                    .font(Tuna.Fonts.micro)
                    .tracking(2.2)
                    .foregroundStyle(Tuna.Palette.gold)
                Text("The Vault")
                    .font(Tuna.Fonts.heroTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("Everything that didn't make your showcase — still one click away.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 30) {
                    stat(total, "items")
                    stat(shelves, shelves == 1 ? "shelf" : "shelves")
                    if languages > 0 { stat(languages, languages == 1 ? "language" : "languages") }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .background {
            ZStack {
                shape.fill(Tuna.Palette.surface.opacity(0.55))
                RadialGradient(colors: [Tuna.Palette.gold.opacity(0.18), Color.clear], center: .init(x: 0.18, y: 0.45),
                               startRadius: 10, endRadius: 360)
                RadialGradient(colors: [Tuna.Palette.accentCool.opacity(0.10), Color.clear], center: .init(x: 0.85, y: 0.1),
                               startRadius: 10, endRadius: 420)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
        .tunaPageInset()
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TDCountUpText(value: Double(value), font: Tuna.Fonts.rounded(30, weight: .heavy))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(label.uppercased())
                .font(Tuna.Fonts.micro)
                .tracking(1.2)
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
    }
}

/// A 3D-ish box drawn with shapes: the lid swings open (rotation3DEffect), light beams rise and shelf badges float
/// out of it (KeyframeAnimator / PhaseAnimator). Fully static (already open) with reduce motion. Click to replay.
struct VaultBoxIllustration: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isOpen = false

    private var animated: Bool { !(systemReduceMotion || model.settings.reduceMotion) }

    private static let badges: [(symbol: String, tint: Color, x: CGFloat, y: CGFloat)] = [
        (symbol: "opticaldisc.fill", tint: Tuna.Palette.bluray, x: 62, y: 78),
        (symbol: "sparkles.tv.fill", tint: Tuna.Palette.fhd, x: 122, y: 30),
        (symbol: "film.stack.fill", tint: Color(hex: 0xD8A86A), x: 200, y: 34),
        (symbol: "globe.europe.africa.fill", tint: Tuna.Palette.accentCool, x: 258, y: 80),
    ]

    var body: some View {
        ZStack {
            glow.zIndex(0)
            inside.zIndex(1)
            beams.zIndex(2)
            ForEach(Array(VaultBoxIllustration.badges.enumerated()), id: \.offset) { item in
                badge(index: item.offset, symbol: item.element.symbol, tint: item.element.tint,
                      x: item.element.x, y: item.element.y)
            }
            .zIndex(3)
            front.zIndex(4)
            lid.zIndex(isOpen ? 1.5 : 6)
        }
        .frame(width: 320, height: 280)
        .contentShape(Rectangle())
        .onTapGesture { replay() }
        .help("Open the box again")
        .accessibilityLabel(Text("The Vault box"))
        .task {
            if !animated {
                isOpen = true
                return
            }
            try? await Task.sleep(for: .milliseconds(380))
            withAnimation(.spring(response: 0.95, dampingFraction: 0.66)) { isOpen = true }
        }
    }

    private func replay() {
        guard animated else { return }
        withAnimation(.easeIn(duration: 0.25)) { isOpen = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.spring(response: 0.95, dampingFraction: 0.66)) { isOpen = true }
        }
    }

    // MARK: Layers (canvas 320 × 280; box front x 70…250, y 150…258; opening y 122…150)

    private var glow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Tuna.Palette.gold.opacity(0.55), Tuna.Palette.accentWarm.opacity(0.15), Color.clear],
                                 center: .center, startRadius: 4, endRadius: 150))
            .frame(width: 300, height: 220)
            .position(x: 160, y: 110)
            .opacity(isOpen ? 1 : 0.15)
            .blur(radius: 18)
    }

    private var inside: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 95, y: 122))
                path.addLine(to: CGPoint(x: 225, y: 122))
                path.addLine(to: CGPoint(x: 250, y: 150))
                path.addLine(to: CGPoint(x: 70, y: 150))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color(hex: 0x05070C), Color(hex: 0x1A1408)], startPoint: .top, endPoint: .bottom))
            Ellipse()
                .fill(Tuna.Palette.gold)
                .frame(width: 140, height: 18)
                .blur(radius: 10)
                .position(x: 160, y: 140)
                .opacity(isOpen ? 0.85 : 0)
        }
        .frame(width: 320, height: 280)
    }

    @ViewBuilder
    private var beams: some View {
        if animated {
            PhaseAnimator([false, true]) { bright in
                beamStack(bright: bright)
            } animation: { bright in
                Animation.easeInOut(duration: bright ? 1.5 : 1.9)
            }
        } else {
            beamStack(bright: true)
        }
    }

    private func beamStack(bright: Bool) -> some View {
        let specs: [(x: CGFloat, width: CGFloat, height: CGFloat)] = [
            (x: 108, width: 12, height: 120), (x: 134, width: 22, height: 170), (x: 160, width: 30, height: 210),
            (x: 186, width: 22, height: 165), (x: 212, width: 12, height: 125),
        ]
        return ZStack {
            ForEach(Array(specs.enumerated()), id: \.offset) { item in
                Capsule()
                    .fill(LinearGradient(colors: [Tuna.Palette.gold.opacity(0), Tuna.Palette.gold.opacity(0.55), Color.white.opacity(0.85)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: item.element.width, height: item.element.height)
                    .blur(radius: 5)
                    .scaleEffect(x: 1, y: isOpen ? (bright ? 1.05 : 0.93) : 0.05, anchor: .bottom)
                    .position(x: item.element.x, y: 142 - item.element.height / 2)
                    .opacity(isOpen ? (bright ? 0.95 : 0.6) : 0)
            }
        }
        .frame(width: 320, height: 280)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func badge(index: Int, symbol: String, tint: Color, x: CGFloat, y: CGFloat) -> some View {
        VaultFloatingBadge(symbol: symbol, tint: tint, index: index, floating: animated && isOpen)
            .scaleEffect(isOpen ? 1 : 0.2)
            .opacity(isOpen ? 1 : 0)
            .position(x: isOpen ? x : 160, y: isOpen ? y : 160)
            .animation(animated ? Animation.spring(response: 0.7, dampingFraction: 0.62).delay(0.18 + Double(index) * 0.08) : nil,
                       value: isOpen)
    }

    private var front: some View {
        let face = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            face
                .fill(LinearGradient(colors: [Color(hex: 0x2A3350), Color(hex: 0x121828)], startPoint: .top, endPoint: .bottom))
                .overlay(face.strokeBorder(Tuna.Gradients.gold, lineWidth: 1.5).opacity(0.7))
            Rectangle()
                .fill(Tuna.Gradients.gold)
                .frame(height: 3)
                .opacity(0.55)
                .offset(y: -30)
            Circle()
                .fill(Tuna.Palette.surfaceRaised)
                .overlay(Circle().strokeBorder(Tuna.Gradients.gold, lineWidth: 1.5))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tuna.Gradients.gold)
                        .contentTransition(.symbolEffect(.replace))
                }
                .offset(y: 10)
        }
        .frame(width: 180, height: 108)
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 12)
        .position(x: 160, y: 204)
    }

    private var lid: some View {
        ZStack(alignment: .bottom) {
            Path { path in
                path.move(to: CGPoint(x: 12, y: 0))
                path.addLine(to: CGPoint(x: 182, y: 0))
                path.addLine(to: CGPoint(x: 194, y: 30))
                path.addLine(to: CGPoint(x: 0, y: 30))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color(hex: 0x3A4569), Color(hex: 0x232B45)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Tuna.Gradients.gold)
                .frame(width: 194, height: 10)
        }
        .frame(width: 194, height: 40)
        .rotation3DEffect(.degrees(isOpen ? -112 : 0), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
        .position(x: 160, y: 118 + 20)
    }
}

struct VaultFloat {
    var lift: Double = 0
    var tilt: Double = 0
}

/// Round glass badge with a shelf symbol; bobs gently while `floating`.
struct VaultFloatingBadge: View {
    let symbol: String
    let tint: Color
    let index: Int
    let floating: Bool

    var body: some View {
        if floating {
            KeyframeAnimator(initialValue: VaultFloat(), repeating: true) { value in
                face
                    .offset(y: value.lift)
                    .rotationEffect(.degrees(value.tilt))
            } keyframes: { _ in
                KeyframeTrack(\VaultFloat.lift) {
                    CubicKeyframe(-8, duration: 1.4 + Double(index) * 0.22)
                    CubicKeyframe(0, duration: 1.4 + Double(index) * 0.22)
                }
                KeyframeTrack(\VaultFloat.tilt) {
                    CubicKeyframe(5, duration: 1.1 + Double(index) * 0.15)
                    CubicKeyframe(-5, duration: 2.2 + Double(index) * 0.3)
                    CubicKeyframe(0, duration: 1.1 + Double(index) * 0.15)
                }
            }
        } else {
            face
        }
    }

    private var face: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color.white, tint], startPoint: .top, endPoint: .bottom))
            .frame(width: 48, height: 48)
            .background(Circle().fill(.ultraThinMaterial))
            .background(Circle().fill(tint.opacity(0.25)))
            .overlay(Circle().strokeBorder(tint.opacity(0.7), lineWidth: 1))
            .shadow(color: tint.opacity(0.7), radius: 12, x: 0, y: 0)
    }
}
