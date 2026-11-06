import SwiftUI
import AppKit
import TunaCore

// Shared helpers for the app shell, onboarding and settings (owner: shell).
// Everything here is namespaced (Shell*, ShowcaseCopy) so it never collides with other features.

// MARK: - Text

enum ShellText {
    /// Trimmed text, or nil when nothing is left.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "example.com" for "http://www.example.com:8080/path" (nil when it is not a URL).
    static func host(of urlString: String) -> String? {
        guard let cleaned = clean(urlString) else { return nil }
        let candidate = cleaned.contains("://") ? cleaned : "http://" + cleaned
        guard let host = URLComponents(string: candidate)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "1 day" / "3 days".
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }
}

// MARK: - Formatting

enum ShellFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "just now", "5 minutes ago", "in 2 hours".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Whole calendar days from today until `date` (negative when in the past).
    static func daysLeft(until date: Date, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// "12 Mar 2027 · 126 days left".
    static func expiryLine(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "No expiry date" }
        if date < now { return "Expired on \(day(date))" }
        let days = daysLeft(until: date, now: now)
        if days <= 0 { return "\(day(date)) · ends today" }
        return "\(day(date)) · \(ShellText.count(days, "day")) left"
    }

    static func connections(active: Int?, max: Int?) -> String {
        switch (active, max) {
        case let (active?, max?): return "\(active) of \(max) in use"
        case let (nil, max?): return "Up to \(max)"
        case let (active?, nil): return "\(active) in use"
        case (nil, nil): return "Not reported"
        }
    }

    /// "Every 6 hours", "Every day", "Every week".
    static func interval(_ seconds: TimeInterval) -> String {
        let hours = max(1, Int((seconds / 3600).rounded()))
        if hours % 24 == 0 {
            let days = hours / 24
            switch days {
            case 1: return "Every day"
            case 7: return "Every week"
            default: return "Every \(days) days"
            }
        }
        return "Every \(hours) hours"
    }

    static func errorMessage(_ error: Error) -> String {
        if let tuna = error as? TunaError { return tuna.userMessage }
        if error is CancellationError { return "Cancelled." }
        return error.localizedDescription
    }

    static func stageLabel(_ stage: SyncStage) -> String {
        switch stage {
        case .checkingAccount: return "Checking your account"
        case .liveCategories: return "Reading live TV categories"
        case .movieCategories: return "Reading movie categories"
        case .seriesCategories: return "Reading series categories"
        case .liveChannels: return "Loading live channels"
        case .movies: return "Loading movies"
        case .series: return "Loading series"
        case .playlist: return "Downloading your playlist"
        case .guide: return "Fetching the TV guide"
        case .curating: return "Curating your library"
        case .done: return "All done"
        }
    }

    static func stageShortLabel(_ stage: SyncStage) -> String {
        switch stage {
        case .checkingAccount: return "Account"
        case .liveCategories: return "Live categories"
        case .movieCategories: return "Movie categories"
        case .seriesCategories: return "Series categories"
        case .liveChannels: return "Channels"
        case .movies: return "Movies"
        case .series: return "Series"
        case .playlist: return "Playlist"
        case .guide: return "TV guide"
        case .curating: return "Curation"
        case .done: return "Done"
        }
    }

    /// The sync stages a provider kind goes through, in order (shown as a checklist).
    static func stages(for kind: ProviderKind) -> [SyncStage] {
        switch kind {
        case .xtream:
            return [.checkingAccount, .liveCategories, .movieCategories, .seriesCategories,
                    .liveChannels, .movies, .series, .curating]
        case .m3u:
            return [.playlist, .curating]
        }
    }

    /// Label for a counts-dictionary key (StreamKind raw values, Vault shelves, anything else).
    static func countLabel(_ key: String) -> String {
        switch key {
        case StreamKind.live.rawValue: return "Channels"
        case StreamKind.movie.rawValue: return "Movies"
        case StreamKind.series.rawValue: return "Series"
        case StreamKind.episode.rawValue: return "Episodes"
        default:
            if let shelf = VaultShelf(rawValue: key) { return shelf.title }
            guard let first = key.first else { return key }
            return String(first).uppercased() + key.dropFirst()
        }
    }

    static func countSymbol(_ key: String) -> String {
        switch key {
        case StreamKind.live.rawValue: return "dot.radiowaves.left.and.right"
        case StreamKind.movie.rawValue: return "film.fill"
        case StreamKind.series.rawValue: return "tv.fill"
        case StreamKind.episode.rawValue: return "list.number"
        default:
            if let shelf = VaultShelf(rawValue: key) { return shelf.symbol }
            return "square.stack.fill"
        }
    }

    /// Keys in display order: live, movie, series, episode, then the rest alphabetically.
    static func orderedKeys(_ counts: [String: Int]) -> [String] {
        let preferred = [StreamKind.live.rawValue, StreamKind.movie.rawValue,
                         StreamKind.series.rawValue, StreamKind.episode.rawValue]
        let known = preferred.filter { counts[$0] != nil }
        let rest = counts.keys.filter { !preferred.contains($0) }.sorted()
        return known + rest
    }

    static func total(_ counts: [String: Int]) -> Int {
        counts.values.reduce(0, +)
    }

    /// "Movies 312 · Series 41 · Channels 220".
    static func breakdown(_ counts: [String: Int], limit: Int = 3) -> String {
        let parts = orderedKeys(counts)
            .filter { (counts[$0] ?? 0) > 0 }
            .prefix(limit)
            .map { "\(countLabel($0)) \((counts[$0] ?? 0).formatted())" }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }

    static func liveFormatLabel(_ format: LiveStreamFormat) -> String {
        switch format {
        case .auto: return "Automatic (MPEG-TS, HLS fallback)"
        case .ts: return "MPEG-TS (.ts)"
        case .m3u8: return "HLS (.m3u8)"
        }
    }
}

