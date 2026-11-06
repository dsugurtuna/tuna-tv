import SwiftUI
import TunaCore

/// "Nerd stats" (I): what the engine is actually decoding, plus the Provider Shield connection line.
struct TechPanel: View {
    let player: PlayerModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Stream info", systemImage: "info.circle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Spacer()
                PlayerIconButton(systemImage: "xmark", help: "Close (I)", size: 12, diameter: 26, filled: true) {
                    onClose()
                }
            }
            Divider().overlay(Tuna.Palette.stroke)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.id)
                            .foregroundStyle(Tuna.Palette.textTertiary)
                            .frame(width: 104, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(Tuna.Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Tuna.Fonts.mono)
            Divider().overlay(Tuna.Palette.stroke)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Tuna.Palette.success)
                Text("\(player.connectionsInUse) of \(player.connectionLimit) connections in use")
                    .font(Tuna.Fonts.mono)
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            Text("One engine, one connection, no automatic retries.")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
        .padding(18)
        .frame(width: 380)
        .tunaGlass(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
    }

    private var rows: [TechPanelRow] {
        let tech = player.tech
        var result: [TechPanelRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { result.append(TechPanelRow(id: label, value: value)) }
        }
        add("Status", statusText)
        if let resolution = tech.resolutionLabel, let height = tech.height {
            let quality = Quality.from(height: max(height, (tech.width ?? 0) * 9 / 16))
            add("Resolution", "\(resolution) (\(quality.label))")
        }
        add("Video", tech.videoCodec)
        add("HDR", tech.hdr)
        add("Frame rate", tech.frameRate.map { Self.frameRateText($0) })
        add("Bitrate", tech.bitrateMbps.map { String(format: "%.1f Mb/s", $0) })
        add("Decoder", tech.decoder)
        add("Audio", audioText(tech))
        add("Route", tech.route)
        add("Buffer", tech.bufferSeconds.map { String(format: "%.1f s", $0) })
        add("Dropped", tech.droppedFrames.map { "\($0) frames" })
        add("Version", player.content?.variant.label)
        add("Engine", tech.engineVersion ?? TunaPlaybackEngine.engineLabel)
        return result
    }

    private static func frameRateText(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.005 { return String(format: "%.0f fps", fps) }
        return String(format: "%.3f fps", fps)
    }

    private func audioText(_ tech: PlayerModel.TechInfo) -> String? {
        guard let codec = tech.audioCodec else { return nil }
        guard let channels = tech.audioChannels else { return codec }
        let layout: String
        switch channels {
        case 1: layout = "mono"
        case 2: layout = "stereo"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        default: layout = "\(channels) ch"
        }
        return "\(codec) · \(layout)"
    }

    private var statusText: String {
        switch player.status {
        case .idle: return "Idle"
        case .opening: return "Opening"
        case .playing: return player.isLive && player.behindLive >= 5 ? "Playing (timeshift)" : "Playing"
        case .paused: return "Paused"
        case .buffering: return "Buffering"
        case .reconnecting: return "Reconnecting"
        case .ended: return "Ended"
        case .failed: return "Failed"
        }
    }
}

struct TechPanelRow: Identifiable {
    /// The label (unique per panel).
    let id: String
    let value: String
}
