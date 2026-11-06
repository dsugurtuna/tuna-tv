import SwiftUI
import TunaCore

/// Step 6: saves the provider and runs the first (paced) sync while showing it live, then the results.
struct OnboardingTheaterStep: View {
    @Environment(AppModel.self) private var model

    let draft: ProviderSetupDraft
    let reduceMotion: Bool
    let onEditProvider: () -> Void

    @State private var run: TheaterRunState = .idle

    var body: some View {
        ZStack {
            switch display {
            case .connecting:
                TheaterConnectingView(providerName: draft.displayName, reduceMotion: reduceMotion)
                    .transition(.opacity)
            case .syncing(let progress):
                TheaterSyncView(progress: progress, kind: draft.kind, reduceMotion: reduceMotion)
                    .transition(.opacity)
            case .done:
                TheaterResultsView(stats: model.library.stats, reduceMotion: reduceMotion, onStart: { finish() })
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            case .failed(let message):
                TheaterFailureView(message: message, onRetry: { start(retry: true) }, onEdit: { onEditProvider() })
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Tuna.Motion.page, value: display.kind)
        .onAppear { start(retry: false) }
    }

    private var display: TheaterDisplay {
        if case .failed(let message) = run { return .failed(message) }
        if case .syncing(let progress) = model.syncPhase { return .syncing(progress) }
        guard run == .finished else { return .connecting }
        if case .failed(let message) = model.syncPhase, libraryIsEmpty { return .failed(message) }
        return .done
    }

    private var libraryIsEmpty: Bool {
        model.library.movies.isEmpty && model.library.series.isEmpty && model.library.channels.isEmpty
    }

    private func start(retry: Bool) {
        if !retry && run != .idle { return }
        withAnimation(Tuna.Motion.snappy) { run = .running }
        let currentDraft = draft
        Task { @MainActor in
            do {
                try await ProviderSetupRunner.run(currentDraft, model: model)
                withAnimation(Tuna.Motion.page) { run = .finished }
            } catch {
                let message = ShellFormat.errorMessage(error)
                withAnimation(Tuna.Motion.page) { run = .failed(message) }
            }
        }
    }

    private func finish() {
        model.completeOnboarding()
    }
}

enum TheaterRunState: Equatable {
    case idle
    case running
    case finished
    case failed(String)
}

enum TheaterDisplay: Equatable {
    case connecting
    case syncing(SyncProgress)
    case done
    case failed(String)

    /// Changes only when the screen changes (not on every progress tick).
    var kind: Int {
        switch self {
        case .connecting: return 0
        case .syncing: return 1
        case .done: return 2
        case .failed: return 3
        }
    }
}

// MARK: - Connecting

struct TheaterConnectingView: View {
    let providerName: String
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                ShellProgressRing(fraction: 0.015, lineWidth: 8, spinning: !reduceMotion)
                    .frame(width: 150, height: 150)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
            }
            Text("Saying hello to \(providerName)…")
                .font(Tuna.Fonts.display(30))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Label("One request at a time · protecting your account", systemImage: "checkmark.shield.fill")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textSecondary)
        }
        .padding(40)
    }
}

// MARK: - Live sync

struct TheaterSyncView: View {
    let progress: SyncProgress
    let kind: ProviderKind
    let reduceMotion: Bool

