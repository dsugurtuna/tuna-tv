import SwiftUI
import TunaCore

/// TMDB / OMDb keys (saved via `model.setMetadataKeys`). Assumes nil = keep the saved key, "" = remove it.
struct SettingsMetadataTab: View {
    @Environment(AppModel.self) private var model

    @State private var tmdbKey = ""
    @State private var omdbKey = ""
    @State private var isSaving = false
    @State private var savedNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("Look up artwork, cast and ratings online", isOn: SettingsBinding.make(model, \.onlineMetadata))
            } footer: {
                SettingsNote(text: "Lookups go to TMDB, TVMaze, OMDb and iptv-org — never to your IPTV provider. Results are cached on this Mac.")
            }

            Section {
                HStack {
                    SettingsKeyStatus(isSet: model.hasTMDBKey, setText: "Connected",
                                      unsetText: "Not set — series still get details from TVMaze")
                    Spacer()
                    if model.hasTMDBKey {
                        Button("Remove", role: .destructive) { remove(tmdb: true) }
                    }
                }
                SecureField("TMDB key", text: $tmdbKey,
                            prompt: Text(model.hasTMDBKey ? "Saved — paste a new key to replace it" : "API key or Read Access Token"))
                Link(destination: ShellLinks.tmdbKey) {
                    Label("Get a free key", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("TMDB")
            } footer: {
                SettingsNote(text: "Unlocks posters, backdrops, title logos, cast photos, trailers, ratings, trending and “more like this”.")
            }

            Section {
                HStack {
                    SettingsKeyStatus(isSet: model.hasOMDbKey, setText: "Connected", unsetText: "Not set")
                    Spacer()
                    if model.hasOMDbKey {
                        Button("Remove", role: .destructive) { remove(tmdb: false) }
                    }
                }
                SecureField("OMDb key", text: $omdbKey,
                            prompt: Text(model.hasOMDbKey ? "Saved — paste a new key to replace it" : "OMDb API key"))
                Link(destination: ShellLinks.omdbKey) {
                    Label("Get a free key", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("OMDb (optional)")
            } footer: {
                SettingsNote(text: "Adds IMDb, Rotten Tomatoes and Metacritic scores, awards and box office.")
            }

            Section {
                HStack {
                    if let savedNote {
                        Label(savedNote, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tuna.Palette.success)
                    }
                    Spacer()
                    Button(isSaving ? "Saving…" : "Save keys") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || (ShellText.clean(tmdbKey) == nil && ShellText.clean(omdbKey) == nil))
                }
            } footer: {
                SettingsNote(text: "Keys are stored in your Mac's Keychain. Leave a field empty to keep its saved key.")
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let tmdb = ShellText.clean(tmdbKey)
        let omdb = ShellText.clean(omdbKey)
        guard tmdb != nil || omdb != nil else { return }
        isSaving = true
        Task { @MainActor in
            await model.setMetadataKeys(tmdb: tmdb, omdb: omdb)
            isSaving = false
            tmdbKey = ""
            omdbKey = ""
            withAnimation(Tuna.Motion.snappy) { savedNote = "Saved" }
        }
    }

    private func remove(tmdb: Bool) {
        Task { @MainActor in
            await model.setMetadataKeys(tmdb: tmdb ? "" : nil, omdb: tmdb ? nil : "")
            withAnimation(Tuna.Motion.snappy) { savedNote = "Removed" }
        }
    }
}
