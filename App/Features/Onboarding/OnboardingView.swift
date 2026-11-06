import SwiftUI
import TunaCore

/// Onboarding steps, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case provider
    case worlds
    case quality
    case metadata
    case theater

    var id: Int { rawValue }

    var accessibilityName: String {
        switch self {
        case .welcome: return "Welcome"
        case .provider: return "Add your provider"
        case .worlds: return "Choose your worlds"
        case .quality: return "Showcase quality"
        case .metadata: return "Metadata"
        case .theater: return "Curation"
        }
    }

    /// Ambient colour of the step's backdrop.
    var tint: Color {
        switch self {
        case .welcome: return Tuna.Palette.accent
        case .provider: return Tuna.Palette.accentCool
        case .worlds: return Tuna.Palette.fhd
        case .quality: return Tuna.Palette.gold
        case .metadata: return Tuna.Palette.tmdb
        case .theater: return Tuna.Palette.accentWarm
        }
    }

    /// "Step 2 of 5".
    var eyebrow: String {
        "Step \(rawValue) of \(OnboardingStep.allCases.count - 1)"
    }
}

/// Full-window first-run flow: welcome → provider → worlds → quality → metadata → curation theater.
/// Shown by RootView while `model.needsOnboarding` (and kept up until the user presses "Start watching").
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    @State private var draft = ProviderSetupDraft()
    @State private var validation: ProviderValidation = .idle
    @State private var isStartingDemo = false

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    var body: some View {
        ZStack {
            OnboardingBackdrop(tint: step.tint, phase: step.rawValue, reduceMotion: reduceMotion)

            VStack(spacing: 0) {
                OnboardingTopStrip(showsWordmark: step != .welcome)

                ZStack {
                    currentStep
                        .id(step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                OnboardingProgressDots(current: step,
                                       isSelectable: { target in canJump(to: target) },
                                       onSelect: { target in go(to: target) })
                    .padding(.top, 6)
                    .padding(.bottom, 20)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(reduceMotion: reduceMotion,
                                  isStartingDemo: isStartingDemo,
                                  onAddProvider: { go(to: .provider) },
                                  onTryDemo: { startDemo() })
        case .provider:
            OnboardingProviderStep(draft: $draft,
                                   validation: $validation,
                                   onBack: { go(to: .welcome) },
                                   onContinue: { go(to: .worlds) })
        case .worlds:
            OnboardingWorldsStep(onBack: { go(to: .provider) }, onContinue: { go(to: .quality) })
        case .quality:
            OnboardingQualityStep(onBack: { go(to: .worlds) }, onContinue: { go(to: .metadata) })
        case .metadata:
            OnboardingMetadataStep(onBack: { go(to: .quality) }, onContinue: { go(to: .theater) })
        case .theater:
            OnboardingTheaterStep(draft: draft,
                                  reduceMotion: reduceMotion,
                                  onEditProvider: { go(to: .provider) })
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.offset(x: forward ? 90 : -90).combined(with: .opacity),
            removal: AnyTransition.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func canJump(to target: OnboardingStep) -> Bool {
        step != .theater && target.rawValue < step.rawValue
    }

    private func go(to target: OnboardingStep) {
        guard target != step else { return }
        forward = target.rawValue > step.rawValue
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Tuna.Motion.page) {
            step = target
        }
    }

    private func startDemo() {
        guard !isStartingDemo else { return }
        isStartingDemo = true
        Task { @MainActor in
            await model.startDemo()
            isStartingDemo = false
        }
    }
}

// MARK: - Chrome

/// Slow, drifting glow behind the steps, tinted per step.
struct OnboardingBackdrop: View {
    let tint: Color
    let phase: Int
    let reduceMotion: Bool

    var body: some View {
        AmbientBackground(tint: tint)
            .overlay {
                GeometryReader { proxy in
                    let side = max(proxy.size.width, proxy.size.height) * 1.05
                    RadialGradient(colors: [tint.opacity(0.3), tint.opacity(0.08), Color.clear],
                                   center: .center, startRadius: 0, endRadius: side / 2)
                        .frame(width: side, height: side)
                        .position(x: proxy.size.width * glowX, y: proxy.size.height * glowY)
                }
                .allowsHitTesting(false)
            }
            .overlay {
                LinearGradient(colors: [Color.clear, Tuna.Palette.background.opacity(0.8)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.4), value: phase)
            .ignoresSafeArea()
    }

    private var glowX: CGFloat {
        let positions: [CGFloat] = [0.5, 0.28, 0.72, 0.36, 0.64, 0.5]
        return positions[abs(phase) % positions.count]
    }

    private var glowY: CGFloat {
        let positions: [CGFloat] = [0.36, 0.3, 0.34, 0.58, 0.36, 0.44]
        return positions[abs(phase) % positions.count]
    }
}

/// Draggable strip under the traffic lights, with the wordmark after the first step.
struct OnboardingTopStrip: View {
    let showsWordmark: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            ShellWindowDragArea()
            if showsWordmark {
                TunaWordmark(size: 17)
                    .padding(.leading, 90)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .animation(Tuna.Motion.gentle, value: showsWordmark)
    }
}

struct OnboardingProgressDots: View {
    let current: OnboardingStep
    let isSelectable: (OnboardingStep) -> Bool
    let onSelect: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OnboardingStep.allCases) { step in
                Button {
                    if isSelectable(step) { onSelect(step) }
                } label: {
                    Capsule()
                        .fill(fill(for: step))
                        .frame(width: step == current ? 28 : 8, height: 8)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.accessibilityName)
                .accessibilityLabel(step.accessibilityName)
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
        .animation(Tuna.Motion.snappy, value: current)
    }

    private func fill(for step: OnboardingStep) -> AnyShapeStyle {
        if step == current { return AnyShapeStyle(Tuna.Gradients.accent) }
        if step.rawValue < current.rawValue { return AnyShapeStyle(Color.white.opacity(0.55)) }
        return AnyShapeStyle(Color.white.opacity(0.16))
    }
}

/// Header + scrolling content + pinned action row, shared by the form-like steps.
struct OnboardingStepScaffold<Content: View, Actions: View>: View {
    let step: OnboardingStep
    let title: String
    let subtitle: String
    var maxWidth: CGFloat = 760
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    OnboardingHeader(eyebrow: step.eyebrow, title: title, subtitle: subtitle)
                    content()
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 12) {
                actions()
            }
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, 44)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
            }
        }
    }
}

struct OnboardingHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Tuna.Palette.accent)
            Text(title)
                .font(Tuna.Fonts.display(40))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(Tuna.Fonts.bodyLarge)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingBackButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text("Back")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(hovering ? Tuna.Palette.textPrimary : Tuna.Palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
    }
}