    @State private var receivedAt = Date()

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 8) {
                    Text("CURATION THEATER")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Tuna.Palette.accent)
                    Text("Building your library")
                        .font(Tuna.Fonts.display(38))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text(headline)
                        .font(Tuna.Fonts.bodyLarge)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .contentTransition(.opacity)
                        .animation(Tuna.Motion.snappy, value: headline)
                }
                .multilineTextAlignment(.center)

                HStack(alignment: .center, spacing: 44) {
                    ring
                    VStack(alignment: .leading, spacing: 18) {
                        counters
                        TheaterStageList(stages: ShellFormat.stages(for: kind), current: progress.stage, reduceMotion: reduceMotion)
                    }
                }

                TheaterPacingLine(nextRequestIn: progress.nextRequestIn, receivedAt: receivedAt)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: progress) { _, _ in
            receivedAt = Date()
        }
    }

    private var headline: String {
        ShellText.clean(progress.message) ?? ShellFormat.stageLabel(progress.stage)
    }

    private var percent: Int {
        Int((min(1, max(0, progress.fraction)) * 100).rounded())
    }

    private var ring: some View {
        ZStack {
            ShellProgressRing(fraction: progress.fraction, lineWidth: 12, spinning: !reduceMotion)
                .frame(width: 200, height: 200)
            VStack(spacing: 2) {
                Text("\(percent)%")
                    .font(Tuna.Fonts.rounded(46, weight: .heavy))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
                    .animation(Tuna.Motion.snappy, value: percent)
                Text(ShellFormat.stageShortLabel(progress.stage))
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 12) {
            ForEach(counterKeys, id: \.self) { key in
                TheaterCounterTile(label: ShellFormat.countLabel(key),
                                   symbol: ShellFormat.countSymbol(key),
                                   value: progress.counts[key] ?? 0)
            }
        }
    }

    private var counterKeys: [String] {
        let base = [StreamKind.live.rawValue, StreamKind.movie.rawValue, StreamKind.series.rawValue]
        let extra = ShellFormat.orderedKeys(progress.counts).filter { !base.contains($0) }
        return base + extra
    }
}

struct TheaterCounterTile: View {
    let label: String
    let symbol: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textSecondary)
            Text(value, format: .number)
                .font(Tuna.Fonts.rounded(26, weight: .heavy))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(Tuna.Motion.snappy, value: value)
        }
        .padding(14)
        .frame(minWidth: 124, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct TheaterStageList: View {
    let stages: [SyncStage]
    let current: SyncStage
    let reduceMotion: Bool

    private enum StageState { case done, active, pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(stages, id: \.self) { stage in
                HStack(spacing: 9) {
                    icon(for: stage)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                    Text(ShellFormat.stageShortLabel(stage))
                        .font(.system(size: 12.5, weight: state(of: stage) == .active ? .semibold : .regular))
                        .foregroundStyle(state(of: stage) == .pending ? Tuna.Palette.textTertiary : Tuna.Palette.textPrimary)
                }
            }
        }
        .animation(Tuna.Motion.snappy, value: current)
    }

    private func state(of stage: SyncStage) -> StageState {
        let all = SyncStage.allCases
        guard let index = all.firstIndex(of: stage), let currentIndex = all.firstIndex(of: current) else { return .pending }
        if current == .done || index < currentIndex { return .done }
        if index == currentIndex { return .active }
        return .pending
    }

    @ViewBuilder
    private func icon(for stage: SyncStage) -> some View {
        switch state(of: stage) {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tuna.Palette.success)
        case .active:
            Image(systemName: "circle.dotted")
                .foregroundStyle(Tuna.Palette.accentCool)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
    }
}

/// "next request in 1.4 s · protecting your account", counting down between progress updates.
struct TheaterPacingLine: View {
    let nextRequestIn: TimeInterval?
    let receivedAt: Date

    var body: some View {
        TimelineView(.periodic(from: receivedAt, by: 0.1)) { context in
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Tuna.Palette.success)
                Text(line(at: context.date))
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func line(at date: Date) -> String {
        guard let wait = nextRequestIn else { return "one request at a time · protecting your account" }
        let remaining = max(0, wait - date.timeIntervalSince(receivedAt))
        if remaining < 0.05 { return "waiting for your provider · protecting your account" }
        return String(format: "next request in %.1f s · protecting your account", remaining)
    }
}

// MARK: - Results

struct TheaterResultsView: View {
    let stats: CurationStats
    let reduceMotion: Bool
    let onStart: () -> Void

