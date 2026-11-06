import SwiftUI
import TunaCore

// =====================================================================================================
// TV GUIDE TIMELINE. One 2D ScrollView holds a LazyVStack whose pinned section header is the time ruler,
// so the ruler and the programme rows share the same horizontal scroll and the ruler sticks to the top.
// The channel column (and the ruler's corner) stay glued to the leading edge with a render-time offset
// (`visualEffect`), which costs no layout pass while scrolling. Rows are lazy: programmes are fetched only
// for the rows on screen and only inside the window (now − 2 h … now + 12 h).
// =====================================================================================================

enum TVGuideLayout {
    /// Width of one minute of programme time.
    static let pointsPerMinute: CGFloat = 6
    static let channelColumnWidth: CGFloat = 220
    static let rowHeight: CGFloat = 68
    static let rulerHeight: CGFloat = 46
    static let blockInset: CGFloat = 3
    /// The guide opens (and "Now" jumps) with this much past time visible before now.
    static let leadIn: TimeInterval = 30 * 60
    static let nowAnchorID = "tv-guide.now-anchor"
}

// MARK: - Window

/// The visible time range: from the half hour two hours before now to twelve and a half hours later.
struct TVGuideWindow: Equatable {
    let start: Date
    let end: Date

    init(around now: Date) {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        parts.minute = (parts.minute ?? 0) < 30 ? 0 : 30
        parts.second = 0
        let halfHour = calendar.date(from: parts) ?? now
        start = halfHour.addingTimeInterval(-2 * 3600)
        end = halfHour.addingTimeInterval(12 * 3600 + 1800)
    }

    var interval: DateInterval { DateInterval(start: start, end: end) }

    var width: CGFloat { x(for: end) }

    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * TVGuideLayout.pointsPerMinute
    }

    func contains(_ date: Date) -> Bool { date >= start && date <= end }

    /// Leading x and width of a programme clipped to the window, nil when it is outside.
    func span(of program: Program) -> (x: CGFloat, width: CGFloat)? {
        let from = max(program.start, start)
        let to = min(program.end, end)
        guard to > from else { return nil }
        let leading = x(for: from)
        return (leading, x(for: to) - leading)
    }

    /// 30-minute ticks.
    var ticks: [TVGuideTick] {
        let calendar = Calendar.current
        var result: [TVGuideTick] = []
        var date = start
        var index = 0
        while date < end {
            let minute = calendar.component(.minute, from: date)
            let hour = calendar.component(.hour, from: date)
            result.append(TVGuideTick(id: index, date: date, x: x(for: date),
                                      isHour: minute == 0, isMidnight: minute == 0 && hour == 0))
            date = date.addingTimeInterval(1800)
            index += 1
        }
        return result
    }
}

struct TVGuideTick: Identifiable {
    let id: Int
    let date: Date
    let x: CGFloat
    let isHour: Bool
    let isMidnight: Bool
}

// MARK: - Grid

struct TVGuideGrid: View {
    let channels: [Channel]
    let window: TVGuideWindow
    /// Incremented by the "Now" button.
    let nowRequest: Int
    let reduceMotion: Bool

    init(channels: [Channel], window: TVGuideWindow, nowRequest: Int, reduceMotion: Bool) {
        self.channels = channels
        self.window = window
        self.nowRequest = nowRequest
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    TVGuideGridContent(channels: channels, window: window, now: context.date)
                }
            }
            .scrollIndicators(.automatic)
            .task {
                // Give the lazy stack one layout pass, then park "now − 30 min" next to the channel column.
                try? await Task.sleep(for: .milliseconds(20))
                jumpToNow(proxy, animated: false)
                try? await Task.sleep(for: .milliseconds(180))
                jumpToNow(proxy, animated: false)
            }
            .onChange(of: nowRequest) { _, _ in
                jumpToNow(proxy, animated: true)
            }
        }
    }

    private func jumpToNow(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(Tuna.Motion.page) {
                proxy.scrollTo(TVGuideLayout.nowAnchorID, anchor: .topLeading)
            }
        } else {
            proxy.scrollTo(TVGuideLayout.nowAnchorID, anchor: .topLeading)
        }
    }
}

