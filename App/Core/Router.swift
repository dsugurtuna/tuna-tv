import SwiftUI
import Observation
import TunaCore

/// Top-level destinations shown in the floating top bar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case live
    case movies
    case series
    case myList
    case vault

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .myList: return "My List"
        case .vault: return "The Vault"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .live: return "dot.radiowaves.left.and.right"
        case .movies: return "film.fill"
        case .series: return "tv.fill"
        case .myList: return "plus.rectangle.on.rectangle"
        case .vault: return "shippingbox.fill"
        }
    }

    /// ⌘1…⌘6
    var shortcut: KeyEquivalent {
        switch self {
        case .home: return "1"
        case .live: return "2"
        case .movies: return "3"
        case .series: return "4"
        case .myList: return "5"
        case .vault: return "6"
        }
    }
}

/// Pages pushed on top of a section (rendered as overlays by RootView so transitions are fully custom).
enum Route: Hashable, Identifiable {
    case title(String)
    case person(id: Int, name: String)
    case seeAll(key: String, title: String, kind: TitleKind?)
    case vaultShelf(VaultShelf)
    case guide
    case insights

    var id: String {
        switch self {
        case .title(let id): return "title:\(id)"
        case .person(let id, _): return "person:\(id)"
        case .seeAll(let key, _, _): return "seeAll:\(key)"
        case .vaultShelf(let shelf): return "vault:\(shelf.rawValue)"
        case .guide: return "guide"
        case .insights: return "insights"
        }
    }
}

@MainActor
@Observable
final class Router {
    var section: AppSection = .home
    /// Overlay stack on top of the current section (last = visible).
    private(set) var stack: [Route] = []
    var isSearchPresented = false
    var isSettingsPresented = false

    var top: Route? { stack.last }

    func select(_ section: AppSection) {
        if self.section == section, !stack.isEmpty {
            withAnimation(Tuna.Motion.page) { stack.removeAll() }
            return
        }
        withAnimation(Tuna.Motion.page) {
            stack.removeAll()
            self.section = section
        }
    }

    func open(_ route: Route) {
        if stack.last == route { return }
        withAnimation(Tuna.Motion.page) { stack.append(route) }
    }

    func back() {
        guard !stack.isEmpty else { return }
        withAnimation(Tuna.Motion.page) { _ = stack.removeLast() }
    }

    func popToRoot() {
        withAnimation(Tuna.Motion.page) { stack.removeAll() }
    }
}
