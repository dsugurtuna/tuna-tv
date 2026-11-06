import SwiftUI
import TunaCore

struct TDCrewEntry: Identifiable, Hashable {
    let id: String
    let personID: Int
    let name: String
    let role: String
    let profileURL: String?
}

/// Cast rail + key crew grid.
struct TDPeopleSection: View {
    let metadata: MediaMetadata
    @Environment(AppModel.self) private var model

    var body: some View {
        let cast = TDPeopleSection.cast(metadata)
        let crew = TDPeopleSection.keyCrew(metadata)
        VStack(alignment: .leading, spacing: 26) {
            if !cast.isEmpty {
                RailScroller(title: "Cast", subtitle: "\(metadata.cast.count) people") {
                    ForEach(cast) { member in
                        PersonCard(member: member) { open(member.personID, member.name) }
                    }
                }
            }
            if !crew.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: metadata.kind == .series ? "Created & crewed by" : "Crew")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .leading)],
                              alignment: .leading, spacing: 14) {
                        ForEach(crew) { entry in
                            TDCrewCard(entry: entry) { open(entry.personID, entry.name) }
                        }
                    }
                }
                .tunaPageInset()
            }
        }
    }

    private func open(_ id: Int, _ name: String) {
        guard id > 0 else {
            model.showToast("No details available for \(name) yet.")
            return
        }
        model.router.open(.person(id: id, name: name))
    }

    static func cast(_ metadata: MediaMetadata) -> [CastMember] {
        var seen = Set<String>()
        return metadata.cast
            .sorted { $0.order < $1.order }
            .filter { seen.insert($0.id).inserted }
            .prefix(30)
            .map { $0 }
    }

    /// Creators, directors, writers, composer, DoP and a few producers.
    static func keyCrew(_ metadata: MediaMetadata) -> [TDCrewEntry] {
        var out: [TDCrewEntry] = []
        var seen = Set<String>()
        func add(_ personID: Int, _ name: String, _ role: String, _ url: String?) {
            let key = "\(personID)|\(name)|\(role)"
            guard seen.insert(key).inserted else { return }
            out.append(TDCrewEntry(id: key, personID: personID, name: name, role: role, profileURL: url))
        }
        for name in metadata.creators {
            let match = metadata.crew.first(where: { $0.name == name })
            add(match?.personID ?? 0, name, "Creator", match?.profileURL)
        }
        let roles: [(role: String, jobs: Set<String>, cap: Int)] = [
            (role: "Director", jobs: ["Director"], cap: 4),
            (role: "Writer", jobs: ["Screenplay", "Writer", "Story", "Novel", "Teleplay", "Author", "Characters"], cap: 5),
            (role: "Composer", jobs: ["Original Music Composer", "Music", "Composer"], cap: 2),
            (role: "Director of Photography", jobs: ["Director of Photography", "Cinematography"], cap: 2),
            (role: "Producer", jobs: ["Producer"], cap: 3),
        ]
        for entry in roles {
            let members = metadata.crew.filter { entry.jobs.contains($0.job) }.prefix(entry.cap)
            for member in members {
                let role = member.job == entry.role || entry.role == "Producer" ? entry.role : member.job
                add(member.personID, member.name, role, member.profileURL)
            }
        }
        if !metadata.crew.contains(where: { $0.job == "Director" }) {
            for name in metadata.directors.prefix(3) { add(0, name, "Director", nil) }
        }
        if !out.contains(where: { $0.role != "Creator" && $0.role != "Director" && $0.role != "Producer" }) {
            for name in metadata.writers.prefix(3) { add(0, name, "Writer", nil) }
        }
        return Array(out.prefix(16))
    }
}

struct TDCrewCard: View {
    let entry: TDCrewEntry
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                TunaImage(url: entry.profileURL, kind: .person, seed: "\(entry.personID)-\(entry.name)", title: entry.name)
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    Text(entry.role)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.personID > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tuna.Palette.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(10)
            .background(shape.fill(hovering ? Tuna.Palette.surfaceRaised : Tuna.Palette.surfaceElevated.opacity(0.7)))
            .overlay(shape.strokeBorder(Tuna.Palette.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Tuna.Motion.hover) { hovering = inside }
        }
    }
}
