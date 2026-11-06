import SwiftUI
import TunaCore

struct SettingsAboutTab: View {
    private struct License: Identifiable {
        let name: String
        let license: String
        var id: String { name }
    }

    private let licenses: [License] = [
        License(name: "Tuna TV", license: "GPL-3.0"),
        License(name: "AetherEngine", license: "LGPL-3.0"),
        License(name: "FFmpeg", license: "LGPL-2.1+"),
        License(name: "dav1d", license: "BSD-2-Clause"),
        License(name: "libdovi", license: "MIT"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                TunaLogoMark(size: 96)
                    .shadow(color: Tuna.Palette.accent.opacity(0.35), radius: 24)
                TunaWordmark(size: 28)
                Text("Version \(version) (\(build))")
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(.secondary)
                Text("Arguably the best IPTV app for macOS. Free and open source.")
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                Link(destination: ShellLinks.github) {
                    Label("github.com/dsugurtuna/tuna-tv", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                VStack(spacing: 0) {
                    ForEach(licenses) { item in
                        HStack {
                            Text(item.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(item.license).font(Tuna.Fonts.mono).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if item.id != licenses.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                .frame(maxWidth: 420)

                Label("Tuna TV provides no content. Bring your own subscription.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
