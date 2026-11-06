import SwiftUI
import TunaCore

/// One labelled fact (icon, small caps label, content).
struct TDFact<Content: View>: View {
    let label: String
    let symbol: String
    let content: Content

    init(_ label: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tuna.Palette.textTertiary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(Tuna.Fonts.micro)
                    .tracking(0.8)
                    .foregroundStyle(Tuna.Palette.textTertiary)
                content
                    .font(Tuna.Fonts.body)
                    .foregroundStyle(Tuna.Palette.textPrimary)
            }
        }
    }
}

/// "Details": two columns of facts, keywords, collection, provider tech and the match source.
struct TDFactsSection: View {
    let title: Title
    let metadata: MediaMetadata?
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.providerInfo(for: title)
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader(title: "Details")
            HStack(alignment: .top, spacing: 40) {
                TDFactsPrimaryColumn(title: title, metadata: metadata, info: info)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                TDFactsSecondaryColumn(title: title, metadata: metadata, info: info)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let keywords = metadata?.keywords, !keywords.isEmpty {
                TDFact("Keywords", symbol: "tag") {
                    TDFlow(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(keywords.prefix(24).enumerated()), id: \.offset) { item in
                            TDTextChip(text: item.element.capitalized)
                        }
                    }
                }
            }
            if let collection = metadata?.collection {
                TDCollectionCard(collection: collection)
            }
            TDSourceLine(metadata: metadata, info: info, isDemo: model.isDemo)
        }
        .tunaPageInset()
    }
}

struct TDFactsPrimaryColumn: View {
    let title: Title
    let metadata: MediaMetadata?
    let info: RawItemInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let release = releaseText {
                TDFact(title.kind == .series ? "First aired" : "Release date", symbol: "calendar") { Text(release) }
            }
            if title.kind == .series, let last = TDFormat.date(metadata?.lastAirDate) {
                TDFact("Last aired", symbol: "calendar.badge.clock") { Text(last) }
            }
            if let runtime = runtimeText {
                TDFact("Runtime", symbol: "clock") { Text(runtime) }
            }
            if title.kind == .series, let seasons = seasonsText {
                TDFact("Seasons", symbol: "square.stack") { Text(seasons) }
            }
            if let original = originalTitle {
                TDFact("Original title", symbol: "textformat") { Text(original).textSelection(.enabled) }
            }
            if let language = TDFormat.clean(metadata?.originalLanguage) ?? title.languages.first {
                TDFact("Original language", symbol: "character.bubble") {
                    HStack(spacing: 8) {
                        LanguageChip(languageCode: language, compact: false)
                        Text(TDFormat.languageName(language))
                            .foregroundStyle(Tuna.Palette.textSecondary)
                    }
                }
            }
            if !countries.isEmpty {
                TDFact("Countries", symbol: "globe") {
                    TDFlow(spacing: 12, lineSpacing: 6) {
                        ForEach(countries, id: \.self) { code in
                            HStack(spacing: 6) {
                                FlagView(countryCode: code, size: 15)
                                Text(TDFormat.countryName(code))
                            }
                        }
                    }
                }
            }
            if let status = TDFormat.clean(metadata?.status) {
                TDFact("Status", symbol: "flag") {
                    Text(metadata?.inProduction == true ? "\(status) · In production" : status)
                }
            }
        }
    }

    private var releaseText: String? {
        let raw = title.kind == .series ? (metadata?.firstAirDate ?? metadata?.releaseDate) : metadata?.releaseDate
        return TDFormat.date(raw ?? info?.releaseDate)
    }

    private var runtimeText: String? {
        let minutes = metadata?.runtimeMinutes ?? info?.durationSeconds.map { $0 / 60 }
        guard let text = TDFormat.runtime(minutes: minutes) else { return nil }
        return title.kind == .series ? "\(text) per episode" : text
    }

    private var seasonsText: String? {
        guard let seasons = metadata?.seasonCount, seasons > 0 else { return nil }
        var text = seasons == 1 ? "1 season" : "\(seasons) seasons"
        if let episodes = metadata?.episodeCount, episodes > 0 { text += " · \(episodes) episodes" }
        return text
    }

    private var originalTitle: String? {
        let candidate = TDFormat.clean(metadata?.originalTitle) ?? TDFormat.clean(info?.originalName)
        guard let candidate, candidate.lowercased() != title.name.lowercased() else { return nil }
        return candidate
    }

    private var countries: [String] {
        let list = metadata?.displayCountries ?? []
        return list.isEmpty ? title.countries : list
    }
}

