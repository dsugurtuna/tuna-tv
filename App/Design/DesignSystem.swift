import SwiftUI
import TunaCore

// =====================================================================================================
// DESIGN SYSTEM CONTRACT (owner: design-system). Shared components used by every screen.
// Signatures (type names, init parameters, labels, defaults) are FIXED for other agents. Implementations
// live in the files below (all in App/Design/); every component reads `@Environment(AppModel.self)` as an
// OPTIONAL so it also renders (without app actions) where no AppModel is injected.
//
//   ImagePipeline.swift      ImagePipeline (memory + disk cache, downsampling, provider-safe HTTP)
//   TunaImage.swift          TunaImage (+ placeholder, remote loading)
//   GenerativeArtwork.swift  GenerativeArtwork (deterministic posters, backdrops, logos, people, channels, studios)
//   Badges.swift             QualityBadge, SourceBadge, FlagView, LanguageChip, RatingChip, CertificationBadge,
//                            PlatformChip, LiveBadge, ProgressLine
//   Controls.swift           GlassButton, SectionHeader, ChipBar
//   Rails.swift              RailScroller, RailView
//   Cards.swift              PosterCard, LandscapeCard, Top10Card, PersonCard
//   ChannelCard.swift        ChannelCard
//   Feedback.swift           EmptyStateView, AmbientBackground, ToastView
//   ProviderShield.swift     ProviderShieldView
//   Brand.swift              TunaLogoMark, TunaWordmark
//   Modifiers.swift          shimmering(active:), staggeredAppear(index:), hoverLift(scale:)
//   Theme.swift              tokens (Tuna.Palette / Gradients / Fonts / Metrics / Motion), tunaGlass, Color helpers
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

enum RatingSource: Hashable { case tmdb, imdb, rottenTomatoes, metacritic, provider }

enum GlassButtonStyleKind: Hashable { case primary, secondary, icon, destructive }

extension View {
    /// Shimmering skeleton effect while loading (animated gradient mask; static when motion is reduced).
    func shimmering(active: Bool = true) -> some View { modifier(DSShimmerModifier(active: active)) }
    /// Staggered fade/slide-in when first shown (index-based delay, capped at `Tuna.Motion.staggerCap` items).
    func staggeredAppear(index: Int) -> some View { modifier(DSStaggeredAppearModifier(index: index)) }
    /// Hover lift used by custom cards: scale + shadow + z-order.
    func hoverLift(scale: CGFloat = 1.06) -> some View { modifier(DSHoverLiftModifier(scale: scale)) }
}
