import SwiftUI
import TunaCore

/// Per-shelf look and visibility rules for The Vault.
enum VaultLook {
    /// @AppStorage key: language picked on the Vault landing page, preselected on the Other Languages shelf.
    static let languageStorageKey = "tuna.vault.preferredLanguage"

    static func tint(_ shelf: VaultShelf) -> Color {
        switch shelf {
        case .disc: return Tuna.Palette.bluray
        case .highDefinition: return Tuna.Palette.fhd
        case .legacy: return Color(hex: 0xD8A86A)
        case .lowQuality: return Tuna.Palette.cam
        case .otherLanguages: return Tuna.Palette.accentCool
        case .unsorted: return Tuna.Palette.hdr
        case .adult: return Color(hex: 0xFF4F8B)
        }
    }

    static func isVisible(_ shelf: VaultShelf, settings: AppSettings) -> Bool {
        switch shelf {
        case .adult: return !settings.content.hideAdult
        case .lowQuality: return settings.content.showLowQuality
        case .disc, .highDefinition, .legacy, .otherLanguages, .unsorted: return true
        }
    }
}

@MainActor
enum VaultAccess {
    /// A PIN is set and the adult shelf has not been unlocked in this session.
    static func needsPIN(_ model: AppModel) -> Bool {
        model.settings.content.adultPINHash != nil && !model.adultUnlocked
    }

    /// Adult content can't be shown right now (hidden, or locked behind the PIN).
    static func isAdultBlocked(_ model: AppModel) -> Bool {
        model.settings.content.hideAdult || needsPIN(model)
    }
}

/// Big glowing symbol "logo" of a shelf on a tinted tile.
struct VaultShelfLogo: View {
    var shelf: VaultShelf
    var size: CGFloat
    var glowing: Bool

    init(shelf: VaultShelf, size: CGFloat = 64, glowing: Bool = false) {
        self.shelf = shelf
        self.size = size
        self.glowing = glowing
    }

    var body: some View {
        let tint = VaultLook.tint(shelf)
        let tile = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(glowing ? 0.6 : 0.4), tint.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * 0.85))
                .frame(width: size * 1.7, height: size * 1.7)
            tile
                .fill(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(tile.strokeBorder(tint.opacity(0.55), lineWidth: 1))
                .frame(width: size, height: size)
            Image(systemName: shelf.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color.white, tint], startPoint: .top, endPoint: .bottom))
                .shadow(color: tint.opacity(0.9), radius: glowing ? 14 : 8, x: 0, y: 0)
        }
        .frame(width: size, height: size)
    }
}

struct VaultShakeValue {
    var x: Double = 0
}

/// PIN prompt for the Adult shelf (SecureField -> model.unlockAdult(pin:)).
struct VaultPINSheet: View {
    var onUnlocked: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var failed = false
    @State private var attempts = 0

    init(onUnlocked: @escaping () -> Void) {
        self.onUnlocked = onUnlocked
    }

    var body: some View {
        VStack(spacing: 18) {
            VaultShelfLogo(shelf: .adult, size: 58, glowing: true)
                .padding(.top, 8)
            Text("Enter your PIN")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text("The Adult shelf is locked with your PIN.")
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
            KeyframeAnimator(initialValue: VaultShakeValue(), trigger: attempts) { value in
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { submit() }
                    .offset(x: value.x)
            } keyframes: { _ in
                KeyframeTrack(\VaultShakeValue.x) {
                    CubicKeyframe(10, duration: 0.06)
                    CubicKeyframe(-9, duration: 0.07)
                    CubicKeyframe(6, duration: 0.07)
                    CubicKeyframe(-3, duration: 0.07)
                    CubicKeyframe(0, duration: 0.07)
                }
            }
            if failed {
                Text("That PIN didn't match.")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.danger)
            }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 380)
        .background(Tuna.Palette.surface)
    }

    private func submit() {
        guard !pin.isEmpty else { return }
        if model.unlockAdult(pin: pin) {
            dismiss()
            onUnlocked()
        } else {
            failed = true
            pin = ""
            attempts += 1
        }
    }
}
