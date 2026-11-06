import SwiftUI
import TunaCore

// =====================================================================================================
// "ON NOW" HERO STRIP. Large cards for live sports / news / premiere events happening right now
// (AppModel.liveEvents): programme title, channel logo + name, LIVE badge, time left, progress and the
// sport kind. Click plays the channel (the player debounces zaps). Hidden by the caller when empty.
// =====================================================================================================

struct LiveOnNowStrip: View {
    let events: [LiveTVEvent]
    let now: Date

    @Environment(AppModel.self) private var model

    init(events: [LiveTVEvent], now: Date) {
        self.events = events
        self.now = now
    }

    var body: some View {
        RailScroller(title: "On Now", subtitle: subtitle) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                LiveEventCard(event: event, now: now, model: model)
                    .staggeredAppear(index: index)
            }
        }
    }

    private var subtitle: String {
        events.count == 1 ? "1 live event right now" : "\(events.count) live events right now"
    }
}

private struct LiveEventCard: View {
    let event: LiveTVEvent
    let now: Date
    let model: AppModel

    @State private var isHovering = false

    private static let width: CGFloat = 384
    private static let height: CGFloat = 216
    private static let radius: CGFloat = Tuna.Metrics.cardRadius + 4

    var body: some View {
        Button {
            model.play(event.channel)
        } label: {
            card
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.04)
        .onHover { isHovering = $0 }
        .contextMenu {
            LiveTVChannelMenu(channel: event.channel, model: model)
        }
        .help(event.program.title + " — " + event.channel.name)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        event.program.title + ", live on " + event.channel.name + ", " + LiveTVFormat.remaining(event.program, at: now)
    }

    private var tint: Color { LiveTVFormat.tint(for: event.program, channel: event.channel) }

    private var sportsKind: String? { LiveEventDetector.sportsKind(event.program) }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: LiveEventCard.radius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            artwork
                .frame(width: LiveEventCard.width, height: LiveEventCard.height)
                .clipped()
            LinearGradient(colors: [tint.opacity(0.42), Color.clear],
                           startPoint: .topLeading, endPoint: .center)
            LinearGradient(stops: [
                .init(color: Color.black.opacity(0.15), location: 0),
                .init(color: Color.black.opacity(0.35), location: 0.45),
                .init(color: Color.black.opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            details
                .padding(16)
                .frame(width: LiveEventCard.width, height: LiveEventCard.height, alignment: .topLeading)
        }
        .frame(width: LiveEventCard.width, height: LiveEventCard.height)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(isHovering ? Tuna.Palette.live.opacity(0.65) : Tuna.Palette.stroke,
                               lineWidth: isHovering ? 1.5 : 1)
        )
        .contentShape(shape)
    }

    @ViewBuilder
    private var artwork: some View {
        if let icon = event.program.iconURL {
            TunaImage(url: icon, kind: .still, seed: event.program.id, title: event.program.title)
        } else {
            TunaImage(url: nil, kind: .backdrop, seed: event.channel.id + event.program.title, title: event.program.title)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                LiveBadge()
                if let kind = sportsKind {
                    sportChip(kind)
                }
                Spacer(minLength: 0)
                LiveTVChannelLogo(channel: event.channel, width: 50, height: 34, cornerRadius: 8)
            }
            Spacer(minLength: 0)
            Text(event.program.title)
                .font(Tuna.Fonts.display(23, weight: .heavy))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.black.opacity(0.55), radius: 6, x: 0, y: 2)
            HStack(spacing: 6) {
                Text(event.channel.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("·")
                Text(LiveTVFormat.remaining(event.program, at: now))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .opacity(isHovering ? 1 : 0)
            }
            .font(Tuna.Fonts.caption)
            .foregroundStyle(Color.white.opacity(0.86))
            ProgressLine(fraction: event.program.progress(at: now), tint: Tuna.Palette.live, height: 3)
        }
    }

    private func sportChip(_ kind: String) -> some View {
        Label(kind, systemImage: LiveTVFormat.sportSymbol(for: kind))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
