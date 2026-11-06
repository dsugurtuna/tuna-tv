import SwiftUI
import CoreGraphics

/// Host-drawn subtitles (the engine draws none on its loopback/software routes). Cues come from the engine
/// already matched against `clock.sourceTime`; text cues get a soft outline shadow, bitmap cues (PGS/DVB) are
/// placed on the aspect-fit picture rectangle the way the disc authored them.
struct SubtitleOverlay: View {
    let player: PlayerModel
    /// Raise bottom subtitles above the control bar while it is visible.
    var liftedForControls: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let video = PlayerGeometry.videoRect(in: geometry.size, aspect: player.videoAspect)
            ZStack(alignment: .topLeading) {
                ForEach(bitmapCues) { cue in
                    SubtitleBitmapView(cue: cue, video: video)
                }
                if !bottomTexts.isEmpty {
                    SubtitleTextBlock(lines: bottomTexts, video: video, atTop: false,
                                      extraInset: liftedForControls ? 120 : 0)
                }
                if !topTexts.isEmpty {
                    SubtitleTextBlock(lines: topTexts, video: video, atTop: true, extraInset: 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.25), value: liftedForControls)
        }
        .allowsHitTesting(false)
    }

    private var bitmapCues: [PlayerSubtitleCue] {
        player.subtitleCues.filter { $0.isBitmap }
    }

    private var bottomTexts: [PlayerSubtitleLine] {
        let lines = player.subtitleCues.filter { !$0.isBitmap && !$0.prefersTop }.compactMap { cue in
            cue.text.map { PlayerSubtitleLine(id: cue.id, text: $0) }
        }
        if lines.isEmpty, player.subtitleCues.isEmpty, let text = player.subtitleText, !text.isEmpty {
            return [PlayerSubtitleLine(id: -1, text: text)]
        }
        return lines
    }

    private var topTexts: [PlayerSubtitleLine] {
        player.subtitleCues.filter { !$0.isBitmap && $0.prefersTop }.compactMap { cue in
            cue.text.map { PlayerSubtitleLine(id: cue.id, text: $0) }
        }
    }
}

struct PlayerSubtitleLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Text cues, centred at the bottom (or top) of the picture.
private struct SubtitleTextBlock: View {
    let lines: [PlayerSubtitleLine]
    let video: CGRect
    let atTop: Bool
    let extraInset: CGFloat

    var body: some View {
        let fontSize = min(46, max(15, video.height * 0.047))
        let edgeInset = video.height * 0.06
        VStack(spacing: fontSize * 0.15) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: Color.black.opacity(0.95), radius: 1.2, x: 0, y: 1)
                    .shadow(color: Color.black.opacity(0.7), radius: 6, x: 0, y: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: video.width * 0.86)
        .padding(atTop ? .top : .bottom, edgeInset + extraInset)
        .frame(width: video.width, height: video.height, alignment: atTop ? .top : .bottom)
        .offset(x: video.minX, y: video.minY)
    }
}

/// One bitmap cue at its authored position.
private struct SubtitleBitmapView: View {
    let cue: PlayerSubtitleCue
    let video: CGRect

    var body: some View {
        switch cue.body {
        case .bitmap(let image, let rect, let canvas):
            let frame = PlayerGeometry.bitmapFrame(rect: rect, canvas: canvas, video: video)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .position(x: frame.midX, y: frame.midY)
        case .text:
            EmptyView()
        }
    }
}
