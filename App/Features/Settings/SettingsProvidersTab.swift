import SwiftUI
import TunaCore

/// Providers: list on the left, account + Provider Shield + connection settings on the right.
struct SettingsProvidersTab: View {
    @Environment(AppModel.self) private var model

    @State private var selection: ProviderID?
    @State private var showingAdd = false

    var body: some View {
        Group {
            if model.providers.isEmpty {
                SettingsNoProvidersView(isDemo: model.isDemo,
                                        onAdd: { showingAdd = true },
                                        onExitDemo: { model.exitDemo() })
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    detail
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            SettingsAddProviderSheet()
                .environment(model)
        }
        .onAppear { ensureSelection() }
        .onChange(of: model.providers.map(\.id)) { _, _ in
            ensureSelection()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Providers") {
                    ForEach(model.providers) { config in
                        SettingsProviderRow(config: config, status: status(for: config.id))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.isDemo {
                    Button("Exit demo") { model.exitDemo() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(10)
        }
        .frame(width: 240)
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let config = model.providers.first(where: { $0.id == id }) {
            SettingsProviderDetail(config: config, status: status(for: id))
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SettingsPlaceholder(symbol: "sidebar.left",
                                title: "Pick a provider",
                                message: "Choose a provider on the left to see its account and Provider Shield.")
        }
    }

    private func status(for id: ProviderID) -> ProviderStatus? {
        model.providerStatus.first { $0.id == id }
    }

    private func ensureSelection() {
        let ids = model.providers.map(\.id)
        if let current = selection, ids.contains(current) { return }
        selection = ids.first
    }
}

struct SettingsProviderRow: View {
    let config: ProviderConfig
    let status: ProviderStatus?

    var body: some View {
        let shield = ShellShieldState.from(status?.shield)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(shield.tint.opacity(0.18))
                Image(systemName: config.kind == .xtream ? "server.rack" : "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(shield.tint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if !config.isEnabled { return "Turned off" }
        if status?.lastError.flatMap({ ShellText.clean($0) }) != nil { return "Needs attention" }
        if let lastSync = status?.lastSync { return "Synced \(ShellFormat.relative(lastSync))" }
        return config.kind == .xtream ? "Xtream Codes" : "M3U playlist"
    }
}

struct SettingsNoProvidersView: View {
    let isDemo: Bool
    let onAdd: () -> Void
    let onExitDemo: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            TunaLogoMark(size: 64)
            Text(isDemo ? "You're exploring the demo" : "No provider yet")
                .font(.system(size: 20, weight: .bold))
            Text(isDemo
                 ? "Everything you see is invented demo content. Add your own provider when you're ready."
                 : "Add an Xtream Codes login or an M3U playlist. Tuna TV checks it with a single request.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if isDemo {
                    Button("Exit demo") { onExitDemo() }
                }
                Button("Add provider…") { onAdd() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            ProviderSafetyExplainer()
                .frame(maxWidth: 520)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
