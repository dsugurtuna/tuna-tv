import SwiftUI
import TunaCore

// MARK: - Draft

/// What the user typed into the provider form (shared by onboarding and Settings).
struct ProviderSetupDraft: Equatable {
    /// Stable across retries, so a second attempt updates the provider instead of adding a duplicate.
    var id: ProviderID = UUID().uuidString
    var kind: ProviderKind = .xtream
    var server = ""
    var username = ""
    var password = ""
    var playlistURL = ""
    var epgURL = ""
    var name = ""

    init() {}

    init(config: ProviderConfig) {
        id = config.id
        kind = config.kind
        name = config.name
        epgURL = config.epgURL ?? ""
        switch config.kind {
        case .xtream:
            server = config.serverURL
            username = config.username
        case .m3u:
            playlistURL = config.serverURL
        }
    }

    /// Changes whenever something that affects the connection check changes.
    var credentialSignature: String {
        [kind.rawValue, server, username, password, playlistURL].joined(separator: "\u{1F}")
    }

    var hasRequiredFields: Bool {
        switch kind {
        case .xtream:
            return ShellText.clean(server) != nil && ShellText.clean(username) != nil && ShellText.clean(password) != nil
        case .m3u:
            return ShellText.clean(playlistURL) != nil
        }
    }

    /// Normalized server (Xtream) or playlist URL (M3U); nil when the address is unusable.
    var resolvedServer: String? {
        switch kind {
        case .xtream:
            guard let raw = ShellText.clean(server) else { return nil }
            return XtreamURLBuilder.normalizeServer(raw)
        case .m3u:
            guard let raw = ShellText.clean(playlistURL) else { return nil }
            let candidate = raw.contains("://") ? raw : "http://" + raw
            guard let host = URLComponents(string: candidate)?.host, !host.isEmpty else { return nil }
            return candidate
        }
    }

    var resolvedUsername: String { kind == .xtream ? (ShellText.clean(username) ?? "") : "" }
    var resolvedPassword: String { kind == .xtream ? (ShellText.clean(password) ?? "") : "" }

    var displayName: String {
        if let custom = ShellText.clean(name) { return custom }
        let source = kind == .xtream ? server : playlistURL
        return ShellText.host(of: source) ?? (kind == .xtream ? "My provider" : "My playlist")
    }

    /// A config ready to save. `base` keeps the user's other provider settings when editing.
    func makeConfig(base: ProviderConfig?) -> ProviderConfig? {
        guard let server = resolvedServer else { return nil }
        var config = base ?? ProviderConfig(id: id, name: displayName, kind: kind, serverURL: server)
        config.name = displayName
        config.serverURL = server
        config.username = resolvedUsername
        config.epgURL = ShellText.clean(epgURL)
        return config
    }
}

/// Result of "Check connection".
enum ProviderValidation: Equatable {
    case idle
    case checking
    case valid(AccountInfo)
    case invalid(String)

    var account: AccountInfo? {
        if case .valid(let account) = self { return account }
        return nil
    }

    var errorMessage: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }

    var isChecking: Bool { self == .checking }

    /// The provider answered and the account is usable right now.
    var allowsContinue: Bool { account?.isUsable ?? false }
}

struct ProviderSetupFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Adds a provider, or (when an earlier attempt already saved it) updates it and syncs again, so retries
/// never create duplicates. Waits for the sync; errors carry a user-facing message.
@MainActor
enum ProviderSetupRunner {
    static func run(_ draft: ProviderSetupDraft, model: AppModel) async throws {
        let existing = model.providers.first { $0.id == draft.id }
        guard let config = draft.makeConfig(base: existing) else {
            throw ProviderSetupFailure(message: "The provider address looks incomplete. Go back and check the server URL.")
        }
        let password = draft.resolvedPassword
        if existing != nil {
            await model.updateProvider(config, password: password.isEmpty ? nil : password)
            await model.refreshCatalog(force: true)
            if case .failed(let message) = model.syncPhase {
                throw ProviderSetupFailure(message: message)
            }
        } else {
            try await model.addProvider(config, password: password)
        }
    }
}

