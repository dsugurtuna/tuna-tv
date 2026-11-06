import SwiftUI
import AppKit
import TunaCore

/// Full-window player. Present it over everything while `model.player.isPresented` is true, e.g.
/// `if model.player.isPresented { PlayerView().transition(.opacity) }`.
struct PlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PlayerScreen(player: model.player, app: model)
    }
}

/// Mouse-activity timestamp kept outside SwiftUI state, so mouse movement never re-renders the player.
@MainActor
final class PlayerActivityClock {
    var lastActivity = Date()
}

struct PlayerScreen: View {
    let player: PlayerModel
    let app: AppModel

    @State private var controlsVisible = true
    @State private var activity = PlayerActivityClock()
    @State private var showTech = false
    @State private var hoveringControls = false
    @State private var zapStripVisible = false
    @State private var zapStripTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            PlayerVideoSurface(isReady: player.hasEngineSurface)
                .opacity(player.isPictureInPicture ? 0 : 1)
            tapLayer
            SubtitleOverlay(player: player, liftedForControls: showsControls)
            PlayerStatusLayer(player: player, app: app)
            if showsControls {
                PlayerControlsOverlay(player: player, app: app, showTech: $showTech, hoveringControls: $hoveringControls)
                    .transition(.opacity)
            }
            overlays
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { noteActivity() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .upArrow, .downArrow, .escape], phases: [.down, .repeat]) { press in
            handleKey(press)
        }
        .onKeyPress(characters: .letters, phases: .down) { press in
            handleCharacters(press.characters)
        }
        .onAppear { focused = true }
        .task { await autoHideLoop() }
        .onDisappear {
            zapStripTask?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        .animation(.easeInOut(duration: 0.3), value: showsControls)
        .animation(Tuna.Motion.snappy, value: showTech)
        .animation(Tuna.Motion.snappy, value: zapStripShown)
        .animation(Tuna.Motion.page, value: player.upNext)
    }

    // MARK: Layers

    /// Click toggles play/pause, double-click toggles full screen.
    private var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .onTapGesture(count: 1) {
                focused = true
                noteActivity()
                player.togglePlayPause()
            }
    }

    @ViewBuilder
    private var overlays: some View {
        if zapStripShown {
            ZapStrip(player: player, app: app)
                .padding(.bottom, showsControls ? 150 : 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if let next = player.upNext {
            UpNextCard(next: next,
                       countdown: player.upNextCountdown,
                       total: max(1, app.settings.playback.upNextCountdown),
                       onPlay: { player.playUpNext() },
                       onCancel: { player.cancelUpNext() })
                .padding(.trailing, 36)
                .padding(.bottom, showsControls ? 170 : 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        if showTech {
            TechPanel(player: player, onClose: { showTech = false })
                .padding(.top, 96)
                .padding(.trailing, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    // MARK: Visibility rules

    private var showsControls: Bool { controlsVisible || pinsControls }

    /// Controls stay up unless something is actually playing.
    private var pinsControls: Bool {
        switch player.status {
        case .playing, .buffering: return false
        default: return true
        }
    }

    private var zapStripShown: Bool {
        player.isLive && (zapStripVisible || player.pendingZap != nil)
    }

    private func noteActivity() {
        activity.lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    /// Hides the chrome (and the cursor) after 3 s without mouse movement while playing.
    private func autoHideLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard controlsVisible, !pinsControls, !showTech, !hoveringControls else { continue }
            if Date().timeIntervalSince(activity.lastActivity) >= 3 {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private func revealZapStrip() {
        zapStripVisible = true
        zapStripTask?.cancel()
        zapStripTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            zapStripVisible = false
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        noteActivity()
        let isRepeat = press.phase == .repeat
        let key = press.key
        if key == .space {
            if !isRepeat { player.togglePlayPause() }
        } else if key == .leftArrow {
            guard !player.isLive else { return .ignored }
            player.skip(by: -10)
        } else if key == .rightArrow {
            guard !player.isLive else { return .ignored }
            player.skip(by: 10)
        } else if key == .upArrow {
            if player.isLive {
                player.zapPrevious()
                revealZapStrip()
            } else {
                changeVolume(by: 0.1)
            }
        } else if key == .downArrow {
            if player.isLive {
                player.zapNext()
                revealZapStrip()
            } else {
                changeVolume(by: -0.1)
            }
        } else if key == .escape {
            guard !isRepeat else { return .handled }
            if showTech {
                showTech = false
            } else {
                player.dismiss()
            }
        } else {
            return .ignored
        }
        return .handled
    }

    private func handleCharacters(_ characters: String) -> KeyPress.Result {
        switch characters.lowercased() {
        case "f":
            NSApp.keyWindow?.toggleFullScreen(nil)
        case "m":
            player.isMuted.toggle()
        case "i":
            showTech.toggle()
        case "l":
            player.goLive()
        default:
            return .ignored
        }
        noteActivity()
        return .handled
    }

    private func changeVolume(by delta: Double) {
        let next = min(1, max(0, player.volume + delta))
        player.volume = next
        if next > 0, player.isMuted { player.isMuted = false }
    }
}
