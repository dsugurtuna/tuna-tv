import SwiftUI
import AppKit
import TunaCore

/// `--snapshots <dir>`: renders the demo library's main screens to PNG files (CI), prints each path, exits.
/// Hard timeout 150 s (exit 1). Never crashes on missing data: shots without a suitable item still render.
@MainActor
enum SnapshotRunner {
    private static var windows: [NSWindow] = []

    private struct Shot {
        let name: String
        var size: CGSize = CGSize(width: 1600, height: 1000)
        let prepare: @MainActor (AppModel) -> Void
        let makeView: @MainActor () -> AnyView
    }

    static func owns(_ window: NSWindow) -> Bool { windows.contains { $0 === window } }

    static func start(outputDirectory: URL) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
            print("Snapshot run timed out after 150 s")
            exit(1)
        }
        Task { @MainActor in
            await run(outputDirectory)
            exit(0)
        }
    }

    private static func run(_ directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Cannot create \(directory.path): \(error)")
        }
        let model = AppModel(environment: .snapshot)
        await model.startDemo()
        print("Demo loaded: \(model.library.movies.count) movies, \(model.library.series.count) series, "
              + "\(model.library.channels.count) channels")
        for shot in shots(for: model) {
            reset(model)
            shot.prepare(model)
            await render(shot.makeView(), model: model, size: shot.size,
                         to: directory.appendingPathComponent("\(shot.name).png"))
        }
        reset(model)
    }

    private static func shots(for model: AppModel) -> [Shot] {
        let root: @MainActor () -> AnyView = { AnyView(RootView()) }
        let movie = model.library.showcase(.movie).first(where: { $0.bestQuality == .uhd })
            ?? model.library.showcase(.movie).first ?? model.library.movies.first
        let show = model.library.showcase(.series).first ?? model.library.series.first
        return [
            Shot(name: "01-home", prepare: { $0.router.section = .home }, makeView: root),
            Shot(name: "02-movies", prepare: { $0.router.section = .movies }, makeView: root),
            Shot(name: "03-series", prepare: { $0.router.section = .series }, makeView: root),
            Shot(name: "04-live", prepare: { $0.router.section = .live }, makeView: root),
            Shot(name: "05-guide", prepare: { $0.router.section = .live; $0.router.open(.guide) }, makeView: root),
            Shot(name: "06-detail-movie", prepare: { model in
                if let movie { model.router.open(.title(movie.id)) }
            }, makeView: root),
            Shot(name: "07-detail-series", prepare: { model in
                if let show { model.router.open(.title(show.id)) }
            }, makeView: root),
            Shot(name: "08-vault", prepare: { $0.router.section = .vault }, makeView: root),
            Shot(name: "09-vault-shelf", prepare: { model in
                model.router.section = .vault
                model.router.open(.vaultShelf(.disc))
            }, makeView: root),
            Shot(name: "10-search", prepare: { $0.router.isSearchPresented = true }, makeView: root),
            Shot(name: "11-insights", prepare: { $0.router.open(.insights) }, makeView: root),
            Shot(name: "12-onboarding", prepare: { _ in }, makeView: { AnyView(OnboardingView()) }),
            Shot(name: "13-settings", size: CGSize(width: 900, height: 640), prepare: { _ in },
                 makeView: { AnyView(SettingsView()) }),
            Shot(name: "14-player", prepare: { $0.player.isPresented = true }, makeView: root),
        ]
    }

    private static func reset(_ model: AppModel) {
        model.router.popToRoot()
        model.router.isSearchPresented = false
        model.router.isSettingsPresented = false
        model.router.section = .home
        model.player.isPresented = false
    }

    private static func render(_ view: AnyView, model: AppModel, size: CGSize, to url: URL) async {
        let content = view
            .environment(model)
            .preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height)
        let frame = NSRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hosting
        window.setFrameOrigin(.zero)
        windows.append(window)
        for other in NSApp.windows where !owns(other) { other.orderOut(nil) }
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        try? await Task.sleep(nanoseconds: 1_500_000_000) // images, staggered appearance, transitions

        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            windows.removeAll { $0 === window }
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("Could not capture \(url.lastPathComponent)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Could not encode \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url, options: .atomic)
            print(url.path)
        } catch {
            print("Could not write \(url.path): \(error)")
        }
    }
}