// MARK: - Form

enum ProviderSetupField: Hashable {
    case paste, server, username, password, playlist, epg, name
}

/// Xtream / M3U form with "Paste a full link", optional guide + name, "Check connection" (one request),
/// the account card or a friendly error, and the calm safety explainer.
struct ProviderSetupForm: View {
    enum Mode: Equatable {
        case create
        /// Editing a saved provider: the kind is fixed and an empty password keeps the saved one.
        case edit
    }

    @Environment(AppModel.self) private var model

    @Binding var draft: ProviderSetupDraft
    @Binding var validation: ProviderValidation
    var mode: Mode = .create
    /// Whether Return triggers "Check connection" while nothing has been verified yet.
    var checkIsDefaultAction: Bool = true

    @State private var pasteLink = ""
    @State private var pasteFilled = false
    @State private var showsOptional = false
    @FocusState private var focus: ProviderSetupField?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if mode == .create {
                kindPicker
            }
            switch draft.kind {
            case .xtream:
                xtreamFields
            case .m3u:
                m3uFields
            }
            optionalFields
            checkRow
            resultCard
            ProviderSafetyExplainer()
        }
        .onChange(of: draft.credentialSignature) { _, _ in
            if validation != .idle && validation != .checking {
                withAnimation(Tuna.Motion.snappy) { validation = .idle }
            }
        }
        .onChange(of: pasteLink) { _, newValue in
            applyPastedLink(newValue)
        }
        .onChange(of: draft.server) { _, newValue in
            fillFromServerFieldIfFullLink(newValue)
        }
        .onAppear {
            guard mode == .create else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if focus == nil { focus = draft.kind == .xtream ? .server : .playlist }
            }
        }
    }

    // MARK: Fields

    private var kindPicker: some View {
        Picker("Provider type", selection: kindBinding) {
            Text("Xtream Codes").tag(ProviderKind.xtream)
            Text("M3U playlist").tag(ProviderKind.m3u)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)
    }

    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { draft.kind },
            set: { newValue in
                withAnimation(Tuna.Motion.snappy) { draft.kind = newValue }
            })
    }

    private var xtreamFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mode == .create {
                ProviderTextField(label: "Paste a full link (optional)",
                                  prompt: "http://host:8080/get.php?username=…&password=…",
                                  text: $pasteLink,
                                  systemImage: "link",
                                  isFocused: focus == .paste)
                    .focused($focus, equals: .paste)
                if pasteFilled {
                    Label("Filled in server, username and password from your link.", systemImage: "checkmark.circle.fill")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.success)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            ProviderTextField(label: "Server URL",
                              prompt: "http://example.com:8080",
                              text: $draft.server,
                              systemImage: "server.rack",
                              isFocused: focus == .server)
                .focused($focus, equals: .server)
            HStack(alignment: .top, spacing: 12) {
                ProviderTextField(label: "Username",
                                  prompt: "Username",
                                  text: $draft.username,
                                  systemImage: "person.fill",
                                  isFocused: focus == .username)
                    .focused($focus, equals: .username)
                ProviderTextField(label: "Password",
                                  prompt: mode == .edit ? "Leave empty to keep" : "Password",
                                  text: $draft.password,
                                  systemImage: "key.fill",
                                  isSecure: true,
                                  isFocused: focus == .password)
                    .focused($focus, equals: .password)
            }
        }
    }

    private var m3uFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderTextField(label: "Playlist URL",
                              prompt: "http://example.com/playlist.m3u",
                              text: $draft.playlistURL,
                              systemImage: "list.bullet.rectangle",
                              isFocused: focus == .playlist)
                .focused($focus, equals: .playlist)
            if mode == .create, let parsed = XtreamURLBuilder.parseFullLink(draft.playlistURL) {
                ProviderXtreamHint {
                    switchToXtream(server: parsed.server, username: parsed.username, password: parsed.password)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var optionalFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .create {
                Button {
                    withAnimation(Tuna.Motion.snappy) { showsOptional.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showsOptional ? 90 : 0))
                        Text("TV guide & name (optional)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if showsOptional || mode == .edit {
                ProviderTextField(label: "XMLTV guide URL",
                                  prompt: "Leave empty to use your provider's guide",
                                  text: $draft.epgURL,
                                  systemImage: "calendar",
                                  isFocused: focus == .epg)
                    .focused($focus, equals: .epg)
                ProviderTextField(label: "Name",
                                  prompt: draft.displayName,
                                  text: $draft.name,
                                  systemImage: "character.cursor.ibeam",
                                  isFocused: focus == .name)
                    .focused($focus, equals: .name)
            }
        }
    }

    // MARK: Check

    private var canCheck: Bool {
        guard !validation.isChecking else { return false }
        switch draft.kind {
        case .xtream: return draft.hasRequiredFields
        case .m3u: return ShellText.clean(draft.playlistURL) != nil
        }
    }

    private var checkRow: some View {
        HStack(spacing: 14) {
            GlassButton(title: validation.isChecking ? "Checking…" : "Check connection",
                        systemImage: "bolt.horizontal.circle.fill",
                        style: validation.account == nil ? .primary : .secondary,
                        action: { check() })
                .keyboardShortcut(checkIsDefaultAction && validation.account == nil ? .defaultAction : nil)
                .disabled(!canCheck)

            if validation.isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("One request to your provider…")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            } else if mode == .edit && draft.kind == .xtream && ShellText.clean(draft.password) == nil {
                Text("Enter the password to test the connection.")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var resultCard: some View {
        if let account = validation.account {
            ProviderAccountCard(account: account, kind: draft.kind)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let message = validation.errorMessage {
            ProviderErrorCard(message: message)
                .transition(.opacity)
        }
    }

    private func check() {
        guard canCheck else { return }
        focus = nil
        guard let server = draft.resolvedServer else {
            withAnimation(Tuna.Motion.snappy) {
                validation = .invalid(draft.kind == .xtream
                    ? "That server address doesn't look right. It usually looks like http://example.com:8080."
                    : "That playlist address doesn't look right. Paste the full http(s) link.")
            }
            return
        }
        let kind = draft.kind
        let username = draft.resolvedUsername
        let password = draft.resolvedPassword
        withAnimation(Tuna.Motion.snappy) { validation = .checking }
        Task { @MainActor in
            do {
                let account = try await model.validateProvider(kind: kind, server: server, username: username, password: password)
                withAnimation(Tuna.Motion.page) { validation = .valid(account) }
            } catch {
                let message = ShellFormat.errorMessage(error)
                withAnimation(Tuna.Motion.snappy) { validation = .invalid(message) }
            }
        }
    }

    // MARK: Link parsing

    private func applyPastedLink(_ text: String) {
        guard let cleaned = ShellText.clean(text), let parsed = XtreamURLBuilder.parseFullLink(cleaned) else {
            if pasteFilled {
                withAnimation(Tuna.Motion.snappy) { pasteFilled = false }
            }
            return
        }
        withAnimation(Tuna.Motion.snappy) {
            draft.server = parsed.server
            draft.username = parsed.username
            draft.password = parsed.password
            pasteFilled = true
        }
    }

    /// People often paste the whole get.php link into the server field: split it for them.
    private func fillFromServerFieldIfFullLink(_ text: String) {
        guard mode == .create, text.contains("username="),
              let cleaned = ShellText.clean(text),
              let parsed = XtreamURLBuilder.parseFullLink(cleaned) else { return }
        withAnimation(Tuna.Motion.snappy) {
            draft.server = parsed.server
            if ShellText.clean(draft.username) == nil { draft.username = parsed.username }
            if ShellText.clean(draft.password) == nil { draft.password = parsed.password }
            pasteFilled = true
        }
    }

    private func switchToXtream(server: String, username: String, password: String) {
        withAnimation(Tuna.Motion.snappy) {
            draft.kind = .xtream
            draft.server = server
            draft.username = username
            draft.password = password
            pasteFilled = true
        }
    }
}

// MARK: - Pieces

struct ProviderTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var systemImage: String? = nil
    var isSecure = false
    var isFocused = false
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textSecondary)
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFocused ? Tuna.Palette.accentCool : Tuna.Palette.textTertiary)
                        .frame(width: 18)
                }
                field
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.09 : 0.055)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isFocused ? Tuna.Palette.accentCool.opacity(0.8) : Color.white.opacity(0.09),
                              lineWidth: isFocused ? 1.5 : 1))
            .animation(Tuna.Motion.snappy, value: isFocused)
        }
    }

    @ViewBuilder private var field: some View {
        if isSecure {
            SecureField(label, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(Tuna.Fonts.bodyLarge)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .focusEffectDisabled()
        } else {
            TextField(label, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(monospaced ? Tuna.Fonts.mono : Tuna.Fonts.bodyLarge)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .autocorrectionDisabled()
                .focusEffectDisabled()
        }
    }
}

/// "Connected" card: status, expiry + days left, connections, trial, formats.
struct ProviderAccountCard: View {
    let account: AccountInfo
    var kind: ProviderKind = .xtream

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if kind == .xtream {
                facts
            }
            if account.isAtConnectionLimit {
                Label("Every connection on your plan is in use right now. Tuna TV will wait rather than kick another device off.",
                      systemImage: "person.2.slash.fill")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = account.serverMessage.flatMap({ ShellText.clean($0) }) {
                Label(message, systemImage: "text.bubble.fill")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill((account.isUsable ? Tuna.Palette.success : Tuna.Palette.danger).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder((account.isUsable ? Tuna.Palette.success : Tuna.Palette.danger).opacity(0.3), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: account.isUsable ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .font(.system(size: 26))
                .foregroundStyle(account.isUsable ? Tuna.Palette.success : Tuna.Palette.danger)
                .symbolEffect(.bounce, value: account.isUsable)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.isUsable ? "Connected — your account looks good" : "Your provider answered, but this account can't be used")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("Status: \(statusText)")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            Spacer(minLength: 8)
            if account.isTrial {
                ShellTag(text: "Trial", tint: Tuna.Palette.gold)
            }
        }
    }

    private var statusText: String {
        if let status = account.status.flatMap({ ShellText.clean($0) }) { return status }
        return account.isAuthorized ? "Active" : "Not authorized"
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow {
                ProviderFact(label: "Expires", value: ShellFormat.expiryLine(account.expiresAt), symbol: "calendar")
                ProviderFact(label: "Connections",
                             value: ShellFormat.connections(active: account.activeConnections, max: account.maxConnections),
                             symbol: "person.2.fill")
            }
            GridRow {
                ProviderFact(label: "Formats", value: formatsText, symbol: "film.stack")
                ProviderFact(label: "Plan", value: account.isTrial ? "Trial" : "Full subscription", symbol: "creditcard.fill")
            }
        }
    }

    private var formatsText: String {
        let formats = account.allowedOutputFormats.compactMap { ShellText.clean($0)?.uppercased() }
        return formats.isEmpty ? "Not reported" : formats.joined(separator: ", ")
    }
}

struct ProviderFact: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderErrorCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Tuna.Palette.warning)
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was retried automatically — Tuna TV never hammers your provider.")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tuna.Palette.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tuna.Palette.warning.opacity(0.3), lineWidth: 1))
    }
}

/// "Gentle by design" — the calm Provider Shield explainer.
struct ProviderSafetyExplainer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(Tuna.Palette.success)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
                Text("Gentle by design")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("Tuna TV sends one request at a time, never opens a second stream, and pauses itself if your provider pushes back.")
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tuna.Palette.success.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tuna.Palette.success.opacity(0.22), lineWidth: 1))
    }
}

/// Shown when an M3U field holds an Xtream get.php link.
struct ProviderXtreamHint: View {
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Tuna.Palette.gold)
            Text("This is an Xtream Codes link. Switching gives Tuna TV the full catalog with less work for your provider.")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Use Xtream") { onSwitch() }
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tuna.Palette.gold.opacity(0.08)))
    }
}
