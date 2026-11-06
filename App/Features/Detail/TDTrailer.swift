import SwiftUI
import AppKit
import WebKit
import TunaCore

/// Extracts a usable YouTube key ("dQw4w9WgXcQ") from a key or a YouTube URL. Demo keys ("demo-…") are rejected.
enum TDTrailerKey {
    static func extract(_ raw: String?) -> String? {
        guard var text = TDFormat.clean(raw) else { return nil }
        if text.lowercased().hasPrefix("demo-") { return nil }
        if let range = text.range(of: "v=") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "youtu.be/") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "/embed/") {
            text = String(text[range.upperBound...])
        }
        let key = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        guard key.count >= 6, key.count <= 20 else { return nil }
        return key
    }
}

/// Sheet with the trailer playing in a YouTube embed (trailers always come from YouTube, never the provider).
struct TDTrailerSheet: View {
    let trailer: Trailer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Tuna.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trailer.name)
                        .font(.headline)
                        .foregroundStyle(Tuna.Palette.textPrimary)
                        .lineLimit(1)
                    Text(trailer.type)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
                Spacer()
                if let url = trailer.watchURL {
                    GlassButton(title: "Open on YouTube", systemImage: "arrow.up.right.square", style: .secondary) {
                        NSWorkspace.shared.open(url)
                    }
                }
                GlassButton(title: nil, systemImage: "xmark", style: .icon) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            .padding(16)
            TDYouTubePlayer(videoKey: trailer.youtubeKey)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 540)
        .background(Tuna.Palette.background)
    }
}

/// WKWebView hosting a youtube-nocookie iframe (loaded from an HTML page with a proper origin so the embed
/// gets a referrer).
struct TDYouTubePlayer: NSViewRepresentable {
    let videoKey: String

    final class Coordinator {
        var loadedKey: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedKey != videoKey {
            load(into: webView, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedKey = videoKey
        let key = String(videoKey.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let source = "https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&rel=0&modestbranding=1&playsinline=1&fs=1"
            + "&origin=https%3A%2F%2Fwww.youtube-nocookie.com"
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#000;}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0;}</style></head>
        <body><iframe src="\(source)" title="Trailer" allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
        referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }
}
