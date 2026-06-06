import Foundation
import SwiftUI
import WebKit

/// Picks one of the ~480 SVG illustrations bundled under
/// `Resources/SVG Graphics/` for the splash screen, biased to avoid
/// recently-shown picks so the user feels they get something new on
/// every launch instead of the same handful repeating.
///
/// The asset folder is auto-included via Xcode's synchronized group, so
/// the SVGs land flat in the bundle root — no subdirectory lookup, just
/// `Bundle.main.urls(forResourcesWithExtension: "svg", ...)` once at
/// process start.
enum SplashIllustration {

    /// Cached list of all SVG file URLs in the bundle, loaded lazily on
    /// first access. ~480 entries; the enumeration is cheap and runs
    /// once per process.
    private static let allURLs: [URL] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "svg", subdirectory: nil) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    private static let recentKey = "app.splash.illustration.recent"
    private static let recentCap = 20

    /// Returns a random illustration URL while avoiding the last 20
    /// shown. Updates the rolling history on each call. Returns `nil`
    /// only if the bundle somehow ships with zero SVGs.
    static func next() -> URL? {
        guard !allURLs.isEmpty else { return nil }

        let defaults = UserDefaults.standard
        let recent = defaults.stringArray(forKey: recentKey) ?? []
        let recentSet = Set(recent)

        let candidates = allURLs.filter { !recentSet.contains($0.lastPathComponent) }
        // If the user has somehow exhausted the avoid-list (only ever
        // happens when allURLs.count < recentCap, which it isn't, but
        // belt-and-braces), fall back to the full set.
        let pool = candidates.isEmpty ? allURLs : candidates

        guard let pick = pool.randomElement() else { return nil }

        var updated = recent
        updated.append(pick.lastPathComponent)
        if updated.count > recentCap {
            updated.removeFirst(updated.count - recentCap)
        }
        defaults.set(updated, forKey: recentKey)
        return pick
    }
}

/// Minimal SVG renderer for the splash. Uses WKWebView under the hood
/// because UIKit has no native SVG support and a WebView is the only
/// zero-dependency path that handles arbitrary SVG (gradients, clip
/// paths, filters — the Storyset illustrations use all three).
///
/// Locked down to be inert: no scrolling, no zoom, transparent
/// background, no script execution beyond the HTML shell. The shell
/// inlines the SVG bytes and a 4-line CSS reset that strips margin and
/// scales the artwork to fit the view bounds while preserving aspect.
struct SplashSVGView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false
        load(url: url, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(url: url, into: webView)
    }

    private func load(url: URL, into webView: WKWebView) {
        guard let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
        let html = """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;padding:0;background:transparent;height:100%;width:100%;
        display:flex;align-items:center;justify-content:center;overflow:hidden;}
        svg{width:100%;height:100%;display:block;}
        </style></head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }
}
