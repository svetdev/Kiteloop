import SwiftUI
import WebKit

/// Thin SwiftUI wrapper that hosts a `WKWebView` owned by `WebPreviewViewModel`.
/// All behavior (loading, navigation policy, snapshots) lives on the view model;
/// this only puts the web content on screen.
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
