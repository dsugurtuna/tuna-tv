import SwiftUI
import TunaCore

// =====================================================================================================
// LIVE TV SUPPORT (owner: live-guide-search). Selection model, channel lists, formatting, colours and
// small shared views used by Live TV (LiveView), the TV Guide (GuideView) and the ⌘K search palette.
// Every type here is prefixed `LiveTV…` so it never collides with other features.
// =====================================================================================================

// MARK: - Selection

/// What the Live TV category rail shows. Persisted as `storageValue` (AppStorage) so the channel wall
/// and the TV guide always open on the same shelf.
enum LiveTVSelection: Hashable {
    case all
    case favorites
    case recents
    case category(ChannelCategory)
    case group(String)

    static let storageKey = "tuna.live.selection"
    private static let categoryPrefix = "category:"
    private static let groupPrefix = "group:"

    init(storageValue: String) {
        if storageValue == "favorites" {
            self = .favorites
        } else if storageValue == "recents" {
            self = .recents
        } else if storageValue.hasPrefix(LiveTVSelection.categoryPrefix),
                  let category = ChannelCategory(rawValue: String(storageValue.dropFirst(LiveTVSelection.categoryPrefix.count))) {
            self = .category(category)
        } else if storageValue.hasPrefix(LiveTVSelection.groupPrefix),
                  storageValue.count > LiveTVSelection.groupPrefix.count {
            self = .group(String(storageValue.dropFirst(LiveTVSelection.groupPrefix.count)))
        } else {
            self = .all
        }
    }

    var storageValue: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .recents: return "recents"
        case .category(let category): return LiveTVSelection.categoryPrefix + category.rawValue
        case .group(let name): return LiveTVSelection.groupPrefix + name
        }
    }

    var title: String {
        switch self {
        case .all: return "All Channels"
        case .favorites: return "Favorites"
        case .recents: return "Recently Watched"
        case .category(let category): return category.title
        case .group(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .all: return "dot.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .recents: return "clock.arrow.circlepath"
        case .category(let category): return category.symbol
        case .group: return "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Tuna.Palette.accent
        case .favorites: return Tuna.Palette.gold
        case .recents: return Tuna.Palette.accentCool
        case .category(let category): return LiveTVFormat.tint(for: category)
        case .group: return Tuna.Palette.textSecondary
        }
    }
}

// MARK: - Channel lists

/// Cache key for derived channel lists (selection + library snapshot + adult lock state).
struct LiveTVListKey: Hashable {
    var selection: LiveTVSelection
    var library: ObjectIdentifier
    var adult: Bool
}

/// A de-duplicated channel list plus a few facts for headers ("124 channels · 12 in 4K · 30 with replay").
struct LiveTVChannelList {
    let channels: [Channel]
    let catchupCount: Int
    let ultraHDCount: Int

    static let empty = LiveTVChannelList(channels: [])

    init(channels source: [Channel]) {
        var seen = Set<String>()
        var unique: [Channel] = []
        unique.reserveCapacity(source.count)
        var catchup = 0
        var ultra = 0
        for channel in source where seen.insert(channel.id).inserted {
            unique.append(channel)
            if channel.catchupDays != nil { catchup += 1 }
            if channel.bestQuality == .uhd { ultra += 1 }
        }
        channels = unique
        catchupCount = catchup
        ultraHDCount = ultra
    }
}

@MainActor
enum LiveTVChannels {
    /// Channels for a rail selection. Adult channels only appear once the Vault is unlocked (favourites and
    /// recents are the user's own picks and are kept as they are).
    static func resolve(_ selection: LiveTVSelection, model: AppModel) -> [Channel] {
        let library = model.library
        let source: [Channel]
        switch selection {
        case .all: source = library.liveShowcase
        case .favorites: source = model.favoriteChannels
        case .recents: source = model.recentChannels
        case .category(let category): source = library.channels(in: category)
        case .group(let name): source = library.channelGroups.first(where: { $0.name == name })?.channels ?? []
        }
        if model.adultUnlocked { return source }
        switch selection {
        case .favorites, .recents: return source
        case .all, .category, .group: return source.filter { !$0.isAdult }
        }
    }

