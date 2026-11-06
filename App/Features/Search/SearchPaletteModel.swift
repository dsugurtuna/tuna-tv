import SwiftUI
import Observation
import TunaCore

// =====================================================================================================
// ⌘K SEARCH PALETTE — model layer: scopes, grouping of `AppModel.search` hits into Top hit / Movies /
// Series / Channels / People / On Now, keyboard order, and the in-memory recent searches.
// =====================================================================================================

enum SearchPaletteScope: String, CaseIterable, Hashable {
    case all
    case movies
    case series
    case live

    var label: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .series: return "Series"
        case .live: return "Live"
        }
    }

    /// ChipBar items (All is the bar's `allLabel`, i.e. a nil selection).
    static let chipLabels: [String] = [SearchPaletteScope.movies.label, SearchPaletteScope.series.label, SearchPaletteScope.live.label]

    init(chip: String?) {
        self = SearchPaletteScope.allCases.first(where: { $0 != .all && $0.label == chip }) ?? .all
    }

    var chip: String? { self == .all ? nil : label }

    /// What `AppModel.search(_:scope:)` filters on (Live has no title kind: we filter the hits instead).
    var titleKind: TitleKind? {
        switch self {
        case .movies: return .movie
        case .series: return .series
        case .all, .live: return nil
        }
    }

    func includes(_ kind: SearchPaletteGroup.Kind) -> Bool {
        switch self {
        case .all: return true
        case .movies: return kind == .movies || kind == .people
        case .series: return kind == .series || kind == .people
        case .live: return kind == .channels || kind == .programs
        }
    }

    /// Tab / ⇧Tab cycling.
    func cycled(by step: Int) -> SearchPaletteScope {
        let cases = SearchPaletteScope.allCases
        guard let index = cases.firstIndex(of: self) else { return .all }
        let next = (index + step % cases.count + cases.count) % cases.count
        return cases[next]
    }
}

/// `.task(id:)` key for the debounced search, and the request the current results answer.
struct SearchPaletteRequest: Hashable {
    var query: String
    var scope: SearchPaletteScope
}

struct SearchPaletteGroup: Identifiable {
    enum Kind: String, CaseIterable, Hashable {
        case movies
        case series
        case channels
        case people
        case programs
    }

    let kind: Kind
    let hits: [SearchHit]
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .movies: return "Movies"
        case .series: return "Series"
        case .channels: return "Channels"
        case .people: return "People"
        case .programs: return "On Now"
        }
    }
}

/// Grouped results in display order. `flat` is the keyboard order: top hit first, then every group.
struct SearchPaletteResults {
    let topHit: SearchHit?
    let groups: [SearchPaletteGroup]
    let flat: [SearchHit]
    private let positions: [String: Int]

    static let empty = SearchPaletteResults(topHit: nil, groups: [])

    init(topHit: SearchHit?, groups: [SearchPaletteGroup]) {
        self.topHit = topHit
        self.groups = groups
        var flat: [SearchHit] = []
        if let topHit { flat.append(topHit) }
        for group in groups { flat.append(contentsOf: group.hits) }
        self.flat = flat
        var positions: [String: Int] = [:]
        for (index, hit) in flat.enumerated() where positions[hit.id] == nil {
            positions[hit.id] = index
        }
        self.positions = positions
    }

    var isEmpty: Bool { flat.isEmpty }

    /// Keyboard index of a hit (-1 when unknown).
    func position(of hit: SearchHit) -> Int { positions[hit.id] ?? -1 }

    @MainActor
    static func build(hits: [SearchHit], scope: SearchPaletteScope, model: AppModel) -> SearchPaletteResults {
        var buckets: [SearchPaletteGroup.Kind: [SearchHit]] = [:]
        var kept: [SearchHit] = []
        var seen = Set<String>()
        for hit in hits {
            guard seen.insert(hit.id).inserted,
                  let hitKind = classify(hit, model: model),
                  scope.includes(hitKind) else { continue }
            kept.append(hit)
            buckets[hitKind, default: []].append(hit)
        }
        // Highest score wins the top spot; ties keep the search order.
        guard let top = kept.max(by: { $0.score < $1.score }) else { return .empty }
        let limit = scope == .all ? 5 : 24
        var groups: [SearchPaletteGroup] = []
        for kind in SearchPaletteGroup.Kind.allCases {
            let hits = (buckets[kind] ?? []).filter { $0.id != top.id }.prefix(limit)
            if !hits.isEmpty {
                groups.append(SearchPaletteGroup(kind: kind, hits: Array(hits)))
            }
        }
        return SearchPaletteResults(topHit: top, groups: groups)
    }

    @MainActor
    private static func classify(_ hit: SearchHit, model: AppModel) -> SearchPaletteGroup.Kind? {
        switch hit.target {
        case .title(let id):
            guard let title = model.title(id) else { return nil }
            switch title.kind {
            case .movie: return .movies
            case .series: return .series
            }
        case .channel(let id):
            return model.channel(id) == nil ? nil : .channels
        case .person:
            return .people
        case .program(let channelID, _):
            return model.channel(channelID) == nil ? nil : .programs
        }
    }
}

/// Recent searches for this session (in memory only, never written to disk).
@MainActor
@Observable
final class SearchPaletteMemory {
    static let shared = SearchPaletteMemory()

    private(set) var recentQueries: [String] = []

    private static let limit = 8

    func remember(_ query: String) {
        let trimmed = query.tunaTrimmed
        guard trimmed.count >= 2 else { return }
        let folded = trimmed.tunaFolded
        recentQueries.removeAll { $0.tunaFolded == folded }
        recentQueries.insert(trimmed, at: 0)
        if recentQueries.count > SearchPaletteMemory.limit {
            recentQueries.removeLast(recentQueries.count - SearchPaletteMemory.limit)
        }
    }

    func forget(_ query: String) {
        recentQueries.removeAll { $0 == query }
    }

    func clear() {
        recentQueries.removeAll()
    }
}
