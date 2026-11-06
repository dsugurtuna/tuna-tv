import SwiftUI
import TunaCore

/// The "Provider Shield": tiny status capsule (green shield = healthy, amber = pacing, red = paused) with a
/// popover showing requests today, next allowed request, recent request log and connection usage.
struct ProviderShieldView: View {
    var status: [ProviderStatus]

    @State private var isPresented = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            DSShieldCapsule(state: DSShieldState.evaluate(status, now: context.date), isPresented: $isPresented)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DSShieldPopover(status: status)
        }
    }
}

enum DSShieldState: Equatable {
    case idle, healthy, pacing, paused

    static func evaluate(_ status: [ProviderStatus], now: Date) -> DSShieldState {
        guard !status.isEmpty else { return .idle }
        var pacing = false
        for item in status {
            guard let shield = item.shield else { continue }
            switch shield.breaker {
            case .open, .authBlocked: return .paused
            case .closed: break
            }
            if shield.inFlight > 0 || shield.queued > 0 { pacing = true }
            if let next = shield.nextAllowedAt, next > now { pacing = true }
            if let last = shield.lastRequestAt, now.timeIntervalSince(last) < 20 { pacing = true }
            if shield.dailySoftBudget > 0, shield.requestsToday >= shield.dailySoftBudget { pacing = true }
        }
        return pacing ? .pacing : .healthy
    }

    var symbol: String {
        switch self {
        case .idle: return "shield"
        case .healthy: return "checkmark.shield.fill"
        case .pacing: return "clock.fill"
        case .paused: return "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return Tuna.Palette.textTertiary
        case .healthy: return Tuna.Palette.success
        case .pacing: return Tuna.Palette.warning
        case .paused: return Tuna.Palette.danger
        }
    }

    var label: String {
        switch self {
        case .idle: return "Shield"
        case .healthy: return "Protected"
        case .pacing: return "Pacing"
        case .paused: return "Paused"
        }
    }

    var sentence: String {
        switch self {
        case .idle: return "No provider connected yet."
        case .healthy: return "All quiet. Your provider sees a calm, well-behaved client."
        case .pacing: return "Requests are being spaced out right now."
        case .paused: return "Requests are paused to protect your account."
        }
    }
}

private struct DSShieldCapsule: View {
    var state: DSShieldState
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isHovering = false

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(state.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .pacing && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                Text(state.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .tunaGlass(cornerRadius: 14, tint: state == .healthy || state == .idle ? nil : state.color)
            .overlay { Capsule().strokeBorder(state.color.opacity(isHovering ? 0.55 : 0.25), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in isHovering = inside }
        .help("Provider Shield")
        .accessibilityLabel(Text("Provider Shield: " + state.label))
    }
}

private struct DSShieldPopover: View {
    var status: [ProviderStatus]

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = DSShieldState.evaluate(status, now: context.date)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(state.color)
                        .frame(width: 44, height: 44)
                        .background(state.color.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Provider Shield")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Tuna.Palette.textPrimary)
                        Text(state.sentence)
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !status.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(status) { item in
                                DSShieldProviderSection(item: item, now: context.date) {
                                    reset(item.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 460)
                }
                Rectangle().fill(Tuna.Palette.stroke).frame(height: 1)
                Text("Tuna TV talks to your provider gently: one request at a time, never more than one stream.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 400)
        }
        .background(Tuna.Palette.surface)
        .preferredColorScheme(.dark)
    }

    private func reset(_ id: ProviderID) {
        guard let model else { return }
        Task { await model.resetShield(for: id) }
    }
}

private struct DSShieldProviderSection: View {
    var item: ProviderStatus
    var now: Date
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(item.config.name)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                breakerPill
            }
            if let accountLine {
                DSShieldRow(symbol: "person.crop.circle", text: accountLine)
            }
            DSShieldRow(symbol: "antenna.radiowaves.left.and.right", text: connectionsLine)
            if let shield = item.shield {
                requestsBlock(shield)
                if let next = shield.nextAllowedAt, next > now {
                    DSShieldRow(symbol: "clock", text: "Next request in " + DSDuration.clock(seconds: next.timeIntervalSince(now)))
                }
                breakerDetail(shield.breaker)
                logBlock(shield)
            } else {
                DSShieldRow(symbol: "moon.zzz", text: "No requests yet this session.")
            }
            if let error = item.lastError, !error.isEmpty {
                DSShieldRow(symbol: "exclamationmark.triangle", text: error, tint: Tuna.Palette.warning)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tuna.Palette.stroke, lineWidth: 1) }
    }

