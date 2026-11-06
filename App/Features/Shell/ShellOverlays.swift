import SwiftUI
import TunaCore

// MARK: - Toasts

/// Bottom toast for `model.toast`; dismisses itself after 3.2 s (or on click).
struct ToastHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let toast = model.toast {
                ToastView(message: toast)
                    .id(toast.id)
                    .onTapGesture { dismiss(toast.id) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 34)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Tuna.Motion.snappy, value: model.toast?.id)
        .task(id: model.toast?.id) {
            guard let id = model.toast?.id else { return }
            do {
                try await Task.sleep(nanoseconds: 3_200_000_000)
            } catch {
                return
            }
            dismiss(id)
        }
    }

    private func dismiss(_ id: UUID) {
        guard model.toast?.id == id else { return }
        withAnimation(Tuna.Motion.snappy) { model.toast = nil }
    }
}

// MARK: - Boot splash

/// Shown while cached catalogs load and curate on launch (no provider requests happen here).
struct ShellBootSplash: View {
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Tuna.Palette.background
            RadialGradient(colors: [Tuna.Palette.accent.opacity(0.2), Tuna.Palette.accentCool.opacity(0.06), Color.clear],
                           center: .center, startRadius: 10, endRadius: 460)
            VStack(spacing: 26) {
                logo
                VStack(spacing: 8) {
                    Text("Curating your library…")
                        .font(Tuna.Fonts.rounded(19, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text("Reading your saved catalog. Your provider isn't contacted.")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                }
            }
        }
        .overlay(alignment: .top) {
            ShellWindowDragArea()
                .frame(height: 44)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var logo: some View {
        if reduceMotion {
            TunaLogoMark(size: 92)
                .shadow(color: Tuna.Palette.accent.opacity(0.35), radius: 22)
        } else {
            PhaseAnimator([false, true]) { pulsing in
                TunaLogoMark(size: 92)
                    .scaleEffect(pulsing ? 1.06 : 0.95)
                    .shadow(color: Tuna.Palette.accent.opacity(pulsing ? 0.6 : 0.16), radius: pulsing ? 38 : 12)
            } animation: { _ in
                .easeInOut(duration: 1.15)
            }
        }
    }
}

// MARK: - Search

/// Dimmed backdrop that closes an overlay when clicked.
struct ShellScrim: View {
    var opacity: Double = 0.5
    let onTap: () -> Void

    var body: some View {
        Color.black
            .opacity(opacity)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .ignoresSafeArea()
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
    }
}

/// Places the search palette under the top bar; empty space stays click-through so the scrim can close it.
struct ShellSearchHost: View {
    var body: some View {
        VStack(spacing: 0) {
            SearchPalette()
            Spacer(minLength: 0)
        }
        .padding(.top, Tuna.Metrics.topBarHeight + 18)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