// MARK: - Showcase copy (onboarding + settings)

enum ShowcaseCopy {
    static func title(_ quality: ShowcaseQuality) -> String {
        switch quality {
        case .ultraOnly: return "4K only — the good stuff"
        case .fullHDPlus: return "Full HD and up"
        case .everything: return "Everything"
        }
    }

    static func detail(_ quality: ShowcaseQuality) -> String {
        switch quality {
        case .ultraOnly: return "Ultra HD (and HDR) fills the showcase. Full HD and everything below waits in The Vault."
        case .fullHDPlus: return "A fuller showcase with 1080p and 4K. SD and the rest wait in The Vault."
        case .everything: return "No quality bar. Your worlds still decide what makes the showcase."
        }
    }

    static func badge(_ quality: ShowcaseQuality) -> String {
        switch quality {
        case .ultraOnly: return "4K"
        case .fullHDPlus: return "1080p+"
        case .everything: return "ALL"
        }
    }
}

// MARK: - Links

enum ShellLinks {
    static let tmdbKey = URL(string: "https://www.themoviedb.org/settings/api")!
    static let omdbKey = URL(string: "https://www.omdbapi.com/apikey.aspx")!
    static let github = URL(string: "https://github.com/dsugurtuna/tuna-tv")!
}

// MARK: - Provider Shield state (text + colour for a GovernorSnapshot)

struct ShellShieldState: Equatable {
    enum Level: Equatable { case healthy, pacing, paused, blocked, unknown }

    var level: Level
    var title: String
    var detail: String

    var symbol: String {
        switch level {
        case .healthy: return "checkmark.shield.fill"
        case .pacing: return "shield.lefthalf.filled"
        case .paused: return "pause.circle.fill"
        case .blocked: return "xmark.shield.fill"
        case .unknown: return "shield"
        }
    }

