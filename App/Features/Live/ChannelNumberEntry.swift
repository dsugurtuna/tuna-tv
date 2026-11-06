import SwiftUI
import TunaCore

// =====================================================================================================
// CHANNEL NUMBER ENTRY. Typing digits on Live TV (or in the guide) shows a big glass "Go to 104" overlay;
// after 1.2 s without a new digit (or on Return) the channel with that number starts playing.
// Esc cancels, Delete removes the last digit. Zapping itself is debounced by the player, so this never opens
// more than one stream.
// =====================================================================================================

struct ChannelNumberEntryModifier: ViewModifier {
    /// Only the frontmost screen listens (not while the player, search, settings or a pushed page covers it).
    let isActive: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var isFocused: Bool
    @State private var digits = ""
    @State private var commitTask: Task<Void, Never>?
    @State private var index = LiveTVChannelNumberIndex()

    private static let maxDigits = 5
    private static let commitDelay: Duration = .milliseconds(1200)

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func body(content: Content) -> some View {
        content
            .focusable(isActive)
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                append(press)
            }
            .onKeyPress(.return) { commitNow() }
            .onKeyPress(.escape) { cancel() }
            .onKeyPress(.delete) { deleteLast() }
            .overlay { overlay }
            .onAppear {
                if isActive { isFocused = true }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    isFocused = true
                } else {
                    reset()
                }
            }
            .onDisappear { commitTask?.cancel() }
    }

    // MARK: Overlay

    @ViewBuilder
    private var overlay: some View {
        if !digits.isEmpty {
            LiveTVNumberOverlay(digits: digits, channel: match(for: digits))
                .transition(overlayTransition)
                .allowsHitTesting(false)
        }
    }

    private var reduceMotion: Bool { systemReduceMotion || model.settings.reduceMotion }

    private var animation: Animation? { reduceMotion ? nil : Tuna.Motion.snappy }

    private var overlayTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.9).combined(with: .opacity)
    }

    // MARK: Keys

    private func append(_ press: KeyPress) -> KeyPress.Result {
        guard isActive, !model.player.isPresented else { return .ignored }
        // ⌘1…⌘6 belong to the section shortcuts.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let typed = press.characters.filter { $0.isASCII && $0.isNumber }
        guard !typed.isEmpty else { return .ignored }
        let combined = String((digits + typed).prefix(ChannelNumberEntryModifier.maxDigits))
        withAnimation(animation) { digits = combined }
        scheduleCommit()
        return .handled
    }

    private func commitNow() -> KeyPress.Result {
        guard !digits.isEmpty else { return .ignored }
        commit()
        return .handled
    }

    private func cancel() -> KeyPress.Result {
        guard !digits.isEmpty else { return .ignored }
        reset()
        return .handled
    }

    private func deleteLast() -> KeyPress.Result {
        guard !digits.isEmpty else { return .ignored }
        var shorter = digits
        shorter.removeLast()
        withAnimation(animation) { digits = shorter }
        if shorter.isEmpty {
            commitTask?.cancel()
            commitTask = nil
        } else {
            scheduleCommit()
        }
        return .handled
    }

    // MARK: Commit

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: ChannelNumberEntryModifier.commitDelay)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        commitTask?.cancel()
        commitTask = nil
        let entered = digits
        withAnimation(animation) { digits = "" }
        guard let number = Int(entered) else { return }
        if let channel = index.channel(number: number, in: model.library, includeAdult: model.adultUnlocked) {
            model.play(channel)
        } else {
            model.showToast("No channel with number \(number)", style: .warning)
        }
    }

    private func reset() {
        commitTask?.cancel()
        commitTask = nil
        guard !digits.isEmpty else { return }
        withAnimation(animation) { digits = "" }
    }

    private func match(for digits: String) -> Channel? {
        guard let number = Int(digits) else { return nil }
        return index.channel(number: number, in: model.library, includeAdult: model.adultUnlocked)
    }
}

// MARK: - Number index

/// Channel number → channel, rebuilt lazily whenever the library snapshot changes. Showcase channels win
/// over Vault channels that share a number.
final class LiveTVChannelNumberIndex {
    private var libraryID: ObjectIdentifier?
    private var includesAdult = false
    private var byNumber: [Int: Channel] = [:]

    init() {}

    func channel(number: Int, in library: Library, includeAdult: Bool) -> Channel? {
        let id = ObjectIdentifier(library)
        if id != libraryID || includeAdult != includesAdult {
            rebuild(library, includeAdult: includeAdult)
            libraryID = id
            includesAdult = includeAdult
        }
        return byNumber[number]
    }

    private func rebuild(_ library: Library, includeAdult: Bool) {
        var map: [Int: Channel] = [:]
        for channel in library.liveShowcase { insert(channel, into: &map, includeAdult: includeAdult) }
        for channel in library.channels { insert(channel, into: &map, includeAdult: includeAdult) }
        byNumber = map
    }

    private func insert(_ channel: Channel, into map: inout [Int: Channel], includeAdult: Bool) {
        guard let number = channel.number, map[number] == nil else { return }
        guard includeAdult || !channel.isAdult else { return }
        map[number] = channel
    }
}

// MARK: - Overlay view

/// Big glass "Go to 104" panel with a live preview of the matching channel.
private struct LiveTVNumberOverlay: View {
    let digits: String
    let channel: Channel?

    var body: some View {
        VStack(spacing: 10) {
            Text("Go to")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Tuna.Palette.textSecondary)
            Text(digits)
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Tuna.Palette.textPrimary)
                .contentTransition(.numericText())
            match
            Text("Press ↩ to switch now · esc to cancel")
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textTertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 28)
        .frame(minWidth: 320)
        .tunaGlass(cornerRadius: 30)
        .shadow(color: Color.black.opacity(0.45), radius: 40, x: 0, y: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        guard let channel else { return "Go to channel " + digits }
        return "Go to channel " + digits + ", " + channel.name
    }

    @ViewBuilder
    private var match: some View {
        if let channel {
            HStack(spacing: 10) {
                LiveTVChannelLogo(channel: channel, width: 46, height: 32, cornerRadius: 7)
                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
            }
        } else {
            Text("No channel with this number yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tuna.Palette.textTertiary)
        }
    }
}
