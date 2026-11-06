import SwiftUI
import TunaCore

/// "Up Next" card near the end of an episode. With autoplay on it counts down
/// (settings.playback.upNextCountdown) and then plays the next episode; Cancel keeps watching the credits.
struct UpNextCard: View {
    let next: PlayerModel.UpNext
    /// Seconds left before autoplay; nil when autoplay is off.
    let countdown: Int?
    let total: Int
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                TunaImage(url: next.episode.stillURL ?? next.title.backdropURL,
                          kind: .still,
                          seed: next.episode.id,
                          title: next.episode.title,
                          contentMode: .fill)
                    .frame(width: 176, height: 99)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Color.black.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let countdown {
                    UpNextCountdownRing(remaining: countdown, total: total)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 176, height: 99)

            VStack(alignment: .leading, spacing: 5) {
                Text("UP NEXT")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Tuna.Palette.accent)
                Text("S\(next.episode.season) · E\(next.episode.episode)")
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                Text(next.episode.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    PlayerCardButton(title: countdown.map { "Play in \($0)" } ?? "Play next",
                                     systemImage: "play.fill", prominent: true, action: onPlay)
                    PlayerCardButton(title: "Cancel", systemImage: nil, prominent: false, action: onCancel)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 250, alignment: .leading)
        }
        .padding(14)
        .tunaGlass(cornerRadius: 20)
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }
}

/// Countdown ring with the seconds left.
struct UpNextCountdownRing: View {
    let remaining: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, Double(remaining) / Double(max(1, total))))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: remaining)
            Text("\(remaining)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .monospacedDigit()
        }
        .frame(width: 52, height: 52)
    }
}
