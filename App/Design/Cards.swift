import SwiftUI
import AppKit
import CoreText
import TunaCore

// MARK: - PosterCard

/// 2:3 poster card: hover lift + cursor tilt + quality/rating badges; after `Tuna.Motion.hoverPreviewDelay` of
/// hovering, an in-place info reveal slides over the lower half (title, year · runtime · genres, rating,
/// Play and My List). Nothing floats outside the card, so rails never clip it.
struct PosterCard: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress? = nil
    var width: CGFloat = Tuna.Metrics.posterWidth
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isHovering = false
    @State private var isRevealed = false
    @State private var tilt: CGSize = .zero
    @State private var revealTask: Task<Void, Never>? = nil

    private var height: CGFloat { (width / Tuna.Metrics.posterAspect).rounded() }
    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tuna.Metrics.cardRadius, style: .continuous) }
    private var lifted: Bool { isHovering && !reduceMotion }

    var body: some View {
        Button(action: action) {
            DSPosterFace(title: title, metadata: metadata, progress: progress, width: width, height: height,
                         showsFooter: !isRevealed)
        }
        .buttonStyle(DSCardPressStyle())
        .overlay(alignment: .bottom) { revealLayer }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.07), lineWidth: 1).allowsHitTesting(false) }
        .frame(width: width, height: height)
        .onContinuousHover { phase in handleHover(phase) }
        .rotation3DEffect(.degrees(lifted ? Double(tilt.width) * 5 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(lifted ? Double(-tilt.height) * 5 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(lifted ? 1.06 : 1)
        .brightness(isHovering && reduceMotion ? 0.04 : 0)
        .shadow(color: Color.black.opacity(isHovering ? 0.55 : 0), radius: isHovering ? 22 : 0, x: 0, y: isHovering ? 14 : 0)
        .zIndex(isHovering ? 10 : 0)
        .animation(Tuna.Motion.hover, value: isHovering)
        .animation(Tuna.Motion.tilt, value: tilt)
        .accessibilityLabel(Text(title.name))
        .onDisappear { endHover() }
    }

    @ViewBuilder
    private var revealLayer: some View {
        if isRevealed {
            DSPosterReveal(title: title, metadata: metadata, progress: progress, height: (height * 0.56).rounded())
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func handleHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if !isHovering {
                isHovering = true
                scheduleReveal()
            }
            guard !reduceMotion else { return }
            let x = min(max(location.x / max(width, 1), 0), 1) * 2 - 1
            let y = min(max(location.y / max(height, 1), 0), 1) * 2 - 1
            tilt = CGSize(width: x, height: y)
        case .ended:
            endHover()
        }
    }

    private func scheduleReveal() {
        revealTask?.cancel()
        let delay = UInt64(Tuna.Motion.hoverPreviewDelay * 1_000_000_000)
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            withAnimation(Tuna.Motion.reveal) { isRevealed = true }
        }
    }

    private func endHover() {
        revealTask?.cancel()
        revealTask = nil
        isHovering = false
        tilt = .zero
        if isRevealed {
            withAnimation(Tuna.Motion.snappy) { isRevealed = false }
        }
    }
}

/// Artwork + quality badge + footer (rating / year / progress).
private struct DSPosterFace: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress?
    var width: CGFloat
    var height: CGFloat
    var showsFooter: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TunaImage(url: metadata?.posterURL ?? title.posterURL, kind: .poster, seed: title.id, title: title.name,
                      caption: DSCardInfo.posterCaption(title: title, metadata: metadata))
                .frame(width: width, height: height)
            if title.bestQuality != .unknown || title.hdr != nil {
                QualityBadge(quality: title.bestQuality, hdr: title.hdr, compact: true)
                    .padding(8)
            }
            if showsFooter {
                DSPosterFooter(rating: DSCardInfo.bestRating(metadata: metadata, title: title),
                               year: metadata?.year ?? title.year,
                               progress: progress)
                    .frame(width: width, height: height, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .background(Tuna.Palette.surfaceElevated)
    }
}

private struct DSPosterFooter: View {
    var rating: DSRating?
    var year: Int?
    var progress: WatchProgress?

    var body: some View {
        VStack(spacing: 6) {
            if rating != nil || year != nil {
                HStack(spacing: 6) {
                    if let rating {
                        DSMiniRating(rating: rating)
                    }
                    Spacer(minLength: 0)
                    if let year {
                        Text(String(year))
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.86))
                    }
                }
            }
            if let progress {
                ProgressLine(fraction: progress.fraction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
        .background { Tuna.Gradients.footerScrim.allowsHitTesting(false) }
    }
}

/// Compact rating for card footers: coloured star + value.
private struct DSMiniRating: View {
    var rating: DSRating

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(starColor)
            Text(String(format: "%.1f", rating.value))
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
    }

