import SwiftUI
import TunaCore

/// Person page (route `.person(id:name:)`): headshot, facts, biography and the titles on Tuna TV.
struct PersonView: View {
    let personID: Int
    let name: String
    @Environment(AppModel.self) private var model
    @State private var person: PersonDetails?
    @State private var didLoad = false

    init(personID: Int, name: String) {
        self.personID = personID
        self.name = name
    }

    private var seed: String { "\(personID)-\(name)" }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PersonPageGlow(profileURL: person?.profileURL, seed: seed)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 44) {
                    PersonPageHeader(name: name, person: person, isLoading: !didLoad, seed: seed)
                        .staggeredAppear(index: 0)
                    PersonPageCredits(name: name, person: person, didLoad: didLoad)
                        .staggeredAppear(index: 1)
                }
                .padding(.top, Tuna.Metrics.topBarHeight + 76)
                .padding(.bottom, 80)
            }
            TDBackButton()
        }
        .task(id: personID) {
            didLoad = false
            if personID > 0 {
                person = await model.person(id: personID)
            } else {
                person = nil
            }
            didLoad = true
        }
    }
}

/// Soft blurred glow from the headshot behind the header.
private struct PersonPageGlow: View {
    let profileURL: String?
    let seed: String

    var body: some View {
        TunaImage(url: profileURL, kind: .person, seed: seed, title: nil)
            .frame(maxWidth: .infinity)
            .frame(height: 460)
            .blur(radius: 90)
            .opacity(0.4)
            .overlay(Tuna.Gradients.heroScrim)
            .clipped()
            .allowsHitTesting(false)
    }
}

private struct PersonPageHeader: View {
    let name: String
    let person: PersonDetails?
    let isLoading: Bool
    let seed: String

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            TunaImage(url: person?.profileURL, kind: .person, seed: seed, title: name)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Tuna.Gradients.accent, lineWidth: 3))
                .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
            VStack(alignment: .leading, spacing: 14) {
                if let department = TDFormat.clean(person?.knownForDepartment) {
                    Text(department.uppercased())
                        .font(Tuna.Fonts.micro)
                        .tracking(1.6)
                        .foregroundStyle(Tuna.Palette.accent)
                }
                Text(person?.name ?? name)
                    .font(Tuna.Fonts.pageTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(2)
                facts
                if isLoading {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(Tuna.Palette.surfaceRaised)
                                .frame(maxWidth: index == 3 ? 320 : 640)
                                .frame(height: 12)
                        }
                    }
                    .shimmering()
                } else if let biography = TDFormat.clean(person?.biography) {
                    TDExpandableText(text: biography, collapsedLines: 6)
                } else if person != nil {
                    Text("No biography yet.")
                        .font(Tuna.Fonts.body)
                        .foregroundStyle(Tuna.Palette.textTertiary)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            Spacer(minLength: 0)
        }
        .tunaPageInset()
    }

    @ViewBuilder
    private var facts: some View {
        if let line = lifeLine {
            Label(line, systemImage: "calendar")
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
        }
        if let place = TDFormat.clean(person?.placeOfBirth) {
            Label(place, systemImage: "mappin.and.ellipse")
                .font(Tuna.Fonts.body)
                .foregroundStyle(Tuna.Palette.textSecondary)
        }
    }

    private var lifeLine: String? {
        guard let person, let born = TDFormat.parseDate(person.birthday), let bornText = TDFormat.date(person.birthday) else { return nil }
        if let died = TDFormat.parseDate(person.deathday), let diedText = TDFormat.date(person.deathday) {
            return "\(bornText) – \(diedText) (aged \(years(from: born, to: died)))"
        }
        return "Born \(bornText) (age \(years(from: born, to: Date())))"
    }

    private func years(from start: Date, to end: Date) -> Int {
        Calendar(identifier: .gregorian).dateComponents([.year], from: start, to: end).year ?? 0
    }
}

private struct PersonPageCredits: View {
    let name: String
    let person: PersonDetails?
    let didLoad: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let titles: [Title] = person.map { model.titles(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "On Tuna TV", subtitle: subtitle(titles.count))
            if !didLoad {
                skeleton
            } else if person == nil {
                EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                               title: "No details for \(name)",
                               message: model.hasTMDBKey
                                   ? "Tuna TV couldn't load this person right now. Try again later."
                                   : "Add your free TMDB key in Settings to see biographies and filmographies.",
                               actionTitle: "Go back",
                               action: { model.router.back() })
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if titles.isEmpty {
                EmptyStateView(symbol: "film.stack",
                               title: "Nothing on Tuna TV yet",
                               message: "None of \(name)'s titles are offered by your provider right now.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Tuna.Metrics.posterWidth, maximum: Tuna.Metrics.posterWidth + 28),
                                             spacing: 20, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(titles) { item in
                        PosterCard(title: item, metadata: model.metadata(for: item), progress: model.progress(for: item)) {
                            model.router.open(.title(item.id))
                        }
                    }
                }
            }
        }
        .tunaPageInset()
    }

    private func subtitle(_ count: Int) -> String? {
        guard didLoad, person != nil, count > 0 else { return nil }
        return count == 1 ? "1 title in your library" : "\(count) titles in your library"
    }

    private var skeleton: some View {
        HStack(spacing: 20) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Tuna.Metrics.cardRadius, style: .continuous)
                    .fill(Tuna.Palette.surfaceRaised)
                    .frame(width: Tuna.Metrics.posterWidth, height: Tuna.Metrics.posterWidth / Tuna.Metrics.posterAspect)
            }
        }
        .shimmering()
    }
}
