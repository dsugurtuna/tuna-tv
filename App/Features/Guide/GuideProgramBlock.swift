import SwiftUI
import TunaCore

// =====================================================================================================
// TV GUIDE PROGRAMME BLOCK. Width = minutes × 6 pt. Category tint stripe, title + time; the current
// programme is highlighted with a progress fill up to the "now" line; live events carry the LIVE badge;
// past programmes are dimmed and, when the channel has catch-up and the programme is archived, show a
// rewind glyph. Click: current → watch live · past with archive → catch-up · otherwise → details popover.
// =====================================================================================================

struct TVGuideProgramBlock: View {
    let program: Program
    let channel: Channel
    let now: Date
    let width: CGFloat
    /// x of the "now" line relative to this block's leading edge.
    let nowOffset: CGFloat
    let model: AppModel

    @State private var isHovering = false
    @State private var showsDetails = false

    init(program: Program, channel: Channel, now: Date, width: CGFloat, nowOffset: CGFloat, model: AppModel) {
        self.program = program
        self.channel = channel
        self.now = now
        self.width = width
        self.nowOffset = nowOffset
        self.model = model
    }

    private enum Phase { case past, current, future }

    private var phase: Phase {
        if program.end <= now { return .past }
        if program.start <= now { return .current }
        return .future
    }

    private var canCatchUp: Bool { channel.catchupDays != nil && program.hasArchive }

    private var height: CGFloat { TVGuideLayout.rowHeight - TVGuideLayout.blockInset * 2 }

    var body: some View {
        Button(action: activate) {
            content
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            TVGuideProgramDetails(program: program,
                                  channel: channel,
                                  now: now,
                                  canCatchUp: canCatchUp,
                                  onWatch: watchLive,
                                  onCatchUp: watchCatchUp)
        }
        .contextMenu { menuItems }
        .help(program.title + "\n" + LiveTVFormat.timeRange(program))
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Actions

    private func activate() {
        switch phase {
        case .current:
            model.play(channel)
        case .past:
            if canCatchUp {
                model.playCatchup(program, on: channel)
            } else {
                showsDetails = true
            }
        case .future:
            showsDetails = true
        }
    }

    private func watchLive() {
        showsDetails = false
        model.play(channel)
    }

    private func watchCatchUp() {
        showsDetails = false
        model.playCatchup(program, on: channel)
    }

    @ViewBuilder
    private var menuItems: some View {
        if phase != .past {
            Button {
                model.play(channel)
            } label: {
                Label("Watch \(channel.name)", systemImage: "play.fill")
            }
        }
        if canCatchUp && phase != .future {
            Button {
                model.playCatchup(program, on: channel)
            } label: {
                Label(phase == .past ? "Watch Replay" : "Watch from the Start", systemImage: "gobackward")
            }
        }
        Button {
            showsDetails = true
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        Divider()
        Button {
            model.toggleFavorite(channel)
        } label: {
            if model.isFavorite(channel) {
                Label("Remove \(channel.name) from Favorites", systemImage: "star.slash")
            } else {
                Label("Add \(channel.name) to Favorites", systemImage: "star")
            }
        }
    }

    // MARK: Appearance

    private var content: some View {
        let tint = LiveTVFormat.tint(for: program, channel: channel)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(fill(tint))
            if phase == .current {
                Rectangle()
                    .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.34)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: min(max(nowOffset, 0), width))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(shape)
            }
            shape.strokeBorder(stroke(tint), lineWidth: phase == .current ? 1.5 : 1)
            Capsule()
                .fill(tint.opacity(phase == .past ? 0.5 : 1))
                .frame(width: 3)
                .padding(.vertical, 11)
                .padding(.leading, 5)
            if width >= 46 {
                labels
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
            }
            if isHovering && width >= 84 {
                Image(systemName: hoverSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
        .opacity(phase == .past ? 0.55 : 1)
        .contentShape(shape)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if program.isLive && phase != .past {
                    LiveBadge(compact: true)
                }
                if phase == .past && canCatchUp {
                    Image(systemName: "gobackward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tuna.Palette.accentCool)
                }
                if program.isNew && phase == .future {
                    Text("NEW")
                        .font(Tuna.Fonts.micro)
                        .foregroundStyle(Tuna.Palette.gold)
                }
                Text(program.title)
                    .font(.system(size: 13, weight: phase == .current ? .bold : .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
            }
            if width >= 96 {
                Text(timeLine)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(phase == .current ? Tuna.Palette.textSecondary : Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeLine: String {
        let range = LiveTVFormat.timeRange(program)
        switch phase {
        case .current:
            return range + " · " + LiveTVFormat.remaining(program, at: now)
        case .past:
            return canCatchUp ? range + " · Replay" : range
        case .future:
            if let episode = program.episodeLabel?.nonEmpty { return range + " · " + episode }
            return range
        }
    }

    private var hoverSymbol: String {
        switch phase {
        case .current: return "play.fill"
        case .past: return canCatchUp ? "gobackward" : "info.circle"
        case .future: return "info.circle"
        }
    }

    private func fill(_ tint: Color) -> Color {
        switch phase {
        case .current: return tint.opacity(isHovering ? 0.3 : 0.2)
        case .past: return Color.white.opacity(isHovering ? 0.08 : 0.045)
        case .future: return Color.white.opacity(isHovering ? 0.11 : 0.065)
        }
    }

    private func stroke(_ tint: Color) -> Color {
        switch phase {
        case .current: return tint.opacity(0.85)
        case .past, .future: return isHovering ? tint.opacity(0.6) : Tuna.Palette.stroke
        }
    }

    private var spokenLabel: String {
        var text = program.title + ", " + LiveTVFormat.timeRange(program)
        switch phase {
        case .current: text += ", on now"
        case .past: text += canCatchUp ? ", replay available" : ", ended"
        case .future: text += ", " + LiveTVFormat.startsIn(program, at: now)
        }
        return text
    }
}

// MARK: - Details popover

private struct TVGuideProgramDetails: View {
    let program: Program
    let channel: Channel
    let now: Date
    let canCatchUp: Bool
    let onWatch: () -> Void
    let onCatchUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LiveTVChannelLogo(channel: channel, width: 46, height: 32, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                    Text(whenLine)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if program.isLive {
                    LiveBadge(compact: true)
                }
            }
            Text(program.title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = subtitleLine {
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            if !program.categories.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(program.categories.prefix(4).enumerated()), id: \.offset) { _, category in
                        Text(category)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LiveTVFormat.tint(for: program, channel: channel))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                }
            }
            if let summary = program.summary?.nonEmpty {
                Text(summary)
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(Tuna.Palette.surfaceElevated)
        .environment(\.colorScheme, .dark)
    }

    private var whenLine: String {
        let day = LiveTVFormat.day(program.start, relativeTo: now)
        var text = day + " · " + LiveTVFormat.timeRange(program) + " · " + LiveTVFormat.duration(program.duration)
        if program.start > now { text += " · starts " + LiveTVFormat.startsIn(program, at: now) }
        return text
    }

    private var subtitleLine: String? {
        let parts = [program.episodeLabel?.nonEmpty, program.subtitle?.nonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if canCatchUp && program.start <= now {
                GlassButton(title: program.end <= now ? "Watch Replay" : "From the Start",
                            systemImage: "gobackward",
                            style: .primary,
                            action: onCatchUp)
            }
            if program.end > now {
                GlassButton(title: program.start <= now ? "Watch Live" : "Watch Channel Now",
                            systemImage: "play.fill",
                            style: program.start <= now ? .primary : .secondary,
                            action: onWatch)
            }
        }
        .padding(.top, 2)
    }
}
