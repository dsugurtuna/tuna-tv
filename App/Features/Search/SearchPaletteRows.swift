import SwiftUI
import TunaCore

// =====================================================================================================
// ⌘K SEARCH PALETTE — result views: the Top hit card, grouped result rows (with the sliding selection
// highlight), the idle state (recent searches + suggestions) and the no-results state.
// =====================================================================================================

private let searchSelectionID = "search.palette.selection"

// MARK: - Results list

struct SearchPaletteResultsList: View {
    let results: SearchPaletteResults
    let selection: Int
    let namespace: Namespace.ID
    let now: Date
    let onActivate: (SearchHit) -> Void
    let onPlay: (SearchHit) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let top = results.topHit {
                SearchPaletteTopHitCard(hit: top,
                                        isSelected: selection == 0,
                                        namespace: namespace,
                                        now: now,
                                        onOpen: { onActivate(top) },
                                        onPlay: { onPlay(top) })
                    .id(top.id)
                    .onHover { inside in
                        if inside { onHover(0) }
                    }
                    .staggeredAppear(index: 0)
            }
            ForEach(results.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    SearchPaletteGroupHeader(title: group.title, detail: group.hits.count.formatted())
                    ForEach(group.hits) { hit in
                        let index = results.position(of: hit)
                        SearchPaletteRow(hit: hit,
                                         isSelected: index == selection,
                                         namespace: namespace,
                                         now: now) {
                            onActivate(hit)
                        }
                        .id(hit.id)
                        .onHover { inside in
                            if inside { onHover(index) }
                        }
                        .staggeredAppear(index: max(0, index))
                    }
                }
            }
        }
    }
}

// MARK: - Top hit

private struct SearchPaletteTopHitCard: View {
    let hit: SearchHit
    let isSelected: Bool
    let namespace: Namespace.ID
    let now: Date
    let onOpen: () -> Void
    let onPlay: () -> Void

    @Environment(AppModel.self) private var model

