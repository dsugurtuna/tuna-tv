import SwiftUI
import TunaCore

struct TDSeasonGroup: Identifiable, Hashable {
    let number: Int
    let episodes: [RawEpisode]
    var id: Int { number }
}

/// Series: season chips + episode list (provider episodes, TMDB stills/names when available).
struct TDEpisodesSection: View {
    let title: Title
    @Environment(AppModel.self) private var model
    @State private var groups: [TDSeasonGroup] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var seasonLabel: String?
    @State private var seasonMetadata: [Int: SeasonMetadata] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Episodes", subtitle: subtitle)
            content
        }
        .tunaPageInset()
        .task(id: "\(title.id)#\(attempt)") { await load() }
        .task(id: "\(title.id)#season\(selectedSeason ?? -1)") { await loadSeasonMetadata() }
    }

    private var subtitle: String? {
        guard loaded, !groups.isEmpty else { return nil }
        let episodes = groups.reduce(0) { $0 + $1.episodes.count }
        let seasons = groups.filter { $0.number > 0 }.count
        let seasonText = seasons == 1 ? "1 season" : "\(seasons) seasons"
        return "\(seasonText) · \(episodes) episodes"
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage, !loaded {
            EmptyStateView(symbol: "exclamationmark.triangle.fill",
                           title: "Episodes didn't load",
                           message: errorMessage,
                           actionTitle: "Try again",
                           action: { attempt += 1 })
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else if !loaded {
            TDEpisodeSkeleton()
        } else if groups.isEmpty {
            EmptyStateView(symbol: "tv",
                           title: "No episodes yet",
                           message: "Your provider hasn't listed any episodes for this series.")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            if groups.count > 1 {
                ChipBar(items: groups.map { label(for: $0.number) }, selection: $seasonLabel, allLabel: nil)
            }
            if let overview = TDFormat.clean(currentSeasonMetadata?.overview) {
                Text(overview)
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 820, alignment: .leading)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(currentEpisodes) { episode in
                    TDEpisodeRow(title: title, episode: episode, metadata: episodeMetadata(episode))
                }
            }
        }
    }

    private func label(for season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    private var selectedSeason: Int? {
        if let seasonLabel, let match = groups.first(where: { label(for: $0.number) == seasonLabel }) {
            return match.number
        }
        return groups.first(where: { $0.number > 0 })?.number ?? groups.first?.number
    }

    private var currentEpisodes: [RawEpisode] {
        guard let season = selectedSeason else { return [] }
        return groups.first(where: { $0.number == season })?.episodes ?? []
    }

    private var currentSeasonMetadata: SeasonMetadata? {
        guard let season = selectedSeason else { return nil }
        return seasonMetadata[season]
    }

    private func episodeMetadata(_ episode: RawEpisode) -> EpisodeMetadata? {
        seasonMetadata[episode.season]?.episodes.first(where: { $0.episodeNumber == episode.episode })
    }

    private func load() async {
        errorMessage = nil
        if attempt > 0 { loaded = false }
        do {
            let info = try await model.seriesInfo(for: title)
            let built = info.episodesBySeason.map { TDSeasonGroup(number: $0.season, episodes: $0.episodes) }
            groups = built
            if seasonLabel == nil, let initial = initialSeason(in: built), built.count > 1 {
                seasonLabel = label(for: initial)
            }
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = TDFormat.message(for: error)
        }
    }

    /// The season of the most recently watched, unfinished episode; else the first regular season.
    private func initialSeason(in groups: [TDSeasonGroup]) -> Int? {
        var bestSeason: Int?
        var bestDate: Date?
        for group in groups {
            for episode in group.episodes {
                guard let progress = model.progress(forEpisode: episode.ref), progress.position > 30 else { continue }
                if let bestDate, bestDate >= progress.updatedAt { continue }
                bestDate = progress.updatedAt
                bestSeason = group.number
            }
        }
        if let bestSeason { return bestSeason }
        return groups.first(where: { $0.number > 0 })?.number ?? groups.first?.number
    }

    private func loadSeasonMetadata() async {
        guard let season = selectedSeason, seasonMetadata[season] == nil else { return }
        if let metadata = await model.season(for: title, number: season) {
            seasonMetadata[season] = metadata
        }
    }
}

struct TDEpisodeRow: View {
    let title: Title
    let episode: RawEpisode
    let metadata: EpisodeMetadata?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var name: String {
        if let name = TDFormat.clean(metadata?.name) { return name }
        if let name = TDFormat.clean(episode.title) { return name }
        return "Episode \(episode.episode)"
    }

    private var runtime: String? {
        TDFormat.runtime(minutes: metadata?.runtimeMinutes ?? episode.durationSeconds.map { $0 / 60 })
    }

    private var overview: String? { TDFormat.clean(metadata?.overview) ?? TDFormat.clean(episode.plot) }

    var body: some View {
        let progress = model.progress(forEpisode: episode.ref)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {
            model.play(episode: episode, of: title)
        } label: {
            HStack(alignment: .top, spacing: 18) {
                still(progress: progress)
                details(progress: progress)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(shape.fill(hovering ? Tuna.Palette.surfaceElevated : Tuna.Palette.surface.opacity(0.45)))
            .overlay(shape.strokeBorder(hovering ? Tuna.Palette.strokeStrong : Tuna.Palette.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
        .accessibilityLabel(Text("Play episode \(episode.episode), \(name)"))
    }

    private func still(progress: WatchProgress?) -> some View {
        ZStack(alignment: .bottom) {
            TunaImage(url: metadata?.stillURL ?? episode.stillURL, kind: .still, seed: episode.id, title: name)
                .frame(width: 236, height: 133)
                .clipped()
            if let progress, progress.position > 0 {
                ProgressLine(fraction: progress.fraction, height: 3)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 236, height: 133)
        .overlay {
            ZStack {
                Color.black.opacity(hovering ? 0.35 : 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Tuna.Gradients.accent))
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func details(progress: WatchProgress?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "E\(episode.episode) · \(name)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                if let progress, progress.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tuna.Palette.success)
                        .help("Watched")
                }
                Spacer(minLength: 8)
                if let runtime {
                    Text(runtime)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
            }
            HStack(spacing: 10) {
                if let air = TDFormat.date(metadata?.airDate ?? episode.airDate) {
                    Text(air)
                }
                if let progress, !progress.isFinished, progress.position > 30 {
                    Text(TDFormat.remaining(seconds: progress.remaining))
                        .foregroundStyle(Tuna.Palette.accent)
                }
            }
            .font(Tuna.Fonts.caption)
            .foregroundStyle(Tuna.Palette.textTertiary)
            if let overview {
                Text(overview)
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.top, 4)
    }
}

/// Loading placeholder for the episode list.
struct TDEpisodeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Tuna.Palette.surfaceRaised).frame(width: 96, height: 30)
                }
            }
            ForEach(0..<4, id: \.self) { _ in
                HStack(alignment: .top, spacing: 18) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Tuna.Palette.surfaceRaised)
                        .frame(width: 236, height: 133)
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(Tuna.Palette.surfaceRaised).frame(width: 260, height: 14)
                        Capsule().fill(Tuna.Palette.surfaceElevated).frame(width: 120, height: 10)
                        Capsule().fill(Tuna.Palette.surfaceElevated).frame(maxWidth: 520).frame(height: 10)
                    }
                    .padding(.top, 8)
                }
                .padding(12)
            }
        }
        .shimmering()
    }
}
