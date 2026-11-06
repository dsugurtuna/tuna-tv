import SwiftUI

// MARK: - EmptyStateView

/// Empty / error state with a symbol, message and optional action.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var appeared = false

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        VStack(spacing: 18) {
            DSEmptyStateEmblem(symbol: symbol)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.86)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text(message)
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            if let actionTitle, let action {
                GlassButton(title: actionTitle, style: .primary, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
        .onAppear {
            withAnimation(Tuna.Motion.appear) { appeared = true }
        }
    }
}

private struct DSEmptyStateEmblem: View {
    var symbol: String

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Tuna.Palette.accent.opacity(0.22), Color.clear],
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: 70))
                .frame(width: 140, height: 140)
            Circle()
                .fill(Tuna.Palette.surfaceElevated)
                .frame(width: 84, height: 84)
                .overlay {
                    Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                                         startPoint: .top,
                                                         endPoint: .bottom),
                                          lineWidth: 1)
                }
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tuna.Gradients.accent)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - AmbientBackground

/// Slowly animated ambient background (MeshGradient) tinted by the focused artwork.
/// Dark and low-saturation so content stays legible; static when motion is reduced, paused when the window
/// is inactive (no needless redraws).
struct AmbientBackground: View {
    var tint: Color = Tuna.Palette.accentCool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(AppModel.self) private var model: AppModel?

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        let colors = DSAmbientField.colors(tint: tint)
        ZStack {
            Tuna.Palette.background
            if reduceMotion {
                MeshGradient(width: 3, height: 3, points: DSAmbientField.points(time: 0), colors: colors)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: controlActiveState == .inactive)) { context in
                    MeshGradient(width: 3,
                                 height: 3,
                                 points: DSAmbientField.points(time: context.date.timeIntervalSinceReferenceDate),
                                 colors: colors)
                }
            }
            LinearGradient(colors: [Color.black.opacity(0), Tuna.Palette.background.opacity(0.7)],
                           startPoint: .center,
                           endPoint: .bottom)
        }
        .animation(Tuna.Motion.heroFade, value: tint)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum DSAmbientField {
    /// 3×3 mesh: fixed corners, edge midpoints sliding along their edge, centre drifting (periods of ~20–30 s).
    static func points(time: TimeInterval) -> [SIMD2<Float>] {
        let t = time
        func wave(_ period: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(sin(t / period * 2 * Double.pi + phase) * amount)
        }
        return [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.5 + wave(23, 0.0, 0.14), 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0.5 + wave(29, 1.3, 0.13)),
            SIMD2<Float>(0.5 + wave(31, 2.1, 0.16), 0.5 + wave(19, 0.7, 0.13)),
            SIMD2<Float>(1, 0.5 + wave(27, 2.9, 0.13)),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(0.5 + wave(25, 4.2, 0.14), 1),
            SIMD2<Float>(1, 1),
        ]
    }

    /// Dark, desaturated colours tinted by `tint` (strongest top-left, fading towards the bottom).
    static func colors(tint: Color) -> [Color] {
        let muted = tint.tunaBlend(with: Color(white: 0.5), amount: 0.35)
        let cool = Tuna.Palette.accentCool.tunaBlend(with: Color(white: 0.5), amount: 0.5)
        let base = Tuna.Palette.background
        func shade(_ color: Color, _ amount: Double) -> Color { base.tunaBlend(with: color, amount: amount) }
        return [
            shade(muted, 0.32), shade(muted, 0.14), shade(cool, 0.16),
            shade(muted, 0.12), shade(muted, 0.2), shade(cool, 0.07),
            shade(muted, 0.03), shade(muted, 0.08), shade(cool, 0.02),
        ]
    }
}

// MARK: - ToastView

/// Toast overlay content: glass capsule with a style icon and colour.
struct ToastView: View {
    var message: ToastMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(message.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 520)
        .tunaGlass(cornerRadius: 22, tint: color)
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch message.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch message.style {
        case .info: return Tuna.Palette.accentCool
        case .success: return Tuna.Palette.success
        case .warning: return Tuna.Palette.warning
        case .error: return Tuna.Palette.danger
        }
    }
}