private struct TVGuideGridContent: View {
    let channels: [Channel]
    let window: TVGuideWindow
    let now: Date

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(channels) { channel in
                    TVGuideRow(channel: channel, window: window, now: now)
                }
            } header: {
                TVGuideHeaderRow(window: window, now: now)
            }
        }
        .padding(.bottom, 28)
    }
}

private extension View {
    /// Keeps the view on the leading edge of the enclosing scroll view while the content scrolls
    /// horizontally (render-time offset: no layout pass per frame).
    func tvGuideStickyLeading() -> some View {
        visualEffect { content, geometry in
            content.offset(x: max(0, -geometry.frame(in: .scrollView).minX))
        }
    }
}

// MARK: - Header row (corner + ruler)

private struct TVGuideHeaderRow: View {
    let window: TVGuideWindow
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            corner
                .frame(width: TVGuideLayout.channelColumnWidth, height: TVGuideLayout.rulerHeight)
                .background(Tuna.Palette.surface)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Tuna.Palette.strokeStrong).frame(width: 1)
                }
                .tvGuideStickyLeading()
                .zIndex(2)
            TVGuideRuler(window: window, now: now)
        }
        .background(Tuna.Palette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tuna.Palette.strokeStrong).frame(height: 1)
        }
    }

    private var corner: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
                .foregroundStyle(Tuna.Palette.textTertiary)
            Text(LiveTVFormat.day(now, relativeTo: now))
                .foregroundStyle(Tuna.Palette.textSecondary)
            Spacer(minLength: 4)
            Text(LiveTVFormat.clock(now))
                .monospacedDigit()
                .foregroundStyle(Tuna.Palette.live)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
    }
}

private struct TVGuideRuler: View {
    let window: TVGuideWindow
    let now: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(window.ticks) { tick in
                TVGuideTickMark(tick: tick)
                    .offset(x: tick.x)
            }
            if window.contains(now) {
                nowMarker
            }
            scrollAnchor
        }
        .frame(width: window.width, height: TVGuideLayout.rulerHeight, alignment: .topLeading)
        .clipped()
    }

    private var nowX: CGFloat { window.x(for: now) }

    private var nowMarker: some View {
        VStack(spacing: 0) {
            Text(LiveTVFormat.clock(now))
                .font(.system(size: 10, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Tuna.Palette.live))
                .padding(.top, 6)
            Rectangle()
                .fill(Tuna.Palette.live)
                .frame(width: 2)
        }
        .frame(width: 72, height: TVGuideLayout.rulerHeight)
        .offset(x: nowX - 36)
        .allowsHitTesting(false)
    }

    /// Invisible view the grid scrolls to: laid out (not offset) so that aligning it with the leading edge
    /// shows "now − 30 min" right after the sticky channel column.
    private var scrollAnchor: some View {
        let target = window.x(for: now.addingTimeInterval(-TVGuideLayout.leadIn))
        let lead = max(0, target - TVGuideLayout.channelColumnWidth)
        return HStack(spacing: 0) {
            Color.clear.frame(width: lead, height: 1)
            Color.clear.frame(width: 1, height: 1).id(TVGuideLayout.nowAnchorID)
        }
        .allowsHitTesting(false)
    }
}

private struct TVGuideTickMark: View {
    let tick: TVGuideTick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if tick.isMidnight {
                    Text(tick.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Tuna.Palette.accent)
                }
                Text(LiveTVFormat.clock(tick.date))
                    .font(.system(size: tick.isHour ? 12 : 11, weight: tick.isHour ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(tick.isHour ? Tuna.Palette.textSecondary : Tuna.Palette.textTertiary)
            }
            .padding(.leading, 7)
            .padding(.top, 10)
            Spacer(minLength: 0)
            Rectangle()
                .fill(tick.isHour ? Tuna.Palette.strokeStrong : Tuna.Palette.stroke)
                .frame(width: 1, height: tick.isHour ? 14 : 8)
        }
        .frame(height: TVGuideLayout.rulerHeight, alignment: .leading)
    }
}

