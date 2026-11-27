import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders an HTML fragment produced from Markdown inside a WebKit view styled to match
/// the native macOS diff pane.
struct MarkdownPreviewView: NSViewRepresentable {
    let html: String
    let repoRootPath: String?
    let filePath: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(repoRootPath: repoRootPath)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: RepoAssetSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background so the SwiftUI container's textBackgroundColor shows through
        // without a white flash in Dark Mode.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.schemeHandler.repoRootURL = repoRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let baseURL = Self.baseURL(for: filePath)
        guard context.coordinator.loadedHTML != html || context.coordinator.loadedBaseURL != baseURL else {
            return
        }
        context.coordinator.loadedHTML = html
        context.coordinator.loadedBaseURL = baseURL
        webView.loadHTMLString(Self.wrapDocument(body: html), baseURL: baseURL)
    }

    private static func baseURL(for filePath: String?) -> URL? {
        guard let root = URL(string: "\(RepoAssetSchemeHandler.scheme)://root/") else { return nil }
        guard let filePath, !filePath.isEmpty else { return root }
        let dir = (filePath as NSString).deletingLastPathComponent
        guard !dir.isEmpty, dir != "." else { return root }
        return root.appendingPathComponent(dir, isDirectory: true)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var loadedBaseURL: URL?
        let schemeHandler: RepoAssetSchemeHandler

        init(repoRootPath: String?) {
            let rootURL = repoRootPath.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }
            self.schemeHandler = RepoAssetSchemeHandler(repoRootURL: rootURL)
        }

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
            margin: 0 auto;
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

/// Serves relative repository assets (such as images referenced in README.md) to WKWebView
/// without running into file:// origin restrictions.
private final class RepoAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gitcraft-repo"
    var repoRootURL: URL?

    init(repoRootURL: URL?) {
        self.repoRootURL = repoRootURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let rootURL = repoRootURL,
              let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let relativePath = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: targetURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = UTType(filenameExtension: targetURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