    var tint: Color {
        switch level {
        case .healthy: return Tuna.Palette.success
        case .pacing: return Tuna.Palette.warning
        case .paused: return Tuna.Palette.danger
        case .blocked: return Tuna.Palette.danger
        case .unknown: return Tuna.Palette.textTertiary
        }
    }

    static func from(_ snapshot: GovernorSnapshot?) -> ShellShieldState {
        guard let snapshot else {
            return ShellShieldState(level: .unknown, title: "Standing by", detail: "No requests to this provider yet.")
        }
        switch snapshot.breaker {
        case .closed:
            if snapshot.queued > 0 || snapshot.inFlight > 0 {
                let waiting = snapshot.queued > 0 ? "\(snapshot.queued) waiting · " : ""
                return ShellShieldState(level: .pacing, title: "Pacing",
                                        detail: "\(waiting)one request at a time")
            }
            return ShellShieldState(level: .healthy, title: "Healthy",
                                    detail: "Requests flow gently, one at a time.")
        case .open(let until, let reason, _):
            return ShellShieldState(level: .paused, title: "Paused until \(ShellFormat.time(until))",
                                    detail: reason.isEmpty ? "Your provider pushed back, so Tuna TV is waiting." : reason)
        case .authBlocked(let reason):
            return ShellShieldState(level: .blocked, title: "Login refused",
                                    detail: reason.isEmpty ? "Check the username and password." : reason)
        }
    }
}

// MARK: - Ambient tint

enum ShellTint {
    static let palette: [Color] = [
        Tuna.Palette.accentCool, Tuna.Palette.accent, Color(hex: 0x6C7CFF),
        Tuna.Palette.hdr, Tuna.Palette.accentWarm, Tuna.Palette.fhd,
    ]

    /// Stable (launch-independent) tint for a seed such as a title id.
    static func forSeed(_ seed: String?) -> Color {
        guard let seed, !seed.isEmpty else { return Tuna.Palette.accentCool }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Window dragging (hidden title bar)

/// Transparent strip that drags the window (and zooms on double-click, honouring the system preference).
/// Used where SwiftUI content covers the hidden title bar.
struct ShellWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ShellWindowDragNSView { ShellWindowDragNSView() }
    func updateNSView(_ nsView: ShellWindowDragNSView, context: Context) {}
}

final class ShellWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

// MARK: - Flow layout (chips that wrap)

struct ShellFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Small shared views

/// Determinate ring (fraction) with an optional spinning comet on top.
struct ShellProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 3
    var spinning: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.015, min(1, fraction))))
                .stroke(Tuna.Gradients.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Tuna.Motion.gentle, value: fraction)
            if spinning {
                ShellSpinnerArc(lineWidth: lineWidth)
            }
        }
    }
}

/// A short arc that orbits continuously (TimelineView, so it never "sticks" like repeatForever can).
struct ShellSpinnerArc: View {
    var lineWidth: CGFloat
    var arc: Double = 0.16
    var period: Double = 1.15
    var tint: Color = Tuna.Palette.accentCool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Circle()
                .trim(from: 0, to: CGFloat(arc))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(t * 360))
        }
    }
}

/// A flag emoji clipped into a circle (globe when the code has no flag).
struct ShellFlagCircle: View {
    let code: String
    var diameter: CGFloat = 24

    var body: some View {
        let flag = Flags.emoji(for: code)
        ZStack {
            Circle().fill(Tuna.Palette.surfaceRaised)
            if flag.isEmpty {
                Image(systemName: "globe")
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            } else {
                Text(flag)
                    .font(.system(size: diameter * 1.5))
                    .fixedSize()
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

/// Small capsule tag ("Trial", "Recommended").
struct ShellTag: View {
    let text: String
    var tint: Color = Tuna.Palette.accent

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// Round icon button used in the top bar.
struct ShellIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Tuna.Palette.textSecondary
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovering ? Tuna.Palette.textPrimary : tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
    }
}