    private var starColor: Color {
        switch rating.source {
        case .tmdb: return Tuna.Palette.tmdb
        case .imdb: return Tuna.Palette.imdb
        case .rottenTomatoes: return Tuna.Palette.rottenTomatoes
        case .metacritic: return Tuna.Palette.metacritic
        case .provider: return Tuna.Palette.gold
        }
    }
}

/// The in-place hover reveal: scrim, title, meta line, rating, Play and My List.
private struct DSPosterReveal: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress?
    var height: CGFloat

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        let inList = model?.isInMyList(title) ?? false
        let metaLine = DSCardInfo.metaLine(title: title, metadata: metadata)
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            Text(title.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(2)
                .allowsHitTesting(false)
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(2)
                    .allowsHitTesting(false)
            }
            if let progress {
                ProgressLine(fraction: progress.fraction)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 6) {
                if let rating = DSCardInfo.bestRating(metadata: metadata, title: title) {
                    DSMiniRating(rating: rating)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                DSRoundIconButton(systemImage: "play.fill", prominent: true, label: "Play") {
                    model?.play(title)
                }
                DSRoundIconButton(systemImage: inList ? "checkmark" : "plus", prominent: false,
                                  label: inList ? "Remove from My List" : "Add to My List") {
                    model?.toggleMyList(title)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .bottom)
        .background { DSRevealScrim().allowsHitTesting(false) }
    }
}

private struct DSRevealScrim: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: Color.black.opacity(0), location: 0),
                        .init(color: Color.black, location: 0.45),
                    ], startPoint: .top, endPoint: .bottom)
                }
            Tuna.Gradients.revealScrim
        }
    }
}

/// Small circular button used inside cards.
struct DSRoundIconButton: View {
    var systemImage: String
    var prominent: Bool
    var size: CGFloat = 28
    var label: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background { Circle().fill(fillColor) }
                .overlay { Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.5), lineWidth: 1) }
                .scaleEffect(isHovering ? 1.12 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Tuna.Motion.snappy) { isHovering = inside }
        }
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var fillColor: Color {
        if prominent { return isHovering ? Color.white : Color.white.opacity(0.92) }
        return Color.white.opacity(isHovering ? 0.3 : 0.16)
    }
}

