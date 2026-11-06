import SwiftUI
import TunaCore

/// Add a provider from Settings: the onboarding form, then a compact live sync view.
/// "Continue in background" closes the sheet while the paced sync carries on.
struct SettingsAddProviderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProviderSetupDraft()
    @State private var validation: ProviderValidation = .idle
    @State private var phase: Phase = .form
    @State private var progressReceivedAt = Date()

    enum Phase: Equatable {
        case form
        case adding
        case done
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch phase {
                case .form:
                    formContent
                case .adding:
                    addingContent
                case .done:
                    doneContent
                case .failed(let message):
                    failedContent(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 660, height: 680)
        .background(Tuna.Palette.surface)
        .environment(\.colorScheme, .dark)
        .onChange(of: syncProgress) { _, _ in
            progressReceivedAt = Date()
        }
    }

    private var syncProgress: SyncProgress? {
        if case .syncing(let progress) = model.syncPhase, progress.providerID == draft.id { return progress }
        return nil
    }

    private var canAdd: Bool {
        validation.allowsContinue || (draft.kind == .m3u && validation.errorMessage != nil && draft.resolvedServer != nil)
    }

    // MARK: Phases

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a provider")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text("Check the connection first — it's a single request.")
                        .font(.system(size: 13))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
                ProviderSetupForm(draft: $draft, validation: $validation, mode: .create,
                                  checkIsDefaultAction: !validation.allowsContinue)
            }
            .padding(26)
        }
    }

    private var addingContent: some View {
        VStack(spacing: 22) {
            ShellProgressRing(fraction: syncProgress?.fraction ?? 0.015, lineWidth: 9, spinning: true)
                .frame(width: 130, height: 130)
            VStack(spacing: 6) {
                Text(syncProgress.map { ShellFormat.stageLabel($0.stage) } ?? "Connecting to \(draft.displayName)…")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text("Loading at your provider's pace, one request at a time.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            if let progress = syncProgress {
                HStack(spacing: 12) {
                    ForEach([StreamKind.live.rawValue, StreamKind.movie.rawValue, StreamKind.series.rawValue], id: \.self) { key in
                        TheaterCounterTile(label: ShellFormat.countLabel(key),
                                           symbol: ShellFormat.countSymbol(key),
                                           value: progress.counts[key] ?? 0)
                    }
                }
                TheaterPacingLine(nextRequestIn: progress.nextRequestIn, receivedAt: progressReceivedAt)
            }
            Text("You can close this window — loading continues in the background.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
        .padding(30)
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundStyle(Tuna.Palette.success)
                .symbolEffect(.bounce, value: phase == .done)
            Text("\(draft.displayName) is ready")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(ShellFormat.breakdown(model.library.stats.showcaseCounts) + " in your showcase")
                .font(.system(size: 13))
                .foregroundStyle(Tuna.Palette.textSecondary)
        }
        .padding(30)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Tuna.Palette.warning)
                .symbolRenderingMode(.hierarchical)
            Text("We paused before finishing")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Tuna.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Label("Nothing was retried automatically — your account is safe.", systemImage: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Tuna.Palette.success)
        }
        .padding(30)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .form:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add provider") { add() }
                    .keyboardShortcut(validation.allowsContinue ? .defaultAction : nil)
                    .disabled(!canAdd)
            case .adding:
                Spacer()
                Button("Continue in background") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .done:
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Edit details") {
                    withAnimation(Tuna.Motion.snappy) { phase = .form }
                }
                Button("Try again") { add() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func add() {
        let currentDraft = draft
        let name = draft.displayName
        withAnimation(Tuna.Motion.snappy) { phase = .adding }
        Task { @MainActor in
            do {
                try await ProviderSetupRunner.run(currentDraft, model: model)
                withAnimation(Tuna.Motion.snappy) { phase = .done }
                model.showToast("\(name) is ready", style: .success)
            } catch {
                let message = ShellFormat.errorMessage(error)
                withAnimation(Tuna.Motion.snappy) { phase = .failed(message) }
                model.showToast("\(name): \(message)", style: .error)
            }
        }
    }
}

/// Edit the address and login of a saved provider (empty password keeps the saved one).
struct SettingsEditProviderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let config: ProviderConfig

    @State private var draft: ProviderSetupDraft
    @State private var validation: ProviderValidation = .idle
    @State private var isSaving = false

    init(config: ProviderConfig) {
        self.config = config
        _draft = State(initialValue: ProviderSetupDraft(config: config))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Edit login")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        Text("Change the address or credentials for \(config.name). Leave the password empty to keep the saved one.")
                            .font(.system(size: 13))
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ProviderSetupForm(draft: $draft, validation: $validation, mode: .edit, checkIsDefaultAction: false)
                }
                .padding(26)
            }
            Divider()
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(width: 640, height: 640)
        .background(Tuna.Palette.surface)
        .environment(\.colorScheme, .dark)
    }

    private var canSave: Bool {
        guard draft.resolvedServer != nil else { return false }
        return draft.kind == .m3u || ShellText.clean(draft.username) != nil
    }

    private func save() {
        guard let updated = draft.makeConfig(base: config) else { return }
        let password = draft.resolvedPassword
        isSaving = true
        Task { @MainActor in
            await model.updateProvider(updated, password: password.isEmpty ? nil : password)
            isSaving = false
            dismiss()
        }
    }
}
