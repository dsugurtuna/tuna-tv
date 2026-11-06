import SwiftUI
import AppKit
import WebKit

/// Script message channel the embed page reports playback state on.
private let trailerMessageName = "tunaTrailer"

extension HeroCarousel {
    enum TrailerEvent: Equatable {
        case playing
        case ended
        case failed
    }

    /// YouTube trailer embed (youtube-nocookie) in a WKWebView.
    /// - Muted ambient mode: autoplays muted with no controls, covers its frame like a backdrop, never takes the
    ///   mouse (hit testing passes through, so hover/scroll keep working on the hero underneath).
    /// - Interactive mode (trailer lightbox): sound on, YouTube controls, letterboxed.
    /// Playback state is reported through the YouTube IFrame API so callers can fade the video in only once it
    /// really plays. Trailers always come from YouTube, never from the IPTV provider.
    struct TrailerWebView: NSViewRepresentable {
        let youtubeKey: String
        var muted: Bool
        var interactive: Bool
        var onEvent: ((TrailerEvent) -> Void)?

        init(youtubeKey: String, muted: Bool = true, interactive: Bool = false, onEvent: ((TrailerEvent) -> Void)? = nil) {
            self.youtubeKey = youtubeKey
            self.muted = muted
            self.interactive = interactive
            self.onEvent = onEvent
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> HostView {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(context.coordinator, name: trailerMessageName)

            let webView = HostView(frame: .zero, configuration: configuration)
            webView.passthrough = !interactive
            webView.allowsMagnification = false
            webView.allowsBackForwardNavigationGestures = false
            webView.underPageBackgroundColor = .black
            context.coordinator.onEvent = onEvent
            webView.loadHTMLString(
                Self.html(key: youtubeKey, muted: muted, interactive: interactive),
                baseURL: URL(string: "https://www.youtube-nocookie.com")
            )
            return webView
        }

        func updateNSView(_ webView: HostView, context: Context) {
            context.coordinator.onEvent = onEvent
            webView.passthrough = !interactive
        }

        static func dismantleNSView(_ webView: HostView, coordinator: Coordinator) {
            coordinator.onEvent = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: trailerMessageName)
            webView.stopLoading()
            // Tear the player down right away (stops audio even if WebKit keeps the view alive a little longer).
            webView.loadHTMLString("", baseURL: nil)
        }

        /// WKWebView that can let every mouse event through to the SwiftUI view underneath.
        final class HostView: WKWebView {
            var passthrough = true

            override func hitTest(_ point: NSPoint) -> NSView? {
                passthrough ? nil : super.hitTest(point)
            }
        }

        final class Coordinator: NSObject, WKScriptMessageHandler {
            var onEvent: ((TrailerEvent) -> Void)?

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? String else { return }
                switch body {
                case "playing":
                    onEvent?(.playing)
                case "ended":
                    onEvent?(.ended)
                default:
                    onEvent?(.failed)
                }
            }
        }

        /// Minimal embed page: the iframe from the spec plus the IFrame API hooked to it for state reporting.
        static func html(key rawKey: String, muted: Bool, interactive: Bool) -> String {
            let key = String(rawKey.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            let parameters = [
                "autoplay=1",
                "mute=\(muted ? 1 : 0)",
                "controls=\(interactive ? 1 : 0)",
                "loop=1",
                "playlist=\(key)",
                "modestbranding=1",
                "playsinline=1",
                "rel=0",
                "iv_load_policy=3",
                "disablekb=\(interactive ? 0 : 1)",
                "fs=\(interactive ? 1 : 0)",
                "enablejsapi=1",
                "origin=https%3A%2F%2Fwww.youtube-nocookie.com",
            ].joined(separator: "&")
            let source = "https://www.youtube-nocookie.com/embed/\(key)?\(parameters)"
            // Ambient: cover the frame like a backdrop (slightly over-scaled to hide letterboxing and the
            // player chrome). Interactive: fit inside the frame.
            let frameStyle = interactive
                ? "position:absolute;inset:0;width:100%;height:100%;border:0;"
                : "position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-width:177.78vh;min-height:100vh;"
                    + "transform:translate(-50%,-50%) scale(1.14);border:0;pointer-events:none;"
            let background = interactive ? "#000" : "transparent"
            return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:\(background);}
            #trailer{\(frameStyle)}
            </style>
            </head>
            <body>
            <iframe id="trailer" src="\(source)" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
            <script>
            function tunaPost(state){try{window.webkit.messageHandlers.\(trailerMessageName).postMessage(state);}catch(e){}}
            function onYouTubeIframeAPIReady(){
              new YT.Player('trailer',{events:{
                'onStateChange':function(e){if(e.data===1){tunaPost('playing');}else if(e.data===0){tunaPost('ended');}},
                'onError':function(){tunaPost('error');}
              }});
            }
            var api=document.createElement('script');
            api.src='https://www.youtube.com/iframe_api';
            api.onerror=function(){tunaPost('unavailable');};
            document.head.appendChild(api);
            </script>
            </body>
            </html>
            """
        }
    }
}
