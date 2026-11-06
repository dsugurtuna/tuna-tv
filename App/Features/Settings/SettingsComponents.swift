import SwiftUI
import TunaCore

/// Bindings into `AppSettings` that write through `model.updateSettings`.
@MainActor
enum SettingsBinding {
    static func make<T>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.updateSettings { settings in settings[keyPath: keyPath] = newValue }
            })
    }
}

enum SettingsOptions {
    /// `base`, plus the current value when it is not one of them (so pickers never show a blank).
    static func including<T: Comparable & Hashable>(_ current: T, in base: [T]) -> [T] {
        base.contains(current) ? base : (base + [current]).sorted()
    }
}

/// Footnote text under a settings section.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Coloured state capsule ("Healthy", "Paused until 14:32").
struct SettingsStatusPill: View {
    let state: ShellShieldState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .bold))
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(state.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.3), lineWidth: 1))
    }
}

/// Label + value pair used in compact rows.
struct SettingsMiniFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// Status line for a saved/unsaved key.
struct SettingsKeyStatus: View {
    let isSet: Bool
    let setText: String
    let unsetText: String

    var body: some View {
        Label(isSet ? setText : unsetText,
              systemImage: isSet ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isSet ? Tuna.Palette.success : Color.secondary)
    }
}

/// Centered placeholder for empty panes.
struct SettingsPlaceholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
