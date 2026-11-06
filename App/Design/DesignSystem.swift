import SwiftUI
import TunaCore

// =====================================================================================================
// DESIGN SYSTEM CONTRACT (owner: design-system). Shared components used by every screen.
// Signatures (type names, init parameters, labels, defaults) are FIXED for other agents. The owner replaces
// the placeholder bodies with the real, animated implementations (and may split into several files in
// App/Design/, add private helpers and extra components).
// =====================================================================================================

enum ArtworkKind: String, Hashable {
    case poster      // 2:3
    case backdrop    // 16:9
    case logo        // transparent title treatment
    case person      // headshot, circle
    case channel     // channel logo on a tile
    case still       // episode still 16:9
    case studio      // company logo
}

/// Remote/demo/generative image with memory+disk cache, downsampling and per-host throttling.
/// - http(s): ImagePipeline (provider panel hosts load one at a time, ≥1 s apart — see HostLimiter.Rule.providerImages)
/// - "demo://<kind>/<seed>": GenerativeArtwork
/// - nil / failure: GenerativeArtwork(kind, seed, title) — never a grey box.
struct TunaImage: View {
    var url: String?
    var kind: ArtworkKind
    var seed: String
    var title: String? = nil
    var contentMode: ContentMode = .fill

    var body: some View {
        GenerativeArtwork(kind: kind, seed: seed, title: title)
    }
}

/// Beautiful deterministic artwork for items without images (and for the demo).
struct GenerativeArtwork: View {
    var kind: ArtworkKind
    var seed: String
    var title: String? = nil

    var body: some View {
        LinearGradient(colors: [Tuna.Palette.surfaceRaised, Tuna.Palette.surface], startPoint: .top, endPoint: .bottom)
    }
}

/// "4K", "Full HD" ... plus optional HDR/DV mark.
struct QualityBadge: View {
    var quality: Quality
    var hdr: HDRFormat? = nil
    var compact: Bool = false
    var body: some View { Text(quality.label).font(Tuna.Fonts.micro) }
}

struct SourceBadge: View {
    var source: SourceTag
    var body: some View { Text(source.label).font(Tuna.Fonts.micro) }
}

/// Emoji flag (+ optional code/name).
struct FlagView: View {
    var countryCode: String
    var size: CGFloat = 14
    var showCode: Bool = false
    var body: some View { Text(Flags.emoji(for: countryCode)) }
}

/// Language chip: flag + native name or code.
struct LanguageChip: View {
    var languageCode: String
    var compact: Bool = true
    var body: some View { Text(languageCode.uppercased()).font(Tuna.Fonts.micro) }
}

enum RatingSource: Hashable { case tmdb, imdb, rottenTomatoes, metacritic, provider }

struct RatingChip: View {
    var source: RatingSource
    /// tmdb/imdb/provider: 0-10; rottenTomatoes/metacritic: 0-100.
    var value: Double
    var votes: Int? = nil
    var body: some View { Text(String(format: "%.1f", value)).font(Tuna.Fonts.caption) }
}

struct CertificationBadge: View {
    var text: String
    var body: some View { Text(text).font(Tuna.Fonts.micro) }
}

/// Text chip for a streaming platform tag ("Netflix", "Exxen"); text only, never brand logos.
struct PlatformChip: View {
    var name: String
    var body: some View { Text(name).font(Tuna.Fonts.micro) }
}

/// Pulsing red "LIVE" pill.
struct LiveBadge: View {
    var compact: Bool = false
    var body: some View { Text("LIVE").font(Tuna.Fonts.micro) }
}

/// Thin progress bar (watch progress / programme progress).
struct ProgressLine: View {
    var fraction: Double
    var tint: Color = Tuna.Palette.accent
    var height: CGFloat = 3
    var body: some View { Capsule().fill(tint).frame(height: height) }
}

enum GlassButtonStyleKind: Hashable { case primary, secondary, icon, destructive }

