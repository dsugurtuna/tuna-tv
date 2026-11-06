import SwiftUI
import AppKit
import TunaCore

@main
struct TunaTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Runs before any AppModel or window exists.
        if AppLaunchOptions.isSelfTest { SelfTest.runAndExit() }
        _model = State(initialValue: AppModel(environment: AppLaunchOptions.environment))
    }

    var body: some Scene {
        WindowGroup("Tuna TV", id: "main") {
            if AppLaunchOptions.isSnapshotRun {
                // The snapshot runner renders its own offscreen windows.
                Color.black.frame(width: 320, height: 200)
            } else {
                RootView()
                    .environment(model)
                    .frame(minWidth: 1120, minHeight: 720)
                    .preferredColorScheme(.dark)
                    .task { await model.start() }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { TunaCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct TunaCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Go") {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.router.select(section) }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
            }
            Divider()
            Button("Search…") { model.router.isSearchPresented = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Back") { model.router.back() }
                .keyboardShortcut("[", modifiers: .command)
        }
        CommandMenu("Library") {
            Button("Refresh Library") { Task { await model.refreshCatalog(force: false) } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Try the Demo") { Task { await model.startDemo() } }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let directory = AppLaunchOptions.snapshotDirectory else { return }
        hideNormalWindows()
        DispatchQueue.main.async { [weak self] in self?.hideNormalWindows() }
        SnapshotRunner.start(outputDirectory: directory)
    }

    private func hideNormalWindows() {
        for window in NSApp.windows where !SnapshotRunner.owns(window) {
            window.orderOut(nil)
        }
    }
}