    @ViewBuilder
    private var breakerPill: some View {
        let breaker = item.shield?.breaker ?? .closed
        let info = DSShieldProviderSection.breakerSummary(breaker)
        Text(info.text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(info.color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(info.color.opacity(0.15), in: Capsule())
    }

    static func breakerSummary(_ breaker: BreakerState) -> (text: String, color: Color) {
        switch breaker {
        case .closed: return ("HEALTHY", Tuna.Palette.success)
        case .open: return ("PAUSED", Tuna.Palette.danger)
        case .authBlocked: return ("LOGIN REFUSED", Tuna.Palette.danger)
        }
    }

    @ViewBuilder
    private func breakerDetail(_ breaker: BreakerState) -> some View {
        switch breaker {
        case .closed:
            EmptyView()
        case .open(let until, let reason, let tripCount):
            VStack(alignment: .leading, spacing: 6) {
                DSShieldRow(symbol: "pause.circle.fill",
                            text: "Paused · " + DSDuration.clock(seconds: until.timeIntervalSince(now)) + " left · trip " + String(tripCount),
                            tint: Tuna.Palette.danger)
                if !reason.isEmpty {
                    DSShieldRow(symbol: "text.bubble", text: reason)
                }
                GlassButton(title: "Try now", systemImage: "arrow.clockwise", style: .secondary, action: onReset)
            }
        case .authBlocked(let reason):
            VStack(alignment: .leading, spacing: 6) {
                DSShieldRow(symbol: "lock.fill", text: "Login refused" + (reason.isEmpty ? "" : " · " + reason),
                            tint: Tuna.Palette.danger)
                GlassButton(title: "Try now", systemImage: "arrow.clockwise", style: .secondary, action: onReset)
            }
        }
    }

    private func requestsBlock(_ shield: GovernorSnapshot) -> some View {
        let budget = max(1, shield.dailySoftBudget)
        let fraction = Double(shield.requestsToday) / Double(budget)
        let tint = fraction >= 1 ? Tuna.Palette.warning : Tuna.Palette.accentCool
        return VStack(alignment: .leading, spacing: 5) {
            DSShieldRow(symbol: "arrow.up.arrow.down",
                        text: String(shield.requestsToday) + " / " + String(shield.dailySoftBudget) + " requests today")
            ProgressLine(fraction: fraction, tint: tint, height: 3)
        }
    }

    @ViewBuilder
    private func logBlock(_ shield: GovernorSnapshot) -> some View {
        let entries = Array(shield.recent.sorted { $0.date > $1.date }.prefix(8))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("RECENT REQUESTS")
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .padding(.top, 2)
                ForEach(entries) { entry in
                    DSShieldLogRow(entry: entry, now: now)
                }
            }
        }
    }

    private var accountLine: String? {
        guard let account = item.account else { return nil }
        var parts: [String] = [account.status ?? (account.isAuthorized ? "Active" : "Not authorized")]
        if account.isTrial { parts.append("Trial") }
        if let expiry = DSShieldProviderSection.expiry(account.expiresAt, now: now) { parts.append(expiry) }
        return parts.joined(separator: " · ")
    }

    private var connectionsLine: String {
        let cap = item.config.effectiveMaxStreams(account: item.account)
        let streams = "Tuna TV uses at most " + String(cap) + (cap == 1 ? " stream" : " streams")
        guard let account = item.account, let maxConnections = account.maxConnections else { return streams }
        let active = account.activeConnections.map { String($0) } ?? "–"
        return active + " / " + String(maxConnections) + " connections · " + streams
    }

    static func expiry(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        let days = Int(seconds / 86_400)
        if days >= 2 { return "Expires in \(days) days" }
        let hours = Int(seconds / 3600)
        if hours >= 1 { return "Expires in \(hours) h" }
        return "Expires in \(max(1, Int(seconds / 60))) min"
    }
}

private struct DSShieldRow: View {
    var symbol: String
    var text: String
    var tint: Color = Tuna.Palette.textSecondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DSShieldLogRow: View {
    var entry: RequestLogEntry
    var now: Date

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(entry.purpose)
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(statusText)
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(dotColor)
            Text(String(entry.durationMs) + " ms")
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(Tuna.Palette.textTertiary)
                .frame(width: 58, alignment: .trailing)
            Text(ago)
                .font(Tuna.Fonts.monoSmall)
                .foregroundStyle(Tuna.Palette.textTertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var statusText: String {
        if let status = entry.status { return String(status) }
        return entry.outcome
    }

    private var dotColor: Color {
        guard let status = entry.status else { return Tuna.Palette.warning }
        if (200..<400).contains(status) { return Tuna.Palette.success }
        if (400..<500).contains(status) { return Tuna.Palette.warning }
        return Tuna.Palette.danger
    }

    private var ago: String {
        let seconds = max(0, Int(now.timeIntervalSince(entry.date)))
        if seconds < 60 { return String(seconds) + "s" }
        if seconds < 3600 { return String(seconds / 60) + "m" }
        return String(seconds / 3600) + "h"
    }
}
