import AppKit
import SwiftUI
import WebKit

/// Renders an HTML fragment produced from Markdown inside a WebKit view styled to match
/// the native macOS diff pane.
struct MarkdownPreviewView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background so the SwiftUI container's textBackgroundColor shows through
        // without a white flash in Dark Mode.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(Self.wrapDocument(body: html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow the initial loadHTMLString; open clicked external links in the browser.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private static func wrapDocument(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          :root {
            color-scheme: light dark;
            --fg: #1f2328;
            --fg-muted: #656d76;
            --border: #d0d7de;
            --surface: #f6f8fa;
            --link: #0969da;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --fg: #e6edf3;
              --fg-muted: #8b949e;
              --border: #30363d;
              --surface: #161b22;
              --link: #58a6ff;
            }
          }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: var(--fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            font-size: 13.5px;
            line-height: 1.6;
            -webkit-font-smoothing: antialiased;
          }
          main {
            max-width: 820px;
            padding: 18px 24px 32px;
          }
          h1, h2, h3, h4, h5, h6 {
            margin-top: 1.3em;
            margin-bottom: 0.5em;
            font-weight: 600;
            line-height: 1.25;
          }
          h1:first-child, h2:first-child, h3:first-child, p:first-child {
            margin-top: 0;
          }
          h1 { font-size: 1.75em; padding-bottom: 0.25em; border-bottom: 1px solid var(--border); }
          h2 { font-size: 1.4em; padding-bottom: 0.2em; border-bottom: 1px solid var(--border); }
          h3 { font-size: 1.15em; }
          p, ul, ol, blockquote, table, pre {
            margin-top: 0;
            margin-bottom: 12px;
          }
          a { color: var(--link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code, pre {
            font-family: "SF Mono", ui-monospace, Menlo, monospace;
            font-size: 12px;
          }
          code {
            padding: 0.15em 0.35em;
            background: var(--surface);
            border-radius: 4px;
          }
          pre {
            padding: 12px 14px;
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 6px;
            overflow-x: auto;
            line-height: 1.45;
          }
          pre code {
            padding: 0;
            background: transparent;
            border-radius: 0;
          }
          blockquote {
            margin-left: 0;
            padding: 0 14px;
            color: var(--fg-muted);
            border-left: 3px solid var(--border);
          }
          ul, ol { padding-left: 22px; }
          li + li { margin-top: 3px; }
          hr {
            height: 1px;
            border: 0;
            background: var(--border);
            margin: 18px 0;
          }
          table {
            border-collapse: collapse;
            width: auto;
            max-width: 100%;
            display: block;
            overflow-x: auto;
          }
          th, td {
            padding: 6px 12px;
            border: 1px solid var(--border);
            text-align: left;
          }
          th {
            background: var(--surface);
            font-weight: 600;
          }
          img {
            max-width: 100%;
            height: auto;
          }
        </style>
        </head>
        <body>
        <main>\(body)</main>
        </body>
        </html>
        """
    }
}
