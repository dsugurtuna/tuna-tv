import SwiftUI
import TunaCore

/// Title logo / name, meta line, badges, ratings, tagline + overview and the action buttons.
struct TDHeader: View {
    let title: Title
    let metadata: MediaMetadata?
    var onTrailer: (Trailer) -> Void
    var onShowVersions: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.providerInfo(for: title)
        VStack(alignment: .leading, spacing: 16) {
            TDTitleTreatment(title: title, logoURL: metadata?.logoURL)
            TDMetaLine(title: title, metadata: metadata, info: info)
            TDBadgesRow(title: title, metadata: metadata)
            TDRatingsRow(title: title, metadata: metadata)
            TDOverview(tagline: TDFormat.clean(metadata?.tagline), overview: overview(info))
            TDActionButtons(title: title, metadata: metadata, info: info,
                            onTrailer: onTrailer, onShowVersions: onShowVersions)
                .padding(.top, 6)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tunaPageInset()
    }

    private func overview(_ info: RawItemInfo?) -> String? {
        if let text = TDFormat.clean(metadata?.overview) { return text }
        if let text = TDFormat.clean(info?.plot) { return text }
        return TDFormat.clean(title.plot)
    }
}

struct TDTitleTreatment: View {
    let title: Title
    let logoURL: String?

    var body: some View {
        if let logoURL {
            TunaImage(url: logoURL, kind: .logo, seed: title.id, title: title.name, contentMode: .fit, alignment: .leading)
                .frame(maxWidth: 480, maxHeight: 160, alignment: .leading)
                .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 6)
                .accessibilityLabel(Text(title.name))
        } else {
            Text(title.name)
                .font(Tuna.Fonts.heroTitle)
                .foregroundStyle(Tuna.Palette.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .shadow(color: Color.black.opacity(0.55), radius: 16, x: 0, y: 4)
        }
    }
}

enum TDMetaPart: Hashable {
    case text(String)
    case certification(String)
}

/// year · runtime · certification · genres · seasons
struct TDMetaLine: View {
    let title: Title
    let metadata: MediaMetadata?
    let info: RawItemInfo?

    var body: some View {
        let items = parts
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    Circle()
                        .fill(Tuna.Palette.textTertiary)
                        .frame(width: 4, height: 4)
                }
                partView(item.element)
            }
        }
    }

    @ViewBuilder
    private func partView(_ part: TDMetaPart) -> some View {
        switch part {
        case .text(let text):
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tuna.Palette.textSecondary)
                .lineLimit(1)
        case .certification(let text):
            CertificationBadge(text: text)
        }
    }

    private var parts: [TDMetaPart] {
        var out: [TDMetaPart] = []
        if let year = metadata?.year ?? title.year { out.append(.text(String(year))) }
        if title.kind == .movie {
            let minutes = metadata?.runtimeMinutes ?? info?.durationSeconds.map { $0 / 60 }
            if let runtime = TDFormat.runtime(minutes: minutes) { out.append(.text(runtime)) }
        }
        if let cert = TDFormat.clean(metadata?.certification) { out.append(.certification(cert)) }
        let genres = (metadata?.genres.isEmpty == false) ? (metadata?.genres ?? []) : title.genres
        if !genres.isEmpty { out.append(.text(genres.prefix(3).joined(separator: ", "))) }
        if title.kind == .series, let seasons = metadata?.seasonCount, seasons > 0 {
            out.append(.text(seasons == 1 ? "1 Season" : "\(seasons) Seasons"))
        }
        return out
    }
}

struct TDBadgesRow: View {
    let title: Title
    let metadata: MediaMetadata?

    var body: some View {
        let variant = title.defaultVariant
        HStack(spacing: 8) {
            if title.bestQuality != .unknown || title.hdr != nil {
                QualityBadge(quality: title.bestQuality, hdr: title.hdr)
            }
            if let source = TDBadgesRow.notableSource(variant?.parsed.source) {
                SourceBadge(source: source)
            }
            if let audio = variant?.parsed.audio, audio != .original {
                TDTextChip(text: audio.label, symbol: TDFormat.audioSymbol(audio))
            }
            if let platform = title.platform ?? variant?.parsed.platform {
                PlatformChip(name: platform)
            }
            ForEach(countries, id: \.self) { code in
                FlagView(countryCode: code, size: 16)
                    .help(TDFormat.countryName(code))
            }
            if let language = originalLanguage {
                LanguageChip(languageCode: language, compact: false)
            }
            if let shelf = title.placement.shelf {
                TDTextChip(text: "In The Vault · \(shelf.title)", symbol: shelf.symbol, tint: Tuna.Palette.gold)
            }
        }
    }

    private var countries: [String] {
        let list = metadata?.displayCountries ?? []
        return Array((list.isEmpty ? title.countries : list).prefix(4))
    }

    private var originalLanguage: String? {
        TDFormat.clean(metadata?.originalLanguage) ?? title.languages.first
    }

    /// Sources worth calling out on the page (disc rips and low-grade captures).
    static func notableSource(_ source: SourceTag?) -> SourceTag? {
        guard let source else { return nil }
        switch source {
        case .remux, .bluray, .dvd, .cam, .telesync, .screener: return source
        case .webdl, .webrip, .hdtv: return nil
        }
    }
}

