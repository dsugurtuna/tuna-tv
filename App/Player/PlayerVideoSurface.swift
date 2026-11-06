import SwiftUI
#if TUNA_ENGINE
import AetherEngine
#endif

// The picture. Kept in its own file so it is the only view that imports AetherEngine (no name clashes with
// TunaCore types in the rest of the player UI).

#if TUNA_ENGINE
/// The engine's own representable, mounted once the single engine exists; black before that (demo, snapshots).
struct PlayerVideoSurface: View {
    let isReady: Bool

    var body: some View {
        if isReady, let engine = TunaPlaybackEngine.shared.aetherEngine {
            AetherPlayerSurface(engine: engine)
        } else {
            Color.black
        }
    }
}
#else
/// TunaTVCheck build: no engine, no picture.
struct PlayerVideoSurface: View {
    let isReady: Bool

    var body: some View {
        Color.black
    }
}
#endif
