import SwiftUI
import TunaCore

struct SettingsPlaybackTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let playback = model.settings.playback
        Form {
            Section {
                LabeledContent("Channel switch delay") {
                    HStack(spacing: 10) {
                        Slider(value: setting(\.playback.zapDebounce), in: 0.4...1.5, step: 0.1)
                            .frame(width: 220)
                        Text(String(format: "%.1f s", playback.zapDebounce))
                            .font(Tuna.Fonts.mono)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Live pause buffer", selection: setting(\.playback.liveTimeshiftMinutes)) {
                    ForEach(SettingsOptions.including(playback.liveTimeshiftMinutes, in: [0, 10, 15, 30, 60, 90, 120]), id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                    }
                }
            } header: {
                Text("Live TV")
            } footer: {
                SettingsNote(text: "Tuna TV waits until you settle on a channel before opening it, so flicking through never floods your provider. Longer is gentler.")
            }

            Section {
                Toggle("Autoplay next episode", isOn: setting(\.playback.autoplayNextEpisode))
                Stepper(value: setting(\.playback.upNextCountdown), in: 3...60) {
                    LabeledContent("Up next countdown", value: "\(playback.upNextCountdown) s")
                }
                .disabled(!playback.autoplayNextEpisode)
                Picker("Offer to resume after", selection: setting(\.playback.resumeThresholdSeconds)) {
                    ForEach(SettingsOptions.including(playback.resumeThresholdSeconds, in: [0, 30, 60, 120, 300]), id: \.self) { seconds in
                        Text(resumeLabel(seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Movies & series")
            }

            Section {
                Toggle("Play muted trailers in the Home hero", isOn: setting(\.playback.heroTrailers))
            } header: {
                Text("Home")
            } footer: {
                SettingsNote(text: "Trailers come from YouTube, never from your IPTV provider.")
            }

            Section {
                Toggle("Reduce motion", isOn: setting(\.reduceMotion))
            } header: {
                Text("Interface")
            } footer: {
                SettingsNote(text: "Calmer transitions everywhere. Tuna TV also follows the macOS Reduce Motion setting.")
            }
        }
        .formStyle(.grouped)
    }

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        SettingsBinding.make(model, keyPath)
    }

    private func resumeLabel(_ seconds: Double) -> String {
        if seconds <= 0 { return "Always" }
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