// MARK: - Rows

private struct TVGuideRow: View {
    let channel: Channel
    let window: TVGuideWindow
    let now: Date

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            TVGuideChannelCell(channel: channel,
                               isPlaying: LiveTVFormat.playingChannelID(model.player.content) == channel.id,
                               isFavorite: model.isFavorite(channel),
                               model: model)
                .frame(width: TVGuideLayout.channelColumnWidth, height: TVGuideLayout.rowHeight)
                .tvGuideStickyLeading()
                .zIndex(2)
            TVGuideProgramLane(channel: channel, programs: programs, window: window, now: now, model: model)
        }
        .frame(height: TVGuideLayout.rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tuna.Palette.stroke).frame(height: 1)
        }
    }

    /// Only this channel, only this window; duplicates (same start) from messy guides are dropped.
    private var programs: [Program] {
        var seen = Set<String>()
        return model.programs(on: channel, in: window.interval).filter { program in
            program.end > window.start && program.start < window.end && seen.insert(program.id).inserted
        }
    }
}

private struct TVGuideChannelCell: View {
    let channel: Channel
    let isPlaying: Bool
    let isFavorite: Bool
    let model: AppModel

    @State private var isHovering = false

    var body: some View {
        Button {
            model.play(channel)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            LiveTVChannelMenu(channel: channel, model: model, includeGuide: false)
        }
        .help("Watch " + channel.name)
    }

    private var label: some View {
        HStack(spacing: 10) {
            LiveTVChannelLogo(channel: channel, width: 54, height: 38, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let number = channel.number {
                        Text(String(number))
                            .font(Tuna.Fonts.monoSmall)
                            .foregroundStyle(Tuna.Palette.textTertiary)
                    }
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Tuna.Palette.gold)
                    }
                    if channel.catchupDays != nil {
                        Image(systemName: "gobackward")
                            .foregroundStyle(Tuna.Palette.accentCool)
                            .help("Replay available")
                    }
                }
                .font(.system(size: 9, weight: .bold))
                Text(channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tuna.Palette.accent)
            } else if isHovering {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Tuna.Palette.strokeStrong).frame(width: 1)
        }
        .contentShape(Rectangle())
    }

    /// Opaque, because programme blocks scroll underneath the sticky column.
    private var background: some View {
        ZStack {
            Tuna.Palette.surface
            if isPlaying {
                Tuna.Palette.accent.opacity(0.12)
            } else if isHovering {
                Color.white.opacity(0.04)
            }
        }
    }
}

private struct TVGuideProgramLane: View {
    let channel: Channel
    let programs: [Program]
    let window: TVGuideWindow
    let now: Date
    let model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            pastShade
            if programs.isEmpty {
                placeholder
            } else {
                ForEach(programs) { program in
                    block(for: program)
                }
            }
            if window.contains(now) {
                Rectangle()
                    .fill(Tuna.Palette.live)
                    .frame(width: 2, height: TVGuideLayout.rowHeight)
                    .offset(x: nowX - 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: window.width, height: TVGuideLayout.rowHeight, alignment: .topLeading)
    }

    private var nowX: CGFloat { min(max(window.x(for: now), 0), window.width) }

    @ViewBuilder
    private func block(for program: Program) -> some View {
        if let span = window.span(of: program) {
            let inset = TVGuideLayout.blockInset
            TVGuideProgramBlock(program: program,
                                channel: channel,
                                now: now,
                                width: max(span.width - inset * 2, 2),
                                nowOffset: nowX - span.x - inset,
                                model: model)
                .offset(x: span.x + inset, y: inset)
        }
    }

    /// Slightly darker past so "now" reads at a glance even between programmes.
    private var pastShade: some View {
        Rectangle()
            .fill(Color.black.opacity(0.16))
            .frame(width: nowX, height: TVGuideLayout.rowHeight)
            .allowsHitTesting(false)
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
            Text("No programme information")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Tuna.Palette.textTertiary)
        .frame(height: TVGuideLayout.rowHeight)
        .offset(x: max(0, nowX + 16))
        .allowsHitTesting(false)
    }
}
