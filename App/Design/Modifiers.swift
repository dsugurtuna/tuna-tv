import SwiftUI

// Implementations behind `shimmering(active:)`, `staggeredAppear(index:)` and `hoverLift(scale:)`
// (declared in DesignSystem.swift). All of them honour both the system "Reduce motion" setting and
// the app's own `settings.reduceMotion`.

// MARK: - Shimmer

struct DSShimmerModifier: ViewModifier {
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask { DSShimmerMask(animated: !reduceMotion) }
        } else {
            content
        }
    }
}

/// A wide gradient whose bright band sweeps across the content (used as an alpha mask).
private struct DSShimmerMask: View {
    var animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                DSShimmerBand(phase: DSShimmerMask.phase(at: context.date))
            }
        } else {
            Color.black.opacity(0.72)
        }
    }

    static func phase(at date: Date) -> CGFloat {
        let period = 1.7
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return CGFloat(t)
    }
}

private struct DSShimmerBand: View {
    var phase: CGFloat

    private static let stops: [Gradient.Stop] = [
        .init(color: Color.black.opacity(0.58), location: 0),
        .init(color: Color.black.opacity(0.58), location: 0.38),
        .init(color: Color.black, location: 0.5),
        .init(color: Color.black.opacity(0.58), location: 0.62),
        .init(color: Color.black.opacity(0.58), location: 1),
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            LinearGradient(stops: DSShimmerBand.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 3, height: proxy.size.height)
                .offset(x: -2 * width + phase * 2 * width)
        }
    }
}

// MARK: - Staggered appear

struct DSStaggeredAppearModifier: ViewModifier {
    var index: Int

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }
    /// Only the first ~16 items of a rail/grid animate; later ones (and reduced motion) appear immediately.
    private var animates: Bool { index >= 0 && index < Tuna.Motion.staggerCap && !reduceMotion }
    private var shown: Bool { isVisible || !animates }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear(perform: appear)
    }

    private func appear() {
        guard !isVisible else { return }
        guard animates else {
            isVisible = true
            return
        }
        let delay = Double(index) * Tuna.Motion.stagger
        withAnimation(Tuna.Motion.appear.delay(delay)) { isVisible = true }
    }
}

// MARK: - Hover lift

struct DSHoverLiftModifier: ViewModifier {
    var scale: CGFloat

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }
    private var effectiveScale: CGFloat { (isHovering && !reduceMotion) ? scale : 1 }

    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? 0.03 : 0)
            .scaleEffect(effectiveScale)
            .shadow(color: Color.black.opacity(isHovering ? 0.5 : 0), radius: isHovering ? 20 : 0, x: 0, y: isHovering ? 12 : 0)
            .zIndex(isHovering ? 10 : 0)
            .onHover { inside in
                withAnimation(Tuna.Motion.hover) { isHovering = inside }
            }
    }
}