    /// Cached list for the shelves that come from the (immutable) library snapshot; favourites and recents
    /// are always fresh because they change with every click.
    static func list(_ selection: LiveTVSelection, model: AppModel,
                     memo: LiveTVMemo<LiveTVListKey, LiveTVChannelList>) -> LiveTVChannelList {
        switch selection {
        case .favorites, .recents:
            return LiveTVChannelList(channels: resolve(selection, model: model))
        case .all, .category, .group:
            let key = LiveTVListKey(selection: selection, library: ObjectIdentifier(model.library), adult: model.adultUnlocked)
            return memo.value(for: key) { LiveTVChannelList(channels: resolve(selection, model: model)) }
        }
    }
}

/// Single-entry memo kept in `@State`, so heavy library queries run once per change instead of on every
/// body evaluation (clock ticks, hover, favourites).
final class LiveTVMemo<Key: Hashable, Value> {
    private var storedKey: Key?
    private var storedValue: Value?

    init() {}

    func value(for key: Key, _ compute: () -> Value) -> Value {
        if let storedValue, storedKey == key { return storedValue }
        let fresh = compute()
        storedKey = key
        storedValue = fresh
        return fresh
    }
}

/// Identity of the data a Live screen depends on; used as a `.task(id:)` key.
struct LiveTVDataStamp: Hashable {
    var guide: ObjectIdentifier
    var library: ObjectIdentifier
}

/// One live event for the "On Now" strip.
struct LiveTVEvent: Identifiable, Hashable {
    let channel: Channel
    let program: Program
    var id: String { channel.id + "|" + program.id }
}

// MARK: - Formatting & colours

enum LiveTVFormat {
    /// Localised short time ("21:45" / "9:45 PM").
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "21:00 – 22:30".
    static func timeRange(_ program: Program) -> String {
        clock(program.start) + " – " + clock(program.end)
    }

    /// "45 min", "1 h", "1 h 20 min" (rounded up to the next minute).
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "42 min left" / "Ended".
    static func remaining(_ program: Program, at now: Date) -> String {
        let seconds = program.end.timeIntervalSince(now)
        return seconds > 0 ? duration(seconds) + " left" : "Ended"
    }

    /// "in 20 min" / "Now".
    static func startsIn(_ program: Program, at now: Date) -> String {
        let seconds = program.start.timeIntervalSince(now)
        return seconds > 0 ? "in " + duration(seconds) : "Now"
    }