    @State private var revealed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                TunaLogoMark(size: 64)
                    .shadow(color: Tuna.Palette.accent.opacity(0.4), radius: 24)
                VStack(spacing: 10) {
                    Text("Your library is ready")
                        .font(Tuna.Fonts.display(44))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    Text("Only the good stuff made the showcase. Everything else is sorted in The Vault.")
                        .font(Tuna.Fonts.bodyLarge)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
                .multilineTextAlignment(.center)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    TheaterStatTile(title: "In your showcase", value: ShellFormat.total(stats.showcaseCounts),
                                    detail: ShellFormat.breakdown(stats.showcaseCounts),
                                    symbol: "sparkles.tv.fill", tint: Tuna.Palette.gold, revealed: revealed)
                    TheaterStatTile(title: "Tucked into The Vault", value: ShellFormat.total(stats.vaultCounts),
                                    detail: "Lower quality, other languages and extras — all still there",
                                    symbol: "shippingbox.fill", tint: Tuna.Palette.hdr, revealed: revealed)
                    TheaterStatTile(title: "Duplicates merged", value: stats.duplicatesMerged,
                                    detail: "Same title, one card — every version kept inside",
                                    symbol: "square.on.square.dashed", tint: Tuna.Palette.accentCool, revealed: revealed)
                    TheaterStatTile(title: "Languages found", value: stats.languageCounts.count,
                                    detail: topLanguages,
                                    symbol: "globe.europe.africa.fill", tint: Tuna.Palette.fhd, revealed: revealed)
                }

                notes

                GlassButton(title: "Start watching", systemImage: "play.fill", style: .primary, action: { onStart() })
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            let animation: Animation = reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 1.1).delay(0.25)
            withAnimation(animation) { revealed = true }
        }
    }

    @ViewBuilder private var notes: some View {
        VStack(spacing: 8) {
            if stats.showcaseRelaxed {
                Label("4K was a little thin in your worlds, so the next quality tier joined the showcase. Change it anytime in Settings.",
                      systemImage: "wand.and.stars")
                    .foregroundStyle(Tuna.Palette.gold)
            }
            if stats.adultHidden > 0 {
                Label("\(stats.adultHidden.formatted()) adult items are hidden and locked away.", systemImage: "lock.fill")
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
        }
        .font(Tuna.Fonts.caption)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "🇬🇧 English · 🇹🇷 Turkish · 🇩🇪 German".
    private var topLanguages: String {
        let top = stats.languageCounts.sorted { $0.value > $1.value }.prefix(3)
        guard !top.isEmpty else { return "Language tags were scarce" }
        let names: [String] = top.map { (entry) -> String in
            let flag = WorldEditing.languageFlag(entry.key)
            let name = WorldEditing.languageEnglishName(entry.key)
            return flag.isEmpty ? name : "\(flag) \(name)"
        }
        return names.joined(separator: " · ")
    }
}

struct TheaterStatTile: View {
    let title: String
    let value: Int
    let detail: String
    let symbol: String
    let tint: Color
    let revealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.15)))
            Text(revealed ? value : 0, format: .number)
                .font(Tuna.Fonts.rounded(34, weight: .heavy))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(revealed ? value : 0)))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(detail)
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Failure

struct TheaterFailureView: View {
    let message: String
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Tuna.Palette.warning)
                .symbolRenderingMode(.hierarchical)
            Text("We paused before finishing")
                .font(Tuna.Fonts.display(34))
                .foregroundStyle(Tuna.Palette.textPrimary)
            Text(message)
                .font(Tuna.Fonts.bodyLarge)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            Label("Nothing was retried automatically — your account is safe.", systemImage: "checkmark.shield.fill")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.success)
            HStack(spacing: 12) {
                GlassButton(title: "Edit provider", systemImage: "pencil", style: .secondary, action: { onEdit() })
                GlassButton(title: "Try again", systemImage: "arrow.clockwise", style: .primary, action: { onRetry() })
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(40)
    }
}
