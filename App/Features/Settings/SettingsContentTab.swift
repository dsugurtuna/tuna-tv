import SwiftUI
import TunaCore

/// Worlds, showcase quality, auto-relax, adult content + PIN, low-quality copies, preferred languages.
struct SettingsContentTab: View {
    @Environment(AppModel.self) private var model
    @State private var pinPurpose: SettingsPINPurpose?

    var body: some View {
        Form {
            Section {
                WorldPickerPanel(style: .settings)
                    .padding(.vertical, 4)
            } header: {
                Text("Your worlds · \(WorldEditing.summary(for: model.settings.content.worlds))")
            } footer: {
                SettingsNote(text: "The showcase (Home, Movies, Series, Live) is built from these languages and countries. Everything else stays one click away in The Vault → Other Languages.")
            }

            Section {
                Picker("Showcase quality", selection: setting(\.content.showcaseQuality)) {
                    ForEach(ShowcaseQuality.allCases, id: \.self) { quality in
                        Text(ShowcaseCopy.title(quality)).tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Fill thin shelves automatically", isOn: setting(\.content.autoRelaxShowcase))
                if model.settings.content.autoRelaxShowcase {
                    Stepper(value: setting(\.content.relaxThreshold), in: 10...500, step: 10) {
                        LabeledContent("Let the next tier in below", value: "\(model.settings.content.relaxThreshold) titles")
                    }
                }
            } header: {
                Text("Showcase quality")
            } footer: {
                SettingsNote(text: ShowcaseCopy.detail(model.settings.content.showcaseQuality) + " Everything else goes to The Vault.")
            }

            Section {
                Toggle("Hide adult content", isOn: hideAdultBinding)
                LabeledContent("PIN") {
                    if model.settings.content.adultPINHash != nil {
                        HStack {
                            Text("Set").foregroundStyle(.secondary)
                            Button("Change…") { pinPurpose = .change }
                            Button("Remove…") { pinPurpose = .remove }
                        }
                    } else {
                        Button("Set PIN…") { pinPurpose = .set }
                    }
                }
            } header: {
                Text("Adult content")
            } footer: {
                SettingsNote(text: "Adult content lives on its own locked Vault shelf and never appears in the showcase. With a PIN, showing it again needs the PIN.")
            }

            Section {
                Toggle("Keep cam & screener copies in The Vault", isOn: setting(\.content.showLowQuality))
            } header: {
                Text("The Vault")
            }

            Section {
                SettingsLanguageEditor(title: "Audio",
                                       codes: model.settings.content.preferredAudioLanguages,
                                       emptyText: "Original audio") { codes in
                    model.updateSettings { $0.content.preferredAudioLanguages = codes }
                }
                SettingsLanguageEditor(title: "Subtitles",
                                       codes: model.settings.content.preferredSubtitleLanguages,
                                       emptyText: "Off unless needed") { codes in
                    model.updateSettings { $0.content.preferredSubtitleLanguages = codes }
                }
            } header: {
                Text("Preferred languages")
            } footer: {
                SettingsNote(text: "The first language wins when a title has several audio or subtitle tracks.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pinPurpose) { purpose in
            SettingsPINSheet(purpose: purpose)
                .environment(model)
        }
    }

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        SettingsBinding.make(model, keyPath)
    }

    /// Showing adult content again requires the PIN when one is set.
    private var hideAdultBinding: Binding<Bool> {
        Binding(
            get: { model.settings.content.hideAdult },
            set: { newValue in
                if !newValue, model.settings.content.adultPINHash != nil {
                    pinPurpose = .reveal
                } else {
                    model.updateSettings { $0.content.hideAdult = newValue }
                }
            })
    }
}

enum SettingsPINPurpose: String, Identifiable {
    case set, change, remove, reveal
    var id: String { rawValue }
}

struct SettingsPINSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let purpose: SettingsPINPurpose

    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorText: String?

    private var needsCurrent: Bool { purpose != .set }
    private var needsNew: Bool { purpose == .set || purpose == .change }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsCurrent {
                SecureField("Current PIN", text: $currentPIN)
                    .textFieldStyle(.roundedBorder)
            }
            if needsNew {
                SecureField("New PIN (4–8 digits)", text: $newPIN)
                    .textFieldStyle(.roundedBorder)
                SecureField("Repeat the new PIN", text: $confirmPIN)
                    .textFieldStyle(.roundedBorder)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tuna.Palette.warning)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        switch purpose {
        case .set: return "Set an adult PIN"
        case .change: return "Change the PIN"
        case .remove: return "Remove the PIN"
        case .reveal: return "Show adult content"
        }
    }

    private var message: String {
        switch purpose {
        case .set: return "The PIN unlocks the Adult shelf in The Vault."
        case .change: return "Enter the current PIN, then the new one twice."
        case .remove: return "Without a PIN, anyone using this Mac can open the Adult shelf."
        case .reveal: return "Enter the PIN to stop hiding adult content."
        }
    }

    private var actionTitle: String {
        switch purpose {
        case .set, .change: return "Save PIN"
        case .remove: return "Remove PIN"
        case .reveal: return "Show"
        }
    }

    private func submit() {
        if needsCurrent && !model.unlockAdult(pin: currentPIN) {
            errorText = "That PIN isn't right."
            return
        }
        if needsNew {
            guard (4...8).contains(newPIN.count), newPIN.allSatisfy({ $0.isNumber }) else {
                errorText = "Use 4 to 8 digits."
                return
            }
            guard newPIN == confirmPIN else {
                errorText = "The two PINs don't match."
                return
            }
        }
        switch purpose {
        case .set, .change: model.setAdultPIN(newPIN)
        case .remove: model.setAdultPIN(nil)
        case .reveal: model.updateSettings { $0.content.hideAdult = false }
        }
        dismiss()
    }
}

/// Ordered language chips with remove buttons and an "Add" menu.
struct SettingsLanguageEditor: View {
    let title: String
    let codes: [String]
    let emptyText: String
    let onChange: ([String]) -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 8) {
                if codes.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
                } else {
                    ShellFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(codes, id: \.self) { code in
                            chip(code)
                        }
                    }
                }
                Menu {
                    ForEach(available) { language in
                        Button("\(language.flag) \(language.name)") {
                            onChange(codes + [language.code])
                        }
                    }
                } label: {
                    Label("Add language", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    private var available: [LanguageInfo] {
        WorldDirectory.languages.filter { !codes.contains($0.code) }
    }

    private func chip(_ code: String) -> some View {
        HStack(spacing: 5) {
            Text(WorldEditing.languageFlag(code))
            Text(WorldEditing.languageEnglishName(code))
                .font(.system(size: 12, weight: .medium))
            if codes.first == code && codes.count > 1 {
                Text("1st")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Button {
                onChange(codes.filter { $0 != code })
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}
