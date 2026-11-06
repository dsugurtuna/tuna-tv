import SwiftUI
import TunaCore

/// "See all" page pushed over a section: back button, title, live count, sort, and the full poster grid of
/// `model.grid(kind, filter: BrowseFilter(seeAllKey: key))`.
struct SeeAllView: View {
    let key: String
    let title: String
    let kind: TitleKind?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var sort: BrowseFilter.Sort = .recommended

    init(key: String, title: String, kind: TitleKind?) {
        self.key = key
        self.title = title
        self.kind = kind
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var subtitle: String? {
        switch kind {
        case .some(let value): return Discover.Format.kindTitle(value)
        case .none: return nil
        }
    }

    var body: some View {
        let titles = model.grid(kind, filter: BrowseFilter(sort: sort, seeAllKey: key))
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                header(count: titles.count)
                    .tunaPageInset()
                if titles.isEmpty {
                    EmptyStateView(
                        symbol: "square.grid.3x3.square",
                        title: "Nothing here right now",
                        message: "This shelf is empty at the moment. New titles show up here after your next library refresh.",
                        actionTitle: "Go Back"
                    ) {
                        model.router.back()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    Discover.PosterGrid(titles: titles, reduceMotion: reduceMotion) { (item: Title, width: CGFloat) in
                        Discover.GridPoster(title: item, width: width)
                    }
                    .tunaPageInset()
                }
            }
            .padding(.top, Discover.Layout.pageTop)
            .padding(.bottom, Discover.Layout.pageBottom)
        }
        .ignoresSafeArea(edges: .top)
        .background { Discover.PageBackground() }
        .background {
            // ⌘[ goes back, like every page-based Mac app.
            Button("Back") { model.router.back() }
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .center, spacing: 18) {
            GlassButton(systemImage: "chevron.left", style: .icon) {
                model.router.back()
            }
            .help("Back (⌘[)")
            VStack(alignment: .leading, spacing: 6) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(Tuna.Fonts.micro)
                        .tracking(2)
                        .foregroundStyle(Tuna.Palette.accent)
                }
                Text(title)
                    .font(Tuna.Fonts.pageTitle)
                    .tracking(-0.6)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(2)
                Discover.CountText(count: count)
                    .font(Tuna.Fonts.bodyLarge.weight(.medium))
                    .foregroundStyle(Tuna.Palette.textSecondary)
            }
            Spacer(minLength: 16)
            Discover.SortMenu(selection: $sort.animation(reduceMotion ? nil : Tuna.Motion.page))
        }
    }
}
