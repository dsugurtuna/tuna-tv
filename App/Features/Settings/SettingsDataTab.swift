import SwiftUI
import TunaCore

struct SettingsDataTab: View {
    @State private var cacheBytes: Int64?
    @State private var isClearing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Size on disk") {
                    Text(cacheBytes.map { ShellFormat.bytes($0) } ?? "Calculating…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(isClearing ? "Clearing…" : "Clear image cache") { clear() }
                        .disabled(isClearing)
                }
            } header: {
                Text("Image cache")
            } footer: {
                SettingsNote(text: "Posters, backdrops and logos are kept on disk so your provider's server is asked for each image only once. Clearing is safe; images reload gently, one at a time from your provider.")
            }

            Section {
                SettingsNote(text: "Metadata (posters, cast, ratings) is cached for about 30 days and refreshed quietly in the background. Provider catalogs are cached too and refresh at most once a day, so launching Tuna TV never hits your provider.")
            } header: {
                Text("Metadata & catalogs")
            }
        }
        .formStyle(.grouped)
        .task { await refreshSize() }
    }

    private func refreshSize() async {
        let bytes = await Task.detached(priority: .utility) { ImagePipeline.shared.diskUsageBytes }.value
        cacheBytes = bytes
    }

    private func clear() {
        isClearing = true
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { ImagePipeline.shared.clearDiskCache() }.value
            await refreshSize()
            isClearing = false
        }
    }
}
