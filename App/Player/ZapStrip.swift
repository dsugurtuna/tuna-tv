import SwiftUI
import TunaCore

/// Live zapping strip (↑/↓): channel logos around the current channel with what is on air. The pending
/// (debounced) selection is highlighted; only the last one opens a stream.
struct ZapStrip: View {
    let player: PlayerModel
    let app: AppModel

    var body: some View {
        let items = visibleItems
        HStack(spacing: 12) {
            ForEach(items) { item in
                ZapStripTile(channel: item.channel,
                             programme: app.nowPlaying(on: item.channel),
                             isFocused: item.channel.id == focusID,
                             isPlaying: item.channel.id == playingID && player.status.isActive) {
                    player.zap(to: item.channel)
                }
            }
        }
        .padding(14)
        .tunaGlass(cornerRadius: 24)
        .animation(Tuna.Motion.snappy, value: focusID)
    }

    private var focusID: String? { (player.pendingZap ?? player.currentChannel)?.id }

    private var playingID: String? { player.currentChannel?.id }

    /// Up to seven channels centred on the focused one (wrapping around the list).
    private var visibleItems: [ZapStripItem] {
        let list = player.zapChannels
        guard !list.isEmpty else {
            if let current = player.currentChannel { return [ZapStripItem(id: 0, channel: current)] }
            return []
        }
        let span = min(7, list.count)
        guard list.count > span else {
            return list.enumerated().map { ZapStripItem(id: $0.offset, channel: $0.element) }
        }
        let center = focusID.flatMap { id in list.firstIndex(where: { $0.id == id }) } ?? 0
        let half = span / 2
        return (0..<span).map { slot in
            let index = ((center - half + slot) % list.count + list.count) % list.count
            return ZapStripItem(id: slot, channel: list[index])
        }
    }
}

struct ZapStripItem: Identifiable {
    let id: Int
    let channel: Channel
}

struct ZapStripTile: View {
    let channel: Channel
    let programme: Program?
    let isFocused: Bool
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    TunaImage(url: channel.logoURL, kind: .channel, seed: channel.id, title: channel.name, contentMode: .fit)
                        .frame(width: 132, height: 74)
                        .background(Tuna.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if isPlaying {
                        LiveBadge(compact: true)
                            .padding(6)
                    }
                }
                Text(title)
                    .font(Tuna.Fonts.cardTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                Text(programme?.title ?? " ")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(1)
                ProgressLine(fraction: programme?.progress(at: Date()) ?? 0, tint: Tuna.Palette.live, height: 2)
                    .opacity(programme == nil ? 0 : 1)
            }
            .frame(width: 132)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Tuna.Palette.accent.opacity(0.22) : Color.white.opacity(hovering ? 0.08 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? Tuna.Palette.accent : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.06 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tuna.Motion.snappy, value: isFocused)
    }

    private var title: String {
        if let number = channel.number { return "\(number)  \(channel.name)" }
        return channel.name
    }
}