struct TDFactsSecondaryColumn: View {
    let title: Title
    let metadata: MediaMetadata?
    let info: RawItemInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let studios = metadata?.studios, !studios.isEmpty {
                TDFact("Studios", symbol: "building.2") { TDCompanyList(companies: studios) }
            }
            if let networks = metadata?.networks, !networks.isEmpty {
                TDFact("Networks", symbol: "dot.radiowaves.left.and.right") { TDCompanyList(companies: networks) }
            }
            if let budget = TDFormat.money(metadata?.budget) {
                TDFact("Budget", symbol: "dollarsign.circle") { Text(budget) }
            }
            if let revenue = TDFormat.money(metadata?.revenue) {
                TDFact("Box office", symbol: "chart.line.uptrend.xyaxis") { Text(revenue) }
            } else if let boxOffice = TDFormat.clean(metadata?.boxOffice) {
                TDFact("Box office", symbol: "chart.line.uptrend.xyaxis") { Text(boxOffice) }
            }
            if let tech = TDFormat.techLine(info?.tech) {
                TDFact("Stream", symbol: "cpu") { Text(tech).font(Tuna.Fonts.mono) }
            }
            if let container = containerText {
                TDFact("Container", symbol: "shippingbox") { Text(container) }
            }
            if let category = providerCategory {
                TDFact("Provider category", symbol: "folder") { Text(category) }
            }
            if let added = title.addedAt {
                TDFact("Added by your provider", symbol: "plus.circle") {
                    Text(added.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
    }

    private var containerText: String? {
        let ext = TDFormat.clean(info?.containerExtension) ?? TDFormat.clean(title.defaultVariant?.raw.containerExtension)
        return ext?.uppercased()
    }

    private var providerCategory: String? {
        if let raw = TDFormat.clean(title.defaultVariant?.raw.categoryName) { return raw }
        return title.categories.isEmpty ? nil : title.categories.prefix(3).joined(separator: ", ")
    }
}

struct TDCompanyList: View {
    let companies: [Company]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(companies.prefix(5).enumerated()), id: \.offset) { item in
                HStack(spacing: 10) {
                    if let logo = item.element.logoURL {
                        TunaImage(url: logo, kind: .studio, seed: "studio-\(item.element.id)", title: item.element.name, contentMode: .fit)
                            .frame(width: 54, height: 20)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.88)))
                    }
                    Text(item.element.name)
                    if let country = item.element.country {
                        FlagView(countryCode: country, size: 13)
                    }
                }
            }
        }
    }
}

struct TDCollectionCard: View {
    let collection: CollectionRef

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 16) {
            TunaImage(url: collection.posterURL, kind: .poster, seed: "collection-\(collection.id)", title: collection.name)
                .frame(width: 70, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("PART OF A COLLECTION")
                    .font(Tuna.Fonts.micro)
                    .tracking(1)
                    .foregroundStyle(Tuna.Palette.gold)
                Text(collection.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background {
            TunaImage(url: collection.backdropURL, kind: .backdrop, seed: "collection-bg-\(collection.id)", title: nil)
                .overlay(LinearGradient(colors: [Tuna.Palette.background.opacity(0.94), Tuna.Palette.background.opacity(0.5)],
                                        startPoint: .leading, endPoint: .trailing))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
    }
}

/// "Matched via TMDB / TVMaze / Provider".
struct TDSourceLine: View {
    let metadata: MediaMetadata?
    let info: RawItemInfo?
    let isDemo: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
            Text(text)
        }
        .font(Tuna.Fonts.caption)
        .foregroundStyle(Tuna.Palette.textTertiary)
    }

    private var text: String {
        guard let metadata else { return "Matched via Provider — add a TMDB key in Settings for the full picture" }
        var line = "Matched via " + TDFormat.sourceName(metadata.source)
        if metadata.source != .omdb, metadata.imdbRating != nil || metadata.rottenTomatoes != nil || metadata.metacritic != nil {
            line += " · Ratings via OMDb"
        }
        if info != nil, metadata.source != .provider { line += " · Stream details from your provider" }
        if isDemo { line += " · Demo content" }
        return line
    }
}

/// "More Like This" poster grid.
struct TDSimilarSection: View {
    let title: Title
    @Environment(AppModel.self) private var model
    @State private var items: [Title] = []

    var body: some View {
        let stamp = model.metadata(for: title)?.fetchedAt.timeIntervalSince1970 ?? 0
        VStack(alignment: .leading, spacing: 16) {
            if !items.isEmpty {
                SectionHeader(title: "More Like This")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Tuna.Metrics.posterWidth, maximum: Tuna.Metrics.posterWidth + 28),
                                             spacing: 20, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(items) { item in
                        PosterCard(title: item, metadata: model.metadata(for: item), progress: model.progress(for: item)) {
                            model.router.open(.title(item.id))
                        }
                    }
                }
            }
        }
        .tunaPageInset()
        .task(id: "\(title.id)|\(stamp)") {
            let similar = model.similar(to: title)
            items = similar
            if !similar.isEmpty { model.requestMetadata(for: similar) }
        }
    }
}
