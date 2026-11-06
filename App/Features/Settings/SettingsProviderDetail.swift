import SwiftUI
import TunaCore

/// Account, Provider Shield and connection settings for one provider. Every change goes through
/// `model.updateProvider(_:password:)` (password nil = keep the saved one).
struct SettingsProviderDetail: View {
    @Environment(AppModel.self) private var model

    let config: ProviderConfig
    let status: ProviderStatus?

    @State private var nameText = ""
    @State private var epgText = ""
    @State private var customAgent = ""
    @State private var confirmRemove = false
    @State private var showingEditLogin = false
    @State private var isRefreshing = false
    @State private var isResetting = false

    var body: some View {
        Form {
            Section {
                SettingsProviderHeader(config: config, status: status)
            }
            accountSection
            shieldSection
            connectionSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear { loadText() }
        .onChange(of: config) { old, new in
            if old.name != new.name { nameText = new.name }
            if old.epgURL != new.epgURL { epgText = new.epgURL ?? "" }
            if old.userAgent != new.userAgent, case .custom(let value) = new.userAgent { customAgent = value }
        }
        .confirmationDialog("Remove “\(config.name)”?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove provider", role: .destructive) {
                model.removeProvider(config.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tuna TV forgets this provider, its saved catalog and its password on this Mac. You can add it again anytime.")
        }
        .sheet(isPresented: $showingEditLogin) {
            SettingsEditProviderSheet(config: config)
                .environment(model)
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section("Account") {
            if let account = status?.account {
                LabeledContent("Status") {
                    Label(accountStatus(account), systemImage: account.isUsable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(account.isUsable ? Tuna.Palette.success : Tuna.Palette.danger)
                }
                LabeledContent("Expires", value: ShellFormat.expiryLine(account.expiresAt))
                LabeledContent("Connections",
                               value: ShellFormat.connections(active: account.activeConnections, max: account.maxConnections))
                LabeledContent("Plan", value: account.isTrial ? "Trial" : "Full subscription")
                if !account.allowedOutputFormats.isEmpty {
                    LabeledContent("Formats", value: account.allowedOutputFormats.map { $0.uppercased() }.joined(separator: ", "))
                }
                if let message = account.serverMessage.flatMap({ ShellText.clean($0) }) {
                    LabeledContent("Message", value: message)
                }
            } else {
                LabeledContent("Status", value: config.kind == .m3u ? "Playlists don't report account details" : "Not checked yet")
            }
            LabeledContent("Last sync", value: status?.lastSync.map { ShellFormat.relative($0) } ?? "Never")
            if let error = status?.lastError.flatMap({ ShellText.clean($0) }) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tuna.Palette.warning)
            }
        }
    }

    private func accountStatus(_ account: AccountInfo) -> String {
        if let status = account.status.flatMap({ ShellText.clean($0) }) { return status }
        return account.isUsable ? "Active" : "Not usable"
    }

    // MARK: Shield

    private var shieldSection: some View {
        Section {
            SettingsShieldPanel(snapshot: status?.shield, isResetting: isResetting, onReset: { resetShield() })
        } header: {
            Text("Provider Shield")
        } footer: {
            SettingsNote(text: "Tuna TV sends one request at a time, spaces them out, and pauses by itself when your provider pushes back. Waiting is always the safest fix; reset only after fixing the cause.")
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            Toggle("Use this provider", isOn: configBinding(\.isEnabled))

            LabeledContent("Name") {
                TextField("Name", text: $nameText, prompt: Text(config.name))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .onSubmit { saveName() }
            }

            Picker("Request pacing", selection: configBinding(\.pacing)) {
                ForEach(PacingProfile.allCases, id: \.self) { profile in
                    Text(profile.label).tag(profile)
                }
            }

            Picker("User agent", selection: agentChoice) {
                ForEach(UserAgentPreset.presets, id: \.self) { preset in
                    Text(preset.label).tag(SettingsAgentChoice.preset(preset))
                }
                Text("Custom").tag(SettingsAgentChoice.custom)
            }
            if isCustomAgent {
                LabeledContent("Custom user agent") {
                    HStack {
                        TextField("Custom user agent", text: $customAgent, prompt: Text("Player/1.0"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit { saveCustomAgent() }
                        Button("Save") { saveCustomAgent() }
                            .disabled(ShellText.clean(customAgent) == nil)
                    }
                    .frame(maxWidth: 360)
                }
            }
            LabeledContent("Sent as") {
                Text(config.userAgent.value)
                    .font(Tuna.Fonts.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            if config.kind == .xtream {
                Picker("Live stream format", selection: configBinding(\.liveFormat)) {
                    ForEach(LiveStreamFormat.allCases, id: \.self) { format in
                        Text(ShellFormat.liveFormatLabel(format)).tag(format)
                    }
                }
            }

            LabeledContent("TV guide (XMLTV)") {
                HStack {
                    TextField("TV guide URL", text: $epgText, prompt: Text("Provider's own guide"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { saveEPG() }
                    Button("Save") { saveEPG() }
                        .disabled(ShellText.clean(epgText) == config.epgURL.flatMap({ ShellText.clean($0) }))
                }
                .frame(maxWidth: 380)
            }

            Stepper(value: configBinding(\.maxStreams), in: 1...maxStreamsCap) {
                LabeledContent("Simultaneous streams", value: "\(config.maxStreams)")
            }

            Picker("Refresh catalog", selection: configBinding(\.syncInterval)) {
                ForEach(syncIntervals, id: \.self) { seconds in
                    Text(ShellFormat.interval(seconds)).tag(seconds)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            SettingsNote(text: "Keep the recommended user agent unless your provider asks for a specific player — a changing user agent looks suspicious to anti-flood systems. One stream at a time never kicks another device off your plan.")
        }
    }

    private var maxStreamsCap: Int {
        max(1, max(status?.account?.maxConnections ?? 1, config.maxStreams))
    }

    private var syncIntervals: [TimeInterval] {
        SettingsOptions.including(config.syncInterval, in: [6, 12, 24, 48, 168].map { TimeInterval($0) * 3600 })
    }

    private var isCustomAgent: Bool {
        if case .custom = config.userAgent { return true }
        return false
    }

    private var agentChoice: Binding<SettingsAgentChoice> {
        Binding(
            get: {
                if case .custom = config.userAgent { return SettingsAgentChoice.custom }
                return SettingsAgentChoice.preset(config.userAgent)
            },
            set: { choice in
                switch choice {
                case .preset(let preset):
                    update { $0.userAgent = preset }
                case .custom:
                    let value = ShellText.clean(customAgent) ?? ""
                    update { $0.userAgent = .custom(value) }
                }
            })
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    showingEditLogin = true
                } label: {
                    Label("Edit login…", systemImage: "key.fill")
                }
                Button {
                    refresh()
                } label: {
                    Label(isRefreshing || isSyncing ? "Refreshing…" : "Refresh now", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || isSyncing || !config.isEnabled)
                Spacer()
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove…", systemImage: "trash")
                }
            }
            SettingsNote(text: refreshNote)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = model.syncPhase { return true }
        return false
    }

    private var refreshNote: String {
        let base = "Catalogs refresh by themselves (\(ShellFormat.interval(config.syncInterval).lowercased())). Manual refreshes are limited to one every 10 minutes to protect your account."
        guard let lastSync = status?.lastSync, Date().timeIntervalSince(lastSync) < 600 else { return base }
        let next = lastSync.addingTimeInterval(600)
        return base + " Next manual refresh after \(ShellFormat.time(next))."
    }

    // MARK: Mutations

    private func configBinding<T: Equatable>(_ keyPath: WritableKeyPath<ProviderConfig, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                guard config[keyPath: keyPath] != newValue else { return }
                update { $0[keyPath: keyPath] = newValue }
            })
    }

    private func update(_ change: (inout ProviderConfig) -> Void) {
        var updated = config
        change(&updated)
        guard updated != config else { return }
        let final = updated
        Task { @MainActor in
            await model.updateProvider(final, password: nil)
        }
    }

    private func loadText() {
        nameText = config.name
        epgText = config.epgURL ?? ""
        if case .custom(let value) = config.userAgent { customAgent = value }
    }

    private func saveName() {
        guard let name = ShellText.clean(nameText) else {
            nameText = config.name
            return
        }
        update { $0.name = name }
    }

    private func saveEPG() {
        let value = ShellText.clean(epgText)
        update { $0.epgURL = value }
    }

    private func saveCustomAgent() {
        guard let value = ShellText.clean(customAgent) else { return }
        update { $0.userAgent = .custom(value) }
    }

    private func refresh() {
        isRefreshing = true
        Task { @MainActor in
            await model.refreshCatalog(force: false)
            isRefreshing = false
        }
    }

    private func resetShield() {
        isResetting = true
        let id = config.id
        Task { @MainActor in
            await model.resetShield(for: id)
            isResetting = false
        }
    }
}

enum SettingsAgentChoice: Hashable {
    case preset(UserAgentPreset)
    case custom
}

struct SettingsProviderHeader: View {
    let config: ProviderConfig
    let status: ProviderStatus?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Tuna.Gradients.cool)
                Image(systemName: config.kind == .xtream ? "server.rack" : "list.bullet.rectangle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(config.name)
                    .font(.system(size: 17, weight: .bold))
                Text(detailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            SettingsStatusPill(state: ShellShieldState.from(status?.shield))
        }
        .padding(.vertical, 4)
    }

    private var detailLine: String {
        let kind = config.kind == .xtream ? "Xtream Codes" : "M3U playlist"
        let host = ShellText.host(of: config.serverURL) ?? config.serverURL
        if config.kind == .xtream, let user = ShellText.clean(config.username) {
            return "\(kind) · \(host) · \(user)"
        }
        return "\(kind) · \(host)"
    }
}

/// Live Provider Shield state: breaker, daily budget, pacing and the recent request log.
struct SettingsShieldPanel: View {
    let snapshot: GovernorSnapshot?
    let isResetting: Bool
    let onReset: () -> Void

    var body: some View {
        let state = ShellShieldState.from(snapshot)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(state.tint)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(state.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button(isResetting ? "Resetting…" : "Reset shield") { onReset() }
                    .disabled(isResetting || snapshot == nil || (snapshot?.isHealthy ?? true))
            }
            if let snapshot {
                budget(snapshot)
                HStack(spacing: 22) {
                    SettingsMiniFact(label: "Last request", value: snapshot.lastRequestAt.map { ShellFormat.relative($0) } ?? "—")
                    SettingsMiniFact(label: "Next allowed", value: nextAllowed(snapshot))
                    SettingsMiniFact(label: "In flight", value: "\(snapshot.inFlight)")
                    SettingsMiniFact(label: "Waiting", value: "\(snapshot.queued)")
                }
                if !snapshot.recent.isEmpty {
                    recentLog(snapshot.recent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func budget(_ snapshot: GovernorSnapshot) -> some View {
        let total = max(1, snapshot.dailySoftBudget)
        let used = min(snapshot.requestsToday, total)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Requests today")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(snapshot.requestsToday.formatted()) of \(snapshot.dailySoftBudget.formatted())")
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(used), total: Double(total))
                .tint(Double(used) / Double(total) > 0.8 ? Tuna.Palette.warning : Tuna.Palette.success)
        }
    }

    private func nextAllowed(_ snapshot: GovernorSnapshot) -> String {
        guard let next = snapshot.nextAllowedAt else { return "Now" }
        let wait = next.timeIntervalSinceNow
        if wait <= 0 { return "Now" }
        if wait < 60 { return String(format: "in %.1f s", wait) }
        return ShellFormat.time(next)
    }

    private func recentLog(_ entries: [RequestLogEntry]) -> some View {
        let latest = Array(entries.sorted { $0.date > $1.date }.prefix(8))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recent requests")
                .font(.system(size: 12, weight: .medium))
            VStack(spacing: 0) {
                ForEach(latest) { entry in
                    SettingsRequestRow(entry: entry)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }
}

struct SettingsRequestRow: View {
    let entry: RequestLogEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(entry.purpose)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if entry.priority == .userInitiated {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("You asked for this one")
            }
            Spacer(minLength: 6)
            Text(entry.status.map { String($0) } ?? "—")
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(statusColor)
            Text("\(entry.durationMs) ms")
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .help("\(entry.summary) — \(entry.outcome)")
    }

    private var statusColor: Color {
        guard let status = entry.status else { return Color.secondary }
        if (200..<300).contains(status) { return Tuna.Palette.success }
        if (300..<400).contains(status) { return Tuna.Palette.textSecondary }
        return Tuna.Palette.danger
    }
}
