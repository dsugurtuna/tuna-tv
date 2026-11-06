import SwiftUI
import TunaCore

enum SettingsTab: String, Hashable, CaseIterable {
    case providers, content, playback, metadata, data, about
}

/// The macOS Settings window (~880×620). Expects `.environment(appModel)` on the Settings scene; renders a
/// harmless placeholder instead of crashing if it is missing.
struct SettingsView: View {
    @Environment(AppModel.self) private var model: AppModel?
    @State private var selection: SettingsTab = .providers

    var body: some View {
        Group {
            if let model {
                tabs.environment(model)
            } else {
                Text("Settings are unavailable.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 620)
        .preferredColorScheme(.dark)
        .tint(Tuna.Palette.accent)
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            SwiftUI.Tab("Providers", systemImage: "antenna.radiowaves.left.and.right", value: SettingsTab.providers) {
                SettingsProvidersTab()
            }
            SwiftUI.Tab("Content", systemImage: "globe.europe.africa.fill", value: SettingsTab.content) {
                SettingsContentTab()
            }
            SwiftUI.Tab("Playback", systemImage: "play.rectangle.fill", value: SettingsTab.playback) {
                SettingsPlaybackTab()
            }
            SwiftUI.Tab("Metadata", systemImage: "sparkles.rectangle.stack.fill", value: SettingsTab.metadata) {
                SettingsMetadataTab()
            }
            SwiftUI.Tab("Data", systemImage: "internaldrive.fill", value: SettingsTab.data) {
                SettingsDataTab()
            }
            SwiftUI.Tab("About", systemImage: "info.circle.fill", value: SettingsTab.about) {
                SettingsAboutTab()
            }
        }
    }
}