    /// "Today", "Tomorrow", "Yesterday" or "Sat 8 Nov".
    static func day(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Friday 6 November".
    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func channelCount(_ count: Int) -> String {
        count == 1 ? "1 channel" : "\(count.formatted()) channels"
    }

    /// Version label for menus: "Full HD · EN · Backup".
    static func variantTitle(_ variant: Variant, index: Int) -> String {
        var parts = [variant.label]
        if let hours = variant.parsed.timeshiftHours, hours != 0 { parts.append("+\(hours) h") }
        if variant.parsed.isBackup { parts.append("Backup") }
        return "\(index + 1). " + parts.joined(separator: " · ")
    }

    /// Accent colour of a channel category.
    static func tint(for category: ChannelCategory) -> Color {
        switch category {
        case .sports, .outdoor, .auto, .events: return Tuna.Palette.success
        case .news, .business, .weather, .legislative: return Tuna.Palette.accentCool
        case .movies, .classic: return Tuna.Palette.hdr
        case .series, .entertainment, .comedy: return Tuna.Palette.hd
        case .kids, .animation, .family: return Tuna.Palette.gold
        case .documentary, .science, .education, .culture, .travel: return Tuna.Palette.fhd
        case .music: return Tuna.Palette.accentWarm
        case .lifestyle, .cooking, .relax, .shop: return Tuna.Palette.warning
        case .religious, .general, .other: return Tuna.Palette.textSecondary
        case .xxx: return Tuna.Palette.danger
        }
    }

    /// Accent colour of a programme from its guide categories ("Sports", "News", "Movie" …), falling back
    /// to the channel's first category.
    static func tint(for program: Program, channel: Channel?) -> Color {
        for raw in program.categories {
            let value = raw.lowercased()
            if value.contains("sport") || value.contains("football") || value.contains("soccer") { return Tuna.Palette.success }
            if value.contains("news") || value.contains("politic") || value.contains("weather") { return Tuna.Palette.accentCool }
            if value.contains("movie") || value.contains("film") || value.contains("cinema") { return Tuna.Palette.hdr }
            if value.contains("kid") || value.contains("child") || value.contains("anim") || value.contains("cartoon") { return Tuna.Palette.gold }
            if value.contains("doc") || value.contains("nature") || value.contains("science") || value.contains("history") { return Tuna.Palette.fhd }
            if value.contains("music") || value.contains("concert") { return Tuna.Palette.accentWarm }
            if value.contains("series") || value.contains("drama") || value.contains("soap") || value.contains("sitcom") || value.contains("comedy") {
                return Tuna.Palette.hd
            }
            if value.contains("entertain") || value.contains("show") || value.contains("reality") || value.contains("game") { return Tuna.Palette.accent }
        }
        if let category = channel?.categories.first { return tint(for: category) }
        return Tuna.Palette.textSecondary
    }

    /// SF Symbol for a sports kind ("Football", "Formula 1" …) from `LiveEventDetector.sportsKind`.
    static func sportSymbol(for kind: String) -> String {
        let value = kind.lowercased()
        if value.contains("american") || value.contains("nfl") || value.contains("rugby") { return "football.fill" }
        if value.contains("football") || value.contains("soccer") || value.contains("futbol") || value.contains("fútbol") { return "soccerball" }
        if value.contains("basket") || value.contains("nba") { return "basketball.fill" }
        if value.contains("tennis") { return "tennis.racket" }
        if value.contains("formula") || value.contains("f1") || value.contains("motor") || value.contains("racing")
            || value.contains("grand prix") || value.contains("moto") { return "flag.checkered" }
        if value.contains("golf") { return "figure.golf" }
        if value.contains("baseball") || value.contains("mlb") { return "baseball.fill" }
        if value.contains("hockey") || value.contains("nhl") { return "hockey.puck.fill" }
        if value.contains("box") || value.contains("ufc") || value.contains("mma") || value.contains("fight") { return "figure.boxing" }
        if value.contains("cycl") || value.contains("tour") { return "bicycle" }
        if value.contains("volley") { return "volleyball.fill" }
        if value.contains("cricket") { return "cricket.ball.fill" }
        return "sportscourt.fill"
    }

    /// Id of the channel the player shows live right now (catch-up playback does not count).
    @MainActor
    static func playingChannelID(_ content: PlayerModel.Content?) -> String? {
        guard let content else { return nil }
        switch content {
        case .channel(let channel, _): return channel.id
        case .movie, .episode, .catchup: return nil
        }
    }

    /// Id of the variant currently playing live on `channelID`, if any.
    @MainActor
    static func playingVariantID(_ content: PlayerModel.Content?, channelID: String) -> String? {
        guard let content else { return nil }
        switch content {
        case .channel(let channel, let variant): return channel.id == channelID ? variant.id : nil
        case .movie, .episode, .catchup: return nil
        }
    }
}

// MARK: - Shared views

/// Channel logo on a raised tile (TunaImage falls back to generative channel artwork).
struct LiveTVChannelLogo: View {
    let channel: Channel
    var width: CGFloat = 52
    var height: CGFloat = 36
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        TunaImage(url: channel.logoURL, kind: .channel, seed: channel.id, title: channel.name, contentMode: .fit)
            .padding(max(2, min(width, height) * 0.08))
            .frame(width: width, height: height)
            .background(shape.fill(Tuna.Palette.surfaceRaised))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
    }
}

/// Context menu shared by every channel surface (wall cards, On Now cards, guide rows).
/// `model` is passed explicitly because menus are rendered outside the normal view hierarchy.
struct LiveTVChannelMenu: View {
    let channel: Channel
    let model: AppModel
    var includeGuide: Bool = true

    var body: some View {
        Button {
            model.play(channel)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            model.toggleFavorite(channel)
        } label: {
            if model.isFavorite(channel) {
                Label("Remove from Favorites", systemImage: "star.slash")
            } else {
                Label("Add to Favorites", systemImage: "star")
            }
        }
        if !channel.variants.isEmpty {
            Menu("Versions") {
                versionItems
            }
        }
        if includeGuide {
            Divider()
            Button {
                model.router.open(.guide)
            } label: {
                Label("Open TV Guide", systemImage: "calendar.day.timeline.left")
            }
        }
    }

    @ViewBuilder
    private var versionItems: some View {
        let playingID = LiveTVFormat.playingVariantID(model.player.content, channelID: channel.id)
        ForEach(Array(channel.variants.enumerated()), id: \.offset) { index, variant in
            Button {
                model.play(channel, variant: variant)
            } label: {
                if variant.id == playingID {
                    Label(LiveTVFormat.variantTitle(variant, index: index), systemImage: "checkmark")
                } else {
                    Text(LiveTVFormat.variantTitle(variant, index: index))
                }
            }
        }
    }
}
