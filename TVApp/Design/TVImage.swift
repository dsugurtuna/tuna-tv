import SwiftUI
import UIKit

/// Remote/demo/generative image (Apple TV port of the Mac TunaImage) with memory+disk cache, downsampling and per-host throttling.
/// - http(s)/file: ImagePipeline (provider panel hosts load one at a time, ≥1 s apart — see HostLimiter.Rule.providerImages)
/// - "demo://<kind>/<seed>": GenerativeArtwork (seed taken from the URL so a title's poster/backdrop match)
/// - nil / failure: GenerativeArtwork(kind, seed, title) — never a grey box.
/// The target pixel size is the laid-out size × backing scale (≥ 2), so every image is decoded at the size shown.
struct TVImage: View {
    var url: String?
    var kind: ArtworkKind
    var seed: String
    var title: String? = nil
    var contentMode: ContentMode = .fill
    /// Extra: small line under generative poster titles ("2019 · Drama").
    var caption: String? = nil
    /// Extra: where a `.fit` image (e.g. a logo) sits inside the frame; also used by generative logos.
    var alignment: Alignment = .center

    var body: some View {
        let source = DSImageSource(url)
        let artSeed = source.demoSeed ?? seed
        DSRemoteArtwork(source: source, kind: kind, seed: artSeed, alignment: alignment) { loaded in
            loaded.image
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: contentMode)
        } fallback: {
            GenerativeArtwork(kind: kind, seed: artSeed, title: title, caption: caption, alignment: alignment)
        }
    }
}

// MARK: - Source parsing

/// What a TunaImage URL string points at.
struct DSImageSource: Equatable {
    enum Resolved: Equatable {
        case none
        case demo(seed: String)
        case remote(URL)
    }

    let resolved: Resolved

    init(_ string: String?) {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            resolved = .none
            return
        }
        if raw.lowercased().hasPrefix("demo://") {
            let rest = raw.dropFirst("demo://".count)
            let seedPart: Substring
            if let slash = rest.firstIndex(of: "/") {
                seedPart = rest[rest.index(after: slash)...]
            } else {
                seedPart = rest
            }
            let decoded = String(seedPart).removingPercentEncoding ?? String(seedPart)
            resolved = .demo(seed: decoded.isEmpty ? raw : decoded)
            return
        }
        if let url = URL(string: raw), DSImageSource.isSupported(url) {
            resolved = .remote(url)
            return
        }
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded), DSImageSource.isSupported(url) {
            resolved = .remote(url)
            return
        }
        resolved = .none
    }

    var demoSeed: String? {
        if case .demo(let seed) = resolved { return seed }
        return nil
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return true }
        return (scheme == "http" || scheme == "https") && !(url.host ?? "").isEmpty
    }
}

// MARK: - Remote artwork

/// A loaded remote image plus its sampled colour traits (when available).
struct DSLoadedImage {
    let image: Image
    let traits: ImagePipeline.Traits?
}

/// Shared loader behind TunaImage (and the channel tiles): placeholder → fade-in image, or the fallback view
/// when there is no URL, a demo URL, or the load failed.
struct DSRemoteArtwork<Loaded: View, Fallback: View>: View {
    var source: DSImageSource
    var kind: ArtworkKind
    var seed: String
    var alignment: Alignment = .center
    @ViewBuilder var loaded: (DSLoadedImage) -> Loaded
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        switch source.resolved {
        case .none, .demo:
            fallback()
        case .remote(let url):
            GeometryReader { proxy in
                DSRemoteArtworkBody(url: url, kind: kind, seed: seed, size: proxy.size, alignment: alignment,
                                    loaded: loaded, fallback: fallback)
            }
        }
    }
}

private struct DSImageTaskID: Equatable {
    let url: URL
    let bucket: DSPixelBucket
}

private struct DSRemoteArtworkBody<Loaded: View, Fallback: View>: View {
    let url: URL
    let kind: ArtworkKind
    let seed: String
    let size: CGSize
    let alignment: Alignment
    let loaded: (DSLoadedImage) -> Loaded
    let fallback: () -> Fallback

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil
    @State private var imageURL: URL? = nil
    @State private var failedURL: URL? = nil

    private var pixelSize: CGSize {
        let scale = max(displayScale, 2)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        let shown = currentImage()
        ZStack {
            if let shown {
                loaded(DSLoadedImage(image: Image(uiImage: shown), traits: ImagePipeline.shared.traits(for: url)))
                    .frame(width: size.width, height: size.height, alignment: alignment)
                    .clipped()
                    .transition(.opacity)
            } else if failedURL == url {
                fallback()
                    .transition(.opacity)
            } else {
                DSArtworkPlaceholder(kind: kind, seed: seed)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: DSImageTaskID(url: url, bucket: DSPixelBucket(pixelSize))) {
            await load()
        }
    }

    /// The image to show right now: this URL's image, a memory-cache hit (no flash when cells are recreated), or the
    /// previous URL's image while the new one loads (smooth hero swaps).
    private func currentImage() -> UIImage? {
        if let image, imageURL == url { return image }
        if let cached = ImagePipeline.shared.cachedImage(for: url, targetPixelSize: pixelSize) { return cached }
        if let image, failedURL != url { return image }
        return nil
    }

    @MainActor
    private func load() async {
        let target = pixelSize
        guard target.width >= 1, target.height >= 1 else { return }
        if let cached = ImagePipeline.shared.cachedImage(for: url, targetPixelSize: target) {
            image = cached
            imageURL = url
            failedURL = nil
            return
        }
        let result = await ImagePipeline.shared.image(for: url, targetPixelSize: target)
        if Task.isCancelled { return }
        if let result {
            withAnimation(Tuna.Motion.imageFade) {
                image = result
                imageURL = url
                failedURL = nil
            }
        } else {
            withAnimation(Tuna.Motion.imageFade) { failedURL = url }
        }
    }
}

/// Calm, seed-tinted placeholder shown while a remote image loads.
struct DSArtworkPlaceholder: View {
    var kind: ArtworkKind
    var seed: String

    var body: some View {
        switch kind {
        case .logo, .studio:
            Color.clear
        case .person:
            Circle().fill(gradient).shimmering(active: true)
        case .poster, .backdrop, .still, .channel:
            Rectangle().fill(gradient).shimmering(active: true)
        }
    }

    private var gradient: LinearGradient {
        let palette = DSArtPalette.forSeed(seed)
        return LinearGradient(colors: [palette.sky[1].opacity(0.55), Tuna.Palette.surfaceElevated],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }
}
