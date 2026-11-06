import SwiftUI
import TunaCore
#if TUNA_ENGINE
import AetherEngine
#endif

/// Throwaway CI probe: proves XcodeGen + TunaCore + AetherEngine (Release) build, embed, sign and launch.
@main
struct ProbeApp: App {
    init() {
        let args = CommandLine.arguments
        if args.contains("--self-test") || args.contains("--snapshots") {
            #if TUNA_ENGINE
            print("AetherEngine version:", AetherEngine.version)
            let engine = try? AetherEngine()
            print("AetherEngine instance created:", engine != nil)
            #endif
            print("TunaCore ok:", StreamRef(providerID: "p", kind: .movie, streamID: "1").id)
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup { Text("Tuna TV probe") }
    }
}