struct TDRatingsRow: View {
    let title: Title
    let metadata: MediaMetadata?

    private var tmdb: Double? { metadata?.voteAverage.flatMap { $0 > 0 ? $0 : nil } }
    private var imdb: Double? { metadata?.imdbRating.flatMap { $0 > 0 ? $0 : nil } }
    private var provider: Double? { title.providerRating.flatMap { $0 > 0 ? $0 : nil } }
    private var awards: String? { TDFormat.clean(metadata?.awards) }

    private var hasAny: Bool {
        tmdb != nil || imdb != nil || metadata?.rottenTomatoes != nil || metadata?.metacritic != nil
            || provider != nil || awards != nil
    }

    var body: some View {
        if hasAny {
            HStack(spacing: 10) {
                if let tmdb { RatingChip(source: .tmdb, value: tmdb, votes: metadata?.voteCount) }
                if let imdb { RatingChip(source: .imdb, value: imdb, votes: metadata?.imdbVotes) }
                if let rt = metadata?.rottenTomatoes { RatingChip(source: .rottenTomatoes, value: Double(rt)) }
                if let mc = metadata?.metacritic { RatingChip(source: .metacritic, value: Double(mc)) }
                if tmdb == nil, imdb == nil, let provider { RatingChip(source: .provider, value: provider) }
                if let awards {
                    Label(awards, systemImage: "trophy.fill")
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.gold)
                        .lineLimit(1)
                        .help(awards)
                }
            }
        }
    }
}

struct TDOverview: View {
    let tagline: String?
    let overview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tagline {
                Text(tagline)
                    .font(.system(size: 16, weight: .medium))
                    .italic()
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            if let overview {
                TDExpandableText(text: overview, collapsedLines: 3)
            }
        }
    }
}

/// Play / Resume, Trailer, My List, thumbs and the versions menu.
struct TDActionButtons: View {
    let title: Title
    let metadata: MediaMetadata?
    let info: RawItemInfo?
    var onTrailer: (Trailer) -> Void
    var onShowVersions: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.progress(for: title)
        let rating = model.rating(for: title)
        let inList = model.isInMyList(title)
        HStack(spacing: 12) {
            GlassButton(title: playLabel(progress), systemImage: "play.fill", style: .primary) {
                model.play(title)
            }
            if let trailer = playableTrailer {
                GlassButton(title: "Trailer", systemImage: "play.rectangle.fill", style: .secondary) {
                    onTrailer(trailer)
                }
            }
            GlassButton(title: inList ? "In My List" : "My List", systemImage: inList ? "checkmark" : "plus", style: .secondary) {
                withAnimation(Tuna.Motion.snappy) { model.toggleMyList(title) }
            }
            GlassButton(title: nil, systemImage: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsup", style: .icon) {
                model.rate(title, rating > 0 ? 0 : 1)
            }
            .help(rating > 0 ? "Remove rating" : "I like this")
            GlassButton(title: nil, systemImage: rating < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown", style: .icon) {
                model.rate(title, rating < 0 ? 0 : -1)
            }
            .help(rating < 0 ? "Remove rating" : "Not for me")
            if title.variants.count > 1 {
                TDVersionsMenu(title: title, onShowVersions: onShowVersions)
            }
        }
    }

    private func playLabel(_ progress: WatchProgress?) -> String {
        guard let progress, !progress.isFinished, progress.position > 30 else { return "Play" }
        let left = TDFormat.remaining(seconds: progress.remaining)
        if title.kind == .series, let season = progress.season, let episode = progress.episode {
            return "Resume S\(season) E\(episode) · \(left)"
        }
        return "Resume · \(left)"
    }

    private var playableTrailer: Trailer? {
        if let trailer = metadata?.bestTrailer, let key = TDTrailerKey.extract(trailer.youtubeKey) {
            return Trailer(youtubeKey: key, name: trailer.name, type: trailer.type, isOfficial: trailer.isOfficial)
        }
        if let key = TDTrailerKey.extract(info?.trailerYouTubeID) {
            return Trailer(youtubeKey: key, name: "\(title.name) — Trailer")
        }
        if let key = TDTrailerKey.extract(title.defaultVariant?.raw.trailerYouTubeID) {
            return Trailer(youtubeKey: key, name: "\(title.name) — Trailer")
        }
        return nil
    }
}

/// Menu shortcut: play any version directly, or open the versions box below.
struct TDVersionsMenu: View {
    let title: Title
    var onShowVersions: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Play a version") {
                ForEach(title.variants) { variant in
                    Button(menuLabel(variant)) { model.play(title, variant: variant) }
                }
            }
            Divider()
            Button("Open the versions box", systemImage: "shippingbox") { onShowVersions() }
        } label: {
            Label("\(title.variants.count) Versions", systemImage: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textPrimary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 38)
        .tunaGlass(cornerRadius: 19)
        .help("Choose a version")
    }

    private func menuLabel(_ variant: Variant) -> String {
        var text = variant.label
        if variant.id == title.defaultVariant?.id { text += "  (default)" }
        if variant.verifiedQuality != nil { text += "  ✓" }
        return text
    }
}