/// Glass button used everywhere (Play, My List, Trailer ...).
struct GlassButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var style: GlassButtonStyleKind = .secondary
    var action: () -> Void
    var body: some View { Button(title ?? "", action: action) }
}

/// Section header with optional subtitle and "See all".
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil
    var body: some View { Text(title).font(Tuna.Fonts.sectionTitle) }
}

/// Horizontal rail with hover paging arrows, edge fades and lazy content.
struct RailScroller<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading) {
            SectionHeader(title: title, subtitle: subtitle, seeAll: seeAll)
            ScrollView(.horizontal, showsIndicators: false) { LazyHStack(spacing: Tuna.Metrics.railSpacing) { content() } }
        }
    }
}

/// 2:3 poster card: hover lift + cursor tilt + quality/rating badges; after a short hover shows an expanded
/// preview (backdrop, logo, metadata line, Play / My List) without being clipped by the rail.
struct PosterCard: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress? = nil
    var width: CGFloat = Tuna.Metrics.posterWidth
    var action: () -> Void
    var body: some View { Button(title.name, action: action) }
}

/// 16:9 card for Continue Watching, episodes and wide rails.
struct LandscapeCard: View {
    var title: Title
    var metadata: MediaMetadata?
    var progress: WatchProgress? = nil
    var subtitle: String? = nil
    var imageURL: String? = nil
    var width: CGFloat = Tuna.Metrics.landscapeWidth
    var action: () -> Void
    var body: some View { Button(title.name, action: action) }
}

/// Live channel tile: logo on a colour-sampled gradient, now/next with progress, quality badge, flag.
struct ChannelCard: View {
    var channel: Channel
    var now: Program?
    var next: Program?
    var isPlaying: Bool = false
    var isFavorite: Bool = false
    var width: CGFloat = Tuna.Metrics.channelCardWidth
    var action: () -> Void
    var body: some View { Button(channel.name, action: action) }
}

/// Top 10 card: giant outlined rank numeral behind a poster.
struct Top10Card: View {
    var rank: Int
    var title: Title
    var metadata: MediaMetadata?
    var action: () -> Void
    var body: some View { Button("\(rank). \(title.name)", action: action) }
}

/// Round headshot + name + character.
struct PersonCard: View {
    var member: CastMember
    var action: () -> Void
    var body: some View { Button(member.name, action: action) }
}

/// Renders a TunaCore `Rail` in its style (poster, top10, landscape, channels, liveNow, people, continueWatching).
struct RailView: View {
    var rail: Rail
    var onSelect: (RailItem) -> Void
    var onSeeAll: ((String) -> Void)? = nil
    var body: some View { Text(rail.title) }
}

/// Selectable chips (genres, filters).
struct ChipBar: View {
    var items: [String]
    @Binding var selection: String?
    var allLabel: String? = "All"
    var body: some View { HStack { ForEach(items, id: \.self) { Text($0) } } }
}

/// Empty / error state with a symbol, message and optional action.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View { VStack { Image(systemName: symbol); Text(title); Text(message) } }
}

/// Slowly animated ambient background (MeshGradient) tinted by the focused artwork.
struct AmbientBackground: View {
    var tint: Color = Tuna.Palette.accentCool
    var body: some View { Tuna.Palette.background }
}

/// Toast overlay content.
struct ToastView: View {
    var message: ToastMessage
    var body: some View { Text(message.text) }
}

/// The "Provider Shield": tiny status capsule (green shield = healthy, amber = pacing, red = paused) with a
/// popover showing requests today, next allowed request, recent request log and connection usage.
struct ProviderShieldView: View {
    var status: [ProviderStatus]
    var body: some View { Image(systemName: "checkmark.shield.fill") }
}

extension View {
    /// Shimmering skeleton effect while loading.
    func shimmering(active: Bool = true) -> some View { self }
    /// Staggered fade/slide-in when first shown (index-based delay).
    func staggeredAppear(index: Int) -> some View { self }
    /// Hover lift used by custom cards: scale + shadow + z-order.
    func hoverLift(scale: CGFloat = 1.06) -> some View { self }
}
