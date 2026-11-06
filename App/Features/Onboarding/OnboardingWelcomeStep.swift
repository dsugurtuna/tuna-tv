import SwiftUI
import TunaCore

/// Step 1: big logo entrance, headline and the two ways in (own provider or the demo).
struct OnboardingWelcomeStep: View {
    @Environment(AppModel.self) private var model

    let reduceMotion: Bool
    let isStartingDemo: Bool
    let onAddProvider: () -> Void
    let onTryDemo: () -> Void

    @State private var entered = false
    @State private var logoTrigger = 0
    @State private var showsCopy = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            OnboardingLogoEntrance(reduceMotion: reduceMotion, trigger: logoTrigger)
                .opacity(entered ? 1 : 0)
                .padding(.bottom, 30)

            VStack(spacing: 14) {
                Text("Your IPTV, curated.")
                    .font(Tuna.Fonts.display(58))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text("Free forever. No ads. No accounts.")
                    .font(Tuna.Fonts.rounded(20, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            .opacity(showsCopy ? 1 : 0)
            .offset(y: showsCopy ? 0 : 18)

            HStack(spacing: 14) {
                GlassButton(title: "Add my provider", systemImage: "antenna.radiowaves.left.and.right",
                            style: .primary, action: { onAddProvider() })
                    .keyboardShortcut(.defaultAction)
                GlassButton(title: isStartingDemo ? "Opening the demo…" : "Try the demo", systemImage: "sparkles.tv",
                            style: .secondary, action: { onTryDemo() })
                    .disabled(isStartingDemo)
            }
            .padding(.top, 34)
            .opacity(showsCopy ? 1 : 0)
            .offset(y: showsCopy ? 0 : 26)

            VStack(spacing: 6) {
                Label("Gentle on your provider: one request at a time, one stream at a time.",
                      systemImage: "checkmark.shield.fill")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                Text("Tuna TV provides no content. Bring your own subscription.")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            .padding(.top, 26)
            .opacity(showsCopy ? 1 : 0)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !model.isBooting { playEntrance() }
        }
        .onChange(of: model.isBooting) { _, booting in
            if !booting { playEntrance() }
        }
    }

    /// Plays once, after the boot splash is gone (so the entrance is never wasted behind it).
    private func playEntrance() {
        guard !entered else { return }
        entered = true
        logoTrigger += 1
        let copyAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.25)
            : .spring(response: 0.75, dampingFraction: 0.86).delay(0.55)
        withAnimation(copyAnimation) { showsCopy = true }
    }
}

/// Animated values of the logo entrance.
struct OnboardingLogoMotion {
    var scale: Double = 1
    var rotation: Double = 0
    var glow: Double = 0.55
    var opacity: Double = 1
    var lift: Double = 0
}

/// The TunaLogoMark entrance: pops in with a spin and a bloom of coral glow, then settles.
/// Every track starts with a MoveKeyframe from the hidden state and ends at the resting state.
struct OnboardingLogoEntrance: View {
    let reduceMotion: Bool
    let trigger: Int

    var body: some View {
        if reduceMotion {
            logo(OnboardingLogoMotion())
        } else {
            KeyframeAnimator(initialValue: OnboardingLogoMotion(), trigger: trigger) { value in
                logo(value)
            } keyframes: { _ in
                KeyframeTrack(\OnboardingLogoMotion.scale) {
                    MoveKeyframe(0.25)
                    SpringKeyframe(1.14, duration: 0.6, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.5, spring: .smooth)
                }
                KeyframeTrack(\OnboardingLogoMotion.rotation) {
                    MoveKeyframe(-38)
                    SpringKeyframe(8, duration: 0.55, spring: .bouncy)
                    SpringKeyframe(0, duration: 0.6, spring: .smooth)
                }
                KeyframeTrack(\OnboardingLogoMotion.glow) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.55)
                    CubicKeyframe(0.55, duration: 0.9)
                }
                KeyframeTrack(\OnboardingLogoMotion.opacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.3)
                }
                KeyframeTrack(\OnboardingLogoMotion.lift) {
                    MoveKeyframe(26)
                    SpringKeyframe(0, duration: 0.7, spring: .bouncy)
                }
            }
        }
    }

    private func logo(_ value: OnboardingLogoMotion) -> some View {
        TunaLogoMark(size: 128)
            .scaleEffect(value.scale)
            .rotationEffect(.degrees(value.rotation))
            .offset(y: value.lift)
            .opacity(value.opacity)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Tuna.Palette.accent.opacity(0.55 * value.glow),
                                                  Tuna.Palette.accentWarm.opacity(0.22 * value.glow),
                                                  Color.clear],
                                         center: .center, startRadius: 0, endRadius: 160))
                    .frame(width: 320, height: 320)
                    .allowsHitTesting(false)
            }
            .frame(width: 180, height: 180)
    }
}