    private static let height: CGFloat = 188
    private static let radius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SearchPaletteTopHitCard.radius, style: .continuous)
        card
            .frame(maxWidth: .infinity)
            .frame(height: SearchPaletteTopHitCard.height)
            .clipShape(shape)
            .overlay { selectionRing(shape) }
            .contentShape(shape)
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top hit: " + hit.primary)
    }

    @ViewBuilder
    private func selectionRing(_ shape: RoundedRectangle) -> some View {
        if isSelected {
            shape
                .strokeBorder(Tuna.Palette.accent.opacity(0.85), lineWidth: 2)
                .matchedGeometryEffect(id: searchSelectionID, in: namespace)
        } else {
            shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch hit.target {
        case .title(let id):
            if let title = model.title(id) {
                titleCard(title)
            } else {
                genericCard(symbol: "film")
            }
        case .channel(let id):
            if let channel = model.channel(id) {
                channelCard(channel)
            } else {
                genericCard(symbol: "tv")
            }
        case .person(let id, let name, let profileURL):
            personCard(id: id, name: name, profileURL: profileURL)
        case .program(let channelID, let program):
            if let channel = model.channel(channelID) {
                programCard(program, channel: channel)
            } else {
                genericCard(symbol: "calendar")
            }
        }
    }

    // Movies & series: backdrop, poster, facts, Play / Details.
    private func titleCard(_ title: Title) -> some View {
        let meta = model.metadata(for: title)
        return ZStack(alignment: .leading) {
            TunaImage(url: meta?.backdropURL ?? title.backdropURL, kind: .backdrop, seed: title.id, title: title.name)
                .frame(maxWidth: .infinity)
                .frame(height: SearchPaletteTopHitCard.height)
                .clipped()
            Tuna.Gradients.heroSide
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .center, spacing: 18) {
                TunaImage(url: meta?.posterURL ?? title.posterURL, kind: .poster, seed: title.id, title: title.name)
                    .frame(width: 100, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.black.opacity(0.5), radius: 12, x: 0, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    SearchPaletteTopHitLabel()
                    Text(title.name)
                        .font(Tuna.Fonts.display(25, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    SearchPaletteTitleFacts(title: title, metadata: meta)
                    if let overview = (meta?.overview ?? title.plot)?.nonEmpty {
                        Text(overview)
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        GlassButton(title: "Play", systemImage: "play.fill", style: .primary, action: onPlay)
                        GlassButton(title: "Details", systemImage: "info.circle", style: .secondary, action: onOpen)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    // Channels: big logo, now/next with progress, Watch Live.
    private func channelCard(_ channel: Channel) -> some View {
        let program = model.nowPlaying(on: channel, at: now)
        let next = model.nextProgram(on: channel, at: now)
        return ZStack(alignment: .leading) {
            TunaImage(url: program?.iconURL, kind: .backdrop, seed: channel.id, title: channel.name)
                .frame(maxWidth: .infinity)
                .frame(height: SearchPaletteTopHitCard.height)
                .clipped()
            Tuna.Gradients.heroSide
            HStack(alignment: .center, spacing: 20) {
                LiveTVChannelLogo(channel: channel, width: 140, height: 96, cornerRadius: 16)
                VStack(alignment: .leading, spacing: 8) {
                    SearchPaletteTopHitLabel()
                    HStack(spacing: 10) {
                        Text(channel.name)
                            .font(Tuna.Fonts.display(25, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        LiveBadge()
                    }
                    if let program {
                        Text(program.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            ProgressLine(fraction: program.progress(at: now), tint: Tuna.Palette.live, height: 3)
                                .frame(width: 120)
                            Text(LiveTVFormat.remaining(program, at: now))
                                .font(Tuna.Fonts.caption)
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }
                    if let next {
                        Text("Next: " + next.title + " · " + LiveTVFormat.clock(next.start))
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    GlassButton(title: "Watch Live", systemImage: "play.fill", style: .primary, action: onPlay)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    // People: headshot, name, what they are known for.
    private func personCard(id: Int, name: String, profileURL: String?) -> some View {
        ZStack(alignment: .leading) {
            TunaImage(url: nil, kind: .backdrop, seed: "person-\(id)", title: name)
                .frame(maxWidth: .infinity)
                .frame(height: SearchPaletteTopHitCard.height)
                .clipped()
            Tuna.Gradients.heroSide
            HStack(alignment: .center, spacing: 20) {
                TunaImage(url: profileURL, kind: .person, seed: "\(id)", title: name)
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    SearchPaletteTopHitLabel()
                    Text(name)
                        .font(Tuna.Fonts.display(25, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    if !hit.secondary.isEmpty {
                        Text(hit.secondary)
                            .font(Tuna.Fonts.caption)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    GlassButton(title: "View Filmography", systemImage: "person.crop.rectangle.stack", style: .primary, action: onOpen)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    // Guide programmes: channel logo, title, time, Watch.
    private func programCard(_ program: Program, channel: Channel) -> some View {
        let isOn = program.contains(now)
        return ZStack(alignment: .leading) {
            TunaImage(url: program.iconURL, kind: .still, seed: program.id, title: program.title)
                .frame(maxWidth: .infinity)
                .frame(height: SearchPaletteTopHitCard.height)
                .clipped()
            Tuna.Gradients.heroSide
            HStack(alignment: .center, spacing: 20) {
                LiveTVChannelLogo(channel: channel, width: 140, height: 96, cornerRadius: 16)
                VStack(alignment: .leading, spacing: 8) {
                    SearchPaletteTopHitLabel()
                    HStack(spacing: 10) {
                        Text(program.title)
                            .font(Tuna.Fonts.display(25, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                        if isOn {
                            LiveBadge()
                        }
                    }
                    Text(channel.name + " · " + LiveTVFormat.timeRange(program))
                        .font(Tuna.Fonts.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.75))
                    if isOn {
                        ProgressLine(fraction: program.progress(at: now), tint: Tuna.Palette.live, height: 3)
                            .frame(width: 160)
                    }
                    GlassButton(title: isOn ? "Watch Live" : "Watch Channel",
                                systemImage: "play.fill",
                                style: .primary,
                                action: onPlay)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    private func genericCard(symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 6) {
                SearchPaletteTopHitLabel()
                Text(hit.primary)
                    .font(Tuna.Fonts.display(22, weight: .heavy))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                Text(hit.secondary)
                    .font(Tuna.Fonts.caption)
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Tuna.Palette.surfaceElevated)
    }
}

private struct SearchPaletteTopHitLabel: View {
    var body: some View {
        Text("Top hit")
            .font(Tuna.Fonts.micro)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(Tuna.Palette.accent)
    }
}

/// "2021 · Movie · 2 h 10 min · PG-13 · ★ 7.8 · 4K"
private struct SearchPaletteTitleFacts: View {
    let title: Title
    let metadata: MediaMetadata?

    var body: some View {
        HStack(spacing: 8) {
            if let year = metadata?.year ?? title.year {
                Text(String(year))
            }
            Text(title.kind == .movie ? "Movie" : "Series")
            if let runtime = metadata?.runtimeMinutes, runtime > 0, title.kind == .movie {
                Text(LiveTVFormat.duration(TimeInterval(runtime * 60)))
            }
            if let seasons = metadata?.seasonCount, seasons > 0 {
                Text(seasons == 1 ? "1 season" : "\(seasons) seasons")
            }
            if let certification = metadata?.certification?.nonEmpty {
                CertificationBadge(text: certification)
            }
            if let vote = metadata?.voteAverage, vote > 0 {
                RatingChip(source: .tmdb, value: vote, votes: metadata?.voteCount)
            }
            if title.bestQuality != .unknown {
                QualityBadge(quality: title.bestQuality, hdr: title.hdr, compact: true)
            }
        }
        .font(Tuna.Fonts.caption)
        .foregroundStyle(Color.white.opacity(0.8))
        .lineLimit(1)
    }
}

// MARK: - Rows

private struct SearchPaletteRow: View {
    let hit: SearchHit
    let isSelected: Bool
    let namespace: Namespace.ID
    let now: Date
    let action: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.primary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    detail
                }
                Spacer(minLength: 8)
                accessory
                if isSelected {
                    SearchPaletteReturnHint(label: actionLabel)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            .background { highlight }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hit.primary + ", " + hit.secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var highlight: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tuna.Palette.accent.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Tuna.Palette.accent.opacity(0.42), lineWidth: 1)
                )
                .matchedGeometryEffect(id: searchSelectionID, in: namespace)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch hit.target {
        case .title(let id):
            let title = model.title(id)
            TunaImage(url: posterURL(title), kind: .poster, seed: id, title: title?.name ?? hit.primary)
                .frame(width: 34, height: 51)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 54)
        case .channel(let id):
            if let channel = model.channel(id) {
                LiveTVChannelLogo(channel: channel, width: 54, height: 38, cornerRadius: 8)
            } else {
                SearchPaletteSymbolTile(symbol: "tv")
            }
        case .person(let id, let name, let profileURL):
            TunaImage(url: profileURL, kind: .person, seed: "\(id)", title: name)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .frame(width: 54)
        case .program(let channelID, _):
            if let channel = model.channel(channelID) {
                LiveTVChannelLogo(channel: channel, width: 54, height: 38, cornerRadius: 8)
            } else {
                SearchPaletteSymbolTile(symbol: "calendar")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch hit.target {
        case .channel(let id):
            if let channel = model.channel(id), let program = model.nowPlaying(on: channel, at: now) {
                HStack(spacing: 8) {
                    Text("Now: " + program.title)
                        .lineLimit(1)
                    ProgressLine(fraction: program.progress(at: now), tint: Tuna.Palette.live, height: 3)
                        .frame(width: 44)
                }
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textSecondary)
            } else {
                secondaryText
            }
        case .program(let channelID, let program):
            Text(programLine(program, channelID: channelID))
                .font(Tuna.Fonts.caption)
                .monospacedDigit()
                .foregroundStyle(Tuna.Palette.textSecondary)
                .lineLimit(1)
        case .title, .person:
            secondaryText
        }
    }

    private var secondaryText: some View {
        Text(hit.secondary)
            .font(Tuna.Fonts.caption)
            .foregroundStyle(Tuna.Palette.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var accessory: some View {
        switch hit.target {
        case .title(let id):
            if let title = model.title(id) {
                HStack(spacing: 6) {
                    if let vote = model.metadata(for: title)?.voteAverage, vote > 0 {
                        RatingChip(source: .tmdb, value: vote)
                    }
                    if title.bestQuality >= .hd {
                        QualityBadge(quality: title.bestQuality, hdr: title.hdr, compact: true)
                    }
                }
            }
        case .channel(let id):
            if let channel = model.channel(id) {
                HStack(spacing: 6) {
                    if let number = channel.number {
                        Text(String(number))
                            .font(Tuna.Fonts.monoSmall)
                            .foregroundStyle(Tuna.Palette.textTertiary)
                    }
                    if channel.bestQuality >= .hd {
                        QualityBadge(quality: channel.bestQuality, compact: true)
                    }
                }
            }
        case .program(_, let program):
            if program.contains(now) {
                LiveBadge(compact: true)
            } else if program.start > now {
                Text(LiveTVFormat.startsIn(program, at: now))
                    .font(Tuna.Fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tuna.Palette.textTertiary)
            }
        case .person:
            EmptyView()
        }
    }

    private var actionLabel: String {
        switch hit.target {
        case .title: return "Open"
        case .channel: return "Play"
        case .person: return "View"
        case .program(_, let program):
            if program.end <= now { return "Replay" }
            return program.start <= now ? "Watch" : "Tune in"
        }
    }

    private func posterURL(_ title: Title?) -> String? {
        guard let title else { return nil }
        return model.metadata(for: title)?.posterURL ?? title.posterURL
    }

    private func programLine(_ program: Program, channelID: String) -> String {
        let channelName = model.channel(channelID)?.name ?? hit.secondary
        return channelName + " · " + LiveTVFormat.timeRange(program)
    }
}

private struct SearchPaletteSymbolTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Tuna.Palette.textTertiary)
            .frame(width: 54, height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tuna.Palette.surfaceRaised))
    }
}

/// "Open ↩" pill on the selected row.
struct SearchPaletteReturnHint: View {
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
            Image(systemName: "return")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Tuna.Palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct SearchPaletteGroupHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .textCase(.uppercase)
            if let detail {
                Text(detail)
                    .foregroundStyle(Tuna.Palette.textTertiary.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .font(Tuna.Fonts.micro)
        .tracking(1.2)
        .foregroundStyle(Tuna.Palette.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Idle state

/// Empty query: recent searches (keyboard-navigable) and suggestions.
struct SearchPaletteIdleView: View {
    let recents: [String]
    let suggestions: [String]
    let selection: Int
    let namespace: Namespace.ID
    let onPick: (String) -> Void
    let onForget: (String) -> Void
    let onClear: () -> Void
    let onHover: (Int) -> Void

    static let tryQueries = ["thriller", "4K", "Türkçe"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        SearchPaletteGroupHeader(title: "Recent searches")
                        Button("Clear", action: onClear)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tuna.Palette.textTertiary)
                            .padding(.trailing, 10)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(recents.enumerated()), id: \.element) { index, query in
                        SearchPaletteRecentRow(query: query,
                                               isSelected: index == selection,
                                               namespace: namespace,
                                               onPick: { onPick(query) },
                                               onForget: { onForget(query) })
                            .id("recent-\(index)")
                            .onHover { inside in
                                if inside { onHover(index) }
                            }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SearchPaletteGroupHeader(title: "Suggestions")
                SearchPaletteFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        SearchPaletteChip(text: suggestion, symbol: "sparkle.magnifyingglass") {
                            onPick(suggestion)
                        }
                    }
                }
                .padding(.horizontal, 10)
                HStack(spacing: 8) {
                    Text("Try:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textTertiary)
                    ForEach(SearchPaletteIdleView.tryQueries, id: \.self) { query in
                        SearchPaletteChip(text: query, symbol: nil) {
                            onPick(query)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

private struct SearchPaletteRecentRow: View {
    let query: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let onPick: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
                .frame(width: 24)
            Text(query)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isSelected {
                SearchPaletteReturnHint(label: "Search")
            }
            Button(action: onForget) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from recent searches")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Tuna.Palette.accent.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Tuna.Palette.accent.opacity(0.42), lineWidth: 1)
                    )
                    .matchedGeometryEffect(id: searchSelectionID, in: namespace)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onPick)
    }
}

private struct SearchPaletteChip: View {
    let text: String
    let symbol: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(text)
            }
            .font(Tuna.Fonts.chip)
            .foregroundStyle(isHovering ? Tuna.Palette.textPrimary : Tuna.Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: Tuna.Metrics.chipHeight)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - No results

struct SearchPaletteNoResults: View {
    let query: String
    let scope: SearchPaletteScope
    let onSearchEverything: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
            Text("No results for “" + query + "”")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("Check the spelling, or try a genre, a person or a channel name.")
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if scope != .all {
                Button("Search everything instead", action: onSearchEverything)
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Flow layout

/// Wraps chips onto as many lines as needed.
struct SearchPaletteFlowLayout: SwiftUI.Layout {
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
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
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