/// Press feedback shared by all cards.
struct DSCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(Tuna.Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Card info helpers

struct DSRating: Equatable {
    var source: RatingSource
    var value: Double
}

enum DSCardInfo {
    /// Best single rating for compact places: TMDB (with some votes), then IMDb, then the provider's.
    static func bestRating(metadata: MediaMetadata?, title: Title) -> DSRating? {
        if let average = metadata?.voteAverage, average > 0, (metadata?.voteCount ?? 0) >= 5 {
            return DSRating(source: .tmdb, value: average)
        }
        if let imdb = metadata?.imdbRating, imdb > 0 {
            return DSRating(source: .imdb, value: imdb)
        }
        if let provider = title.providerRating, provider > 0 {
            return DSRating(source: .provider, value: provider)
        }
        return nil
    }

    /// "2019 · 2h 16m · Drama, Thriller" (series: "2019 · 3 Seasons · Drama").
    static func metaLine(title: Title, metadata: MediaMetadata?) -> String {
        var parts: [String] = []
        if let year = metadata?.year ?? title.year { parts.append(String(year)) }
        if title.kind == .series {
            if let seasons = metadata?.seasonCount, seasons > 0 {
                parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
            }
        } else if let runtime = metadata?.runtimeMinutes, runtime > 0 {
            parts.append(DSDuration.runtime(minutes: runtime))
        }
        let genres = genreList(title: title, metadata: metadata)
        if !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Caption drawn under generative poster titles: "2019 · Drama".
    static func posterCaption(title: Title, metadata: MediaMetadata?) -> String? {
        var parts: [String] = []
        if let year = metadata?.year ?? title.year { parts.append(String(year)) }
        if let genre = genreList(title: title, metadata: metadata).first { parts.append(genre) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func genreList(title: Title, metadata: MediaMetadata?) -> [String] {
        if let genres = metadata?.genres, !genres.isEmpty { return genres }
        return title.genres
    }
}

enum DSDuration {
    /// 136 -> "2h 16m", 45 -> "45m".
    static func runtime(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// Remaining playback time: "38 min left", "1 h 12 min left".
    static func remaining(seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) h left" }
        return "\(hours) h \(rest) min left"
    }

    /// Countdown clock: 272 -> "4:32", 4000 -> "1:06:40".
    static func clock(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%ld:%02ld:%02ld", hours, minutes, secs) }
        return String(format: "%ld:%02ld", minutes, secs)
    }
}

// MARK: - LandscapeCard

/// 16:9 card for Continue Watching, episodes and wide rails.
struct LandscapeCard: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress? = nil
    var subtitle: String? = nil
    var imageURL: String? = nil
    var width: CGFloat = Tuna.Metrics.landscapeWidth
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isHovering = false

    private var height: CGFloat { (width * 9 / 16).rounded() }
    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tuna.Metrics.cardRadius, style: .continuous) }

    var body: some View {
        Button(action: action) {
            DSLandscapeFace(title: title, metadata: metadata, progress: progress, subtitle: subtitle,
                            imageURL: imageURL, width: width, height: height, isHovering: isHovering)
        }
        .buttonStyle(DSCardPressStyle())
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.07), lineWidth: 1).allowsHitTesting(false) }
        .frame(width: width, height: height)
        .scaleEffect(isHovering && !reduceMotion ? 1.05 : 1)
        .brightness(isHovering && reduceMotion ? 0.04 : 0)
        .shadow(color: Color.black.opacity(isHovering ? 0.5 : 0), radius: isHovering ? 20 : 0, x: 0, y: isHovering ? 12 : 0)
        .zIndex(isHovering ? 10 : 0)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { isHovering = inside }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        [title.name, subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct DSLandscapeFace: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress?
    var subtitle: String?
    var imageURL: String?
    var width: CGFloat
    var height: CGFloat
    var isHovering: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            LinearGradient(stops: [
                .init(color: Color.black.opacity(0), location: 0.35),
                .init(color: Color.black.opacity(0.82), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                titleBlock
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let progress {
                    ProgressLine(fraction: progress.fraction)
                        .padding(.top, 4)
                }
            }
            .padding(12)
            if progress == nil, title.bestQuality != .unknown {
                QualityBadge(quality: title.bestQuality, hdr: title.hdr, compact: true)
                    .padding(9)
                    .frame(width: width, height: height, alignment: .topLeading)
            }
            if progress != nil {
                DSPlayGlyph(visible: isHovering)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .background(Tuna.Palette.surfaceElevated)
    }

    private var artwork: some View {
        let seed = imageURL == nil ? title.id : title.id + "|" + (subtitle ?? "")
        return TunaImage(url: imageURL ?? metadata?.backdropURL ?? title.backdropURL,
                         kind: imageURL == nil ? .backdrop : .still,
                         seed: seed,
                         title: title.name)
            .frame(width: width, height: height)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if imageURL == nil, let logo = metadata?.logoURL {
            TunaImage(url: logo, kind: .logo, seed: title.id, title: title.name, contentMode: .fit, alignment: .bottomLeading)
                .frame(width: width * 0.5, height: height * 0.26, alignment: .bottomLeading)
        } else {
            Text(title.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(2)
                .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 1)
        }
    }
}

/// Glass play disc that appears on hover (continue watching / episodes).
private struct DSPlayGlyph: View {
    var visible: Bool

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .overlay { Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1) }
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
            .scaleEffect(visible ? 1 : 0.7)
            .opacity(visible ? 1 : 0)
            .animation(Tuna.Motion.hover, value: visible)
            .allowsHitTesting(false)
    }
}

// MARK: - Top10Card

/// Top 10 card: giant outlined rank numeral (Tuna.Fonts.rank) with a gradient fill, overlapped by the poster.
struct Top10Card: View {
    var rank: Int
    var title: Title
    var metadata: MediaMetadata?
    var action: () -> Void

    var body: some View {
        let posterWidth = Tuna.Metrics.top10PosterWidth
        let posterHeight = (posterWidth / Tuna.Metrics.posterAspect).rounded()
        let numeral = DSNumeralFactory.glyphs(for: rank, height: (posterHeight * 0.86).rounded())
        let overlap = min(numeral.size.width * 0.3, 40)
        ZStack(alignment: .bottomLeading) {
            DSRankNumeral(rank: rank, glyphs: numeral)
                .padding(.bottom, 2)
            PosterCard(title: title, metadata: metadata, width: posterWidth, action: action)
                .padding(.leading, max(0, numeral.size.width - overlap))
        }
        .frame(height: posterHeight, alignment: .bottom)
    }
}

