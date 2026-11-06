import SwiftUI
import TunaCore

// =====================================================================================================
// Shared helpers for the Title Detail, Person, Vault and Insights pages (owner: detail).
// Everything here is prefixed `TD` so it never collides with other features.
// =====================================================================================================

/// Formatting helpers (dates, runtimes, money, languages, countries, stream tech).
enum TDFormat {
    private static let isoParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Trimmed text; nil when empty or a placeholder such as "N/A".
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "n/a" || lowered == "null" || lowered == "none" || lowered == "-" { return nil }
        return trimmed
    }

    /// "2021-03-12" (or a longer ISO string) -> Date.
    static func parseDate(_ text: String?) -> Date? {
        guard let text = clean(text), text.count >= 10 else { return nil }
        return isoParser.date(from: String(text.prefix(10)))
    }

    /// "2021-03-12" -> "Mar 12, 2021" (locale style). Unparseable text is returned as is.
    static func date(_ text: String?) -> String? {
        guard let text = clean(text) else { return nil }
        if let date = parseDate(text) { return displayFormatter.string(from: date) }
        return text
    }

    static func runtime(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "1h 12m left"
    static func remaining(seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return (runtime(minutes: minutes) ?? "\(minutes)m") + " left"
    }

    /// 120_000_000 -> "$120M"
    static func money(_ amount: Int?) -> String? {
        guard let amount, amount > 0 else { return nil }
        let value = Double(amount)
        if value >= 1_000_000_000 { return "$" + oneDecimal(value / 1_000_000_000) + "B" }
        if value >= 1_000_000 { return "$" + oneDecimal(value / 1_000_000) + "M" }
        if value >= 1_000 { return "$" + oneDecimal(value / 1_000) + "K" }
        return "$\(amount)"
    }

    /// 12_345 -> "12.3K"
    static func compact(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_000_000 { return oneDecimal(value / 1_000_000) + "M" }
        if value >= 1_000 { return oneDecimal(value / 1_000) + "K" }
        return "\(count)"
    }

    /// One decimal without a trailing ".0".
    static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    static func message(for error: Error) -> String {
        if let tuna = error as? TunaError { return tuna.userMessage }
        return error.localizedDescription
    }

    static func languageName(_ code: String) -> String {
        if let info = WorldDirectory.language(code.lowercased()) { return info.name }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static func languageNativeName(_ code: String) -> String {
        if let info = WorldDirectory.language(code.lowercased()) { return info.nativeName }
        return Locale(identifier: code).localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// Country whose flag represents a language ("en" -> "GB").
    static func languageFlagCountry(_ code: String) -> String? {
        WorldDirectory.language(code.lowercased())?.flagCountry
    }

    static func countryName(_ code: String) -> String {
        if let info = WorldDirectory.country(code.uppercased()) { return info.name }
        return Locale(identifier: "en").localizedString(forRegionCode: code) ?? code.uppercased()
    }

    static func sourceName(_ source: MetadataSource) -> String {
        switch source {
        case .tmdb: return "TMDB"
        case .tvmaze: return "TVMaze"
        case .omdb: return "OMDb"
        case .provider: return "Provider"
        case .demo: return "Demo library"
        }
    }

    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// "3840×2160 · HEVC · EAC3 5.1 · 18.4 Mbps"
    static func techLine(_ tech: StreamTechInfo?) -> String? {
        guard let tech else { return nil }
        var parts: [String] = []
        if let width = tech.width, let height = tech.height, width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if let video = clean(tech.videoCodec) { parts.append(video.uppercased()) }
        if let audio = clean(tech.audioCodec) {
            var label = audio.uppercased()
            if let channels = tech.audioChannels, channels > 0 { label += " " + channelLayout(channels) }
            parts.append(label)
        }
        if let kbps = tech.bitrateKbps, kbps > 0 { parts.append(oneDecimal(Double(kbps) / 1000) + " Mbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func audioSymbol(_ audio: AudioMarker) -> String {
        switch audio {
        case .dubbed: return "mic.fill"
        case .subtitled: return "captions.bubble.fill"
        case .multiAudio: return "speaker.wave.3.fill"
        case .original: return "waveform"
        }
    }
}

/// Floating back button for pages pushed on the router stack. Sits just below the shell's floating top bar
/// (the top bar has its own back button too; Esc is handled by the shell).
struct TDBackButton: View {
    var padded: Bool
    @Environment(AppModel.self) private var model

    init(padded: Bool = true) {
        self.padded = padded
    }

    var body: some View {
        GlassButton(title: nil, systemImage: "chevron.left", style: .icon) {
            model.router.back()
        }
        .help("Back")
        .padding(.leading, padded ? 24 : 0)
        .padding(.top, padded ? Tuna.Metrics.topBarHeight + 14 : 0)
    }
}

/// Small capsule chip (text + optional symbol) for facts such as "Dubbed", "HEVC", "60fps".
struct TDTextChip: View {
    var text: String
    var symbol: String?
    var tint: Color

    init(text: String, symbol: String? = nil, tint: Color = Tuna.Palette.textSecondary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(Tuna.Fonts.micro)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }
}

/// Number that counts up (with rolling digits) when it appears or when its value changes.
struct TDCountUpText: View {
    var value: Double
    var font: Font
    var format: (Double) -> String

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var shown: Double = 0

    init(value: Double, font: Font = Tuna.Fonts.rounded(34, weight: .heavy), format: @escaping (Double) -> String = TDCountUpText.integer) {
        self.value = value
        self.font = font
        self.format = format
    }

    nonisolated static func integer(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return Int(value.rounded()).formatted()
    }

    var body: some View {
        Text(format(shown))
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText(value: shown))
            .task(id: value) { await countUp() }
    }

    private func countUp() async {
        if systemReduceMotion || model.settings.reduceMotion {
            shown = value
            return
        }
        let start = shown
        let steps = 22
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(38))
            if Task.isCancelled { return }
            let t = Double(step) / Double(steps)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            withAnimation(.snappy(duration: 0.2)) {
                shown = start + (value - start) * eased
            }
        }
        shown = value
    }
}

/// Wrapping row layout (chips, flags, keywords).
struct TDFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            width = max(width, row.width)
            height += row.height
            if index > 0 { height += lineSpacing }
        }
        if let proposed = proposal.width, proposed.isFinite { width = min(width, proposed) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// View wrapper around `TDFlowLayout` so call sites can use a normal trailing closure.
struct TDFlow<Content: View>: View {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        TDFlowLayout(spacing: spacing, lineSpacing: lineSpacing).callAsFunction {
            content
        }
    }
}

/// Expandable paragraph with a "More / Less" toggle.
struct TDExpandableText: View {
    var text: String
    var collapsedLines: Int
    var font: Font

    @State private var expanded = false

    init(text: String, collapsedLines: Int = 3, font: Font = Tuna.Fonts.bodyLarge) {
        self.text = text
        self.collapsedLines = collapsedLines
        self.font = font
    }

    private var isLong: Bool { text.count > collapsedLines * 90 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(font)
                .foregroundStyle(Tuna.Palette.textPrimary.opacity(0.88))
                .lineSpacing(3)
                .lineLimit(expanded ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button {
                    withAnimation(Tuna.Motion.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Less" : "More")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tuna.Palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
