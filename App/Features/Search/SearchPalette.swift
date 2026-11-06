import SwiftUI
import TunaCore

// =====================================================================================================
// ⌘K SEARCH PALETTE (owner: live-guide-search). Entry point `SearchPalette()`: overlay content — the shell
// dims the background and closes the palette on an outside click.
//
// Centered glass panel (760 wide, ≤ 620 tall, grows with its content): big search field, scope chips
// (All / Movies / Series / Live), results debounced 120 ms and grouped (Top hit, Movies, Series, Channels,
// People, On Now). ↑/↓ move the selection, ↩ opens, ⇥ cycles the scope, esc closes. Every action closes
// the palette. Empty query: recent searches (this session) and suggestions.
// =====================================================================================================

struct SearchPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var isFieldFocused: Bool
    @Namespace private var selectionSpace
    @State private var query = ""
    @State private var scopeChip: String?
    @State private var results = SearchPaletteResults.empty
    /// The request `results` answers (nil until the first search finishes).
    @State private var answered: SearchPaletteRequest?
    @State private var selection = 0
    @State private var contentHeight: CGFloat = 220
    @State private var suggestions: [String] = []
    @State private var keyboardMovedAt = Date.distantPast
    @State private var clock = Date()

    private static let panelWidth: CGFloat = 760
    private static let panelMaxHeight: CGFloat = 620
    /// Search field + scope bar + divider + footer.
    private static let chromeHeight: CGFloat = 68 + 46 + 1 + 38
    private static let radius: CGFloat = 26

    init() {}

    var body: some View {
        // The shell places the palette under the top bar and owns the scrim; this is just the panel.
        panel
        .onAppear {
            isFieldFocused = true
            if suggestions.isEmpty { suggestions = makeSuggestions() }
        }
        .task {
            // Re-assert focus once the overlay is in the window (onAppear can be too early on macOS).
            try? await Task.sleep(for: .milliseconds(60))
            isFieldFocused = true
        }
        .task(id: request) {
            await search(request)
        }
    }

    // MARK: Panel

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: SearchPalette.radius, style: .continuous)
        return VStack(spacing: 0) {
            searchField
            scopeBar
            Rectangle()
                .fill(Tuna.Palette.stroke)
                .frame(height: 1)
            resultsArea
            footer
        }
        .frame(maxWidth: SearchPalette.panelWidth)
        .background(Tuna.Palette.background.opacity(0.62), in: shape)
        .tunaGlass(cornerRadius: SearchPalette.radius)
        .shadow(color: Color.black.opacity(0.55), radius: 50, x: 0, y: 24)
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Tuna.Gradients.accent)
            TextField("Search movies, series, channels, people…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Tuna.Palette.textPrimary)
                .focused($isFieldFocused)
                .onSubmit { activateSelection() }
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { press in
                    cycleScope(by: press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Tuna.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            ChipBar(items: SearchPaletteScope.chipLabels, selection: $scopeChip, allLabel: SearchPaletteScope.all.label)
            Spacer(minLength: 0)
            if let status = statusText {
                Text(status)
                    .font(Tuna.Fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tuna.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46, alignment: .top)
    }

    private var resultsArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                resultsContent
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                    }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(contentHeight, 64), SearchPalette.panelMaxHeight - SearchPalette.chromeHeight))
            .animation(reduceMotion ? nil : Tuna.Motion.snappy, value: contentHeight)
            .onChange(of: selection) { _, newValue in
                // Follow the keyboard only; hovering never scrolls.
                guard Date().timeIntervalSince(keyboardMovedAt) < 0.4 else { return }
                scrollTo(newValue, proxy: proxy)
            }
        }
    }

    /// Idle (empty query, or the very first search still pending) → results (kept while the next debounced
    /// search runs, so typing never flickers) → no results.
    @ViewBuilder
    private var resultsContent: some View {
        if trimmedQuery.isEmpty || (results.isEmpty && answered == nil) {
            SearchPaletteIdleView(recents: memory.recentQueries,
                                  suggestions: suggestions,
                                  selection: trimmedQuery.isEmpty ? selection : -1,
                                  namespace: selectionSpace,
                                  onPick: { pick($0) },
                                  onForget: { memory.forget($0) },
                                  onClear: { memory.clear() },
                                  onHover: { hover($0) })
        } else if results.isEmpty {
            SearchPaletteNoResults(query: trimmedQuery, scope: scope) {
                scopeChip = nil
            }
        } else {
            SearchPaletteResultsList(results: results,
                                     selection: selection,
                                     namespace: selectionSpace,
                                     now: clock,
                                     onActivate: { perform($0) },
                                     onPlay: { play($0) },
                                     onHover: { hover($0) })
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            SearchPaletteKeyHint(keys: "↑↓", label: "Navigate")
            SearchPaletteKeyHint(keys: "↩", label: "Open")
            SearchPaletteKeyHint(keys: "⇥", label: "Scope")
            SearchPaletteKeyHint(keys: "esc", label: "Close")
            Spacer(minLength: 0)
            Text("Movies · Series · Channels · People · Guide")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tuna.Palette.textTertiary.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) {
            Rectangle().fill(Tuna.Palette.stroke).frame(height: 1)
        }
    }

    // MARK: State helpers

    private var memory: SearchPaletteMemory { SearchPaletteMemory.shared }

    private var scope: SearchPaletteScope { SearchPaletteScope(chip: scopeChip) }

    private var trimmedQuery: String { query.tunaTrimmed }

    private var request: SearchPaletteRequest { SearchPaletteRequest(query: trimmedQuery, scope: scope) }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var statusText: String? {
        guard !trimmedQuery.isEmpty, answered == request, !results.isEmpty else { return nil }
        let count = results.flat.count
        return count == 1 ? "1 result" : "\(count) results"
    }

    private var navigableCount: Int {
        trimmedQuery.isEmpty ? memory.recentQueries.count : results.flat.count
    }

    // MARK: Search

    private func search(_ request: SearchPaletteRequest) async {
        guard !request.query.isEmpty else {
            results = .empty
            answered = nil
            selection = 0
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        runSearch(request)
    }

    private func runSearch(_ request: SearchPaletteRequest) {
        let hits = model.search(request.query, scope: request.scope.titleKind)
        let built = SearchPaletteResults.build(hits: hits, scope: request.scope, model: model)
        clock = Date()
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) {
            results = built
            answered = request
            selection = 0
        }
        requestArtwork(for: built)
    }

    /// Visible-first metadata (posters, ratings) for the title hits on screen.
    private func requestArtwork(for built: SearchPaletteResults) {
        var titles: [Title] = []
        for hit in built.flat.prefix(18) {
            if case .title(let id) = hit.target, let title = model.title(id) {
                titles.append(title)
            }
        }
        if !titles.isEmpty { model.requestMetadata(for: titles) }
    }

    private func makeSuggestions() -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let genres = Array(model.genres(.movie).prefix(6)) + Array(model.genres(.series).prefix(4))
        for entry in genres where names.count < 7 {
            let name = entry.genre.tunaTrimmed
            guard !name.isEmpty, seen.insert(name.tunaFolded).inserted else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: Keyboard & selection

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let count = navigableCount
        guard count > 0 else { return .ignored }
        keyboardMovedAt = Date()
        let next = min(max(selection + delta, 0), count - 1)
        guard next != selection else { return .handled }
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) { selection = next }
        return .handled
    }

    private func hover(_ index: Int) {
        // Ignore hover right after keyboard moves (the list scrolls under a resting pointer).
        guard index >= 0, index != selection, Date().timeIntervalSince(keyboardMovedAt) > 0.4 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { selection = index }
    }

    private func cycleScope(by step: Int) {
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) {
            scopeChip = scope.cycled(by: step).chip
        }
    }

    private func scrollTo(_ index: Int, proxy: ScrollViewProxy) {
        let id: String
        if trimmedQuery.isEmpty {
            id = "recent-\(index)"
        } else {
            guard results.flat.indices.contains(index) else { return }
            id = results.flat[index].id
        }
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) {
            proxy.scrollTo(id)
        }
    }

    /// Return: open the selected item (or the top hit, running a pending search right away).
    private func activateSelection() {
        let current = request
        if current.query.isEmpty {
            let recents = memory.recentQueries
            if recents.indices.contains(selection) { pick(recents[selection]) }
            return
        }
        if answered != current { runSearch(current) }
        guard results.flat.indices.contains(selection) else { return }
        perform(results.flat[selection])
    }

    private func pick(_ text: String) {
        query = text
        selection = 0
        isFieldFocused = true
    }

    // MARK: Actions (each one closes the palette)

    /// ↩ / click: titles open their page, channels play, people open their page, programmes tune in.
    private func perform(_ hit: SearchHit) {
        switch hit.target {
        case .title(let id):
            finish()
            model.router.open(.title(id))
        case .channel(let id):
            guard let channel = model.channel(id) else { return }
            finish()
            model.play(channel)
        case .person(let id, let name, _):
            finish()
            model.router.open(.person(id: id, name: name))
        case .program(let channelID, let program):
            guard let channel = model.channel(channelID) else { return }
            finish()
            watch(program, on: channel)
        }
    }

    /// Top hit "Play" button.
    private func play(_ hit: SearchHit) {
        switch hit.target {
        case .title(let id):
            guard let title = model.title(id) else { return }
            finish()
            model.play(title)
        case .channel, .person, .program:
            perform(hit)
        }
    }

    private func watch(_ program: Program, on channel: Channel) {
        if program.end <= Date(), program.hasArchive, channel.catchupDays != nil {
            model.playCatchup(program, on: channel)
        } else {
            model.play(channel)
        }
    }

    private func finish() {
        memory.remember(query)
        close()
    }

    private func close() {
        withAnimation(reduceMotion ? nil : Tuna.Motion.snappy) {
            model.router.isSearchPresented = false
        }
    }
}

// MARK: - Footer key hint

private struct SearchPaletteKeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Tuna.Palette.textSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
    }
}