/// Glyph outline of a rank numeral, normalized to start at (0, 0).
struct DSNumeralGlyphs {
    let path: Path?
    let size: CGSize
}

/// Builds (and caches) CoreText glyph outlines for rank numerals so they can be stroked and gradient-filled.
enum DSNumeralFactory {
    private static let lock = NSLock()
    private static var cache: [String: DSNumeralGlyphs] = [:]

    static func glyphs(for rank: Int, height: CGFloat) -> DSNumeralGlyphs {
        let text = String(rank)
        let key = "\(text)@\(Int(height))"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        let built = build(text: text, height: height)
        lock.lock()
        cache[key] = built
        lock.unlock()
        return built
    }

    private static func rankFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .black)
        if let descriptor = base.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return base
    }

    private static func fallback(text: String, height: CGFloat) -> DSNumeralGlyphs {
        DSNumeralGlyphs(path: nil, size: CGSize(width: height * 0.62 * CGFloat(max(1, text.count)), height: height))
    }

    private static func build(text: String, height: CGFloat) -> DSNumeralGlyphs {
        guard height > 1 else { return fallback(text: text, height: max(height, 1)) }
        let font = rankFont(size: 170)
        let ctFont = font as CTFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: -8]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        let combined = CGMutablePath()
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[index], nil) else { continue }
                let transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                combined.addPath(glyphPath, transform: transform)
            }
        }
        let bounds = combined.boundingBoxOfPath
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return fallback(text: text, height: height) }
        let scale = height / bounds.height
        // Flip CoreText's y-up space and move the outline to the origin.
        var transform = CGAffineTransform(scaleX: scale, y: -scale).translatedBy(x: -bounds.minX, y: -bounds.maxY)
        guard let normalized = combined.copy(using: &transform) else { return fallback(text: text, height: height) }
        return DSNumeralGlyphs(path: Path(normalized), size: CGSize(width: bounds.width * scale, height: height))
    }
}

private struct DSRankNumeral: View {
    var rank: Int
    var glyphs: DSNumeralGlyphs

    var body: some View {
        Group {
            if let path = glyphs.path {
                ZStack(alignment: .topLeading) {
                    path.fill(Tuna.Gradients.rankFill)
                    path.stroke(Tuna.Gradients.rankStroke, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                }
                .frame(width: glyphs.size.width, height: glyphs.size.height, alignment: .topLeading)
            } else {
                Text(String(rank))
                    .font(Tuna.Fonts.rank)
                    .foregroundStyle(Tuna.Gradients.rankFill)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .frame(width: glyphs.size.width, height: glyphs.size.height, alignment: .bottomLeading)
            }
        }
        .shadow(color: Color.black.opacity(0.55), radius: 12, x: 4, y: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - PersonCard

/// Round headshot + name + character.
struct PersonCard: View {
    var member: CastMember
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isHovering = false

    private var reduceMotion: Bool { systemReduceMotion || (model?.settings.reduceMotion ?? false) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                TunaImage(url: member.profileURL, kind: .person, seed: "\(member.personID)-\(member.name)", title: member.name)
                    .frame(width: Tuna.Metrics.personSize, height: Tuna.Metrics.personSize)
                    .clipShape(Circle())
                    .overlay { ring }
                    .scaleEffect(isHovering && !reduceMotion ? 1.06 : 1)
                    .shadow(color: Color.black.opacity(isHovering ? 0.45 : 0.2), radius: isHovering ? 16 : 6, x: 0, y: isHovering ? 10 : 3)
                VStack(spacing: 2) {
                    Text(member.name)
                        .font(Tuna.Fonts.cardTitle)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(2)
                    if let character = member.character, !character.isEmpty {
                        Text(character)
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Tuna.Palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: Tuna.Metrics.personCardWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSCardPressStyle())
        .zIndex(isHovering ? 10 : 0)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { isHovering = inside }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var ring: some View {
        Circle()
            .strokeBorder(isHovering ? AnyShapeStyle(Tuna.Gradients.accent) : AnyShapeStyle(Color.white.opacity(0.1)),
                          lineWidth: isHovering ? 2.5 : 1)
    }

    private var accessibilityText: String {
        if let character = member.character, !character.isEmpty { return "\(member.name) as \(character)" }
        return member.name
    }
}
