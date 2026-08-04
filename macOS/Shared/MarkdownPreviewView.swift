import AppKit
import WebKit

protocol MarkdownPreviewViewDelegate: AnyObject {
    /// The user clicked a relative Markdown link. The receiver should load the file in-place.
    func previewView(_ view: MarkdownPreviewView, openLinkedFile url: URL)
}

final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var pendingMarkdown = ""
    private var sourceURL: URL?
    private var theme = "light"
    private var renderCompletion: ((Error?) -> Void)?
    /// The template page is loaded once and then reused for every later render.
    private var isTemplateLoaded = false
    private var preservesScrollOnLoad = false
    /// Source line the host wants kept in view; `nil` leaves the scroll position alone.
    private var pendingFocusLine: Int?

    /// Weak proxy so the message handler does not retain the view (avoids the WKWebView retain cycle).
    private final class LinkMessageProxy: NSObject, WKScriptMessageHandler {
        weak var view: MarkdownPreviewView?
        init(_ view: MarkdownPreviewView) { self.view = view }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            view?.handleLinkMessage(message)
        }
    }

    enum PreviewError: Error { case missingTemplate, scriptEvaluationFailed, superseded }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Register the link bridge through a weak proxy so the page can hand us raw hrefs.
        webView.configuration.userContentController.add(LinkMessageProxy(self), name: "link")
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `markdown` in the preview.
    ///
    /// After the first call the template page stays loaded and the new source is pushed straight
    /// into it, which is what makes live preview usable while typing: no reload flash, and
    /// `preservingScroll` keeps the reader where they were. The Markdown is handed to the page as a
    /// *function argument* rather than spliced into script source, so a multi-megabyte document
    /// costs one string copy instead of a multi-megabyte script parse.
    func render(markdown: String, sourceURL: URL?, preservingScroll: Bool = false,
                focusLine: Int? = nil, completion: ((Error?) -> Void)? = nil) {
        pendingMarkdown = markdown
        self.sourceURL = sourceURL
        pendingFocusLine = focusLine
        renderCompletion?(PreviewError.superseded)
        renderCompletion = completion

        if isTemplateLoaded {
            paint(preservingScroll: preservingScroll)
            return
        }
        guard let templateURL = Bundle(for: MarkdownPreviewView.self).url(forResource: "preview", withExtension: "html", subdirectory: "Web") else {
            finishRendering(PreviewError.missingTemplate)
            return
        }
        preservesScrollOnLoad = preservingScroll
        webView.loadFileURL(templateURL, allowingReadAccessTo: templateURL.deletingLastPathComponent())
    }

    private func paint(preservingScroll: Bool) {
        // Set the theme before painting content so there is no flash; content only appears once
        // renderMarkdown runs. A focus line re-anchors the view on the block being edited, which
        // matters after a re-render because the old scroll offset may point somewhere else entirely.
        let body = """
        document.documentElement.dataset.theme = theme;
        const offset = keepScroll ? window.scrollY : 0;
        window.renderMarkdown(markdown);
        window.scrollTo(0, offset);
        if (focusLine >= 0) window.scrollToSourceLine(focusLine);
        return true;
        """
        webView.callAsyncJavaScript(
            body,
            arguments: [
                "markdown": pendingMarkdown,
                "theme": theme,
                "keepScroll": preservingScroll,
                "focusLine": pendingFocusLine ?? -1
            ],
            in: nil,
            in: .page
        ) { [weak self] result in
            switch result {
            case .success: self?.finishRendering(nil)
            case .failure(let error): self?.finishRendering(error)
            }
        }
    }

    /// Points the preview at the block that owns `sourceLine`, without re-rendering. Scrolls only
    /// when that block is off-screen, so it does not fight the reader.
    func focus(sourceLine: Int) {
        pendingFocusLine = sourceLine
        guard isTemplateLoaded else { return }
        webView.callAsyncJavaScript("window.scrollToSourceLine(line); return true;",
                                    arguments: ["line": sourceLine], in: nil, in: .page)
    }

    /// Force the preview to a theme ("light"/"dark"). Applied live and re-applied on each render in
    /// `didFinish`, so it takes effect even when set before the page has loaded.
    func setTheme(_ theme: String) {
        self.theme = (theme == "dark") ? "dark" : "light"
        applyThemeToPage()
    }

    private func applyThemeToPage() {
        guard let data = try? JSONSerialization.data(withJSONObject: [theme]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.documentElement.dataset.theme=\(json)[0];")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isTemplateLoaded = true
        paint(preservingScroll: preservesScrollOnLoad)
        preservesScrollOnLoad = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishRendering(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishRendering(error)
    }

    private func finishRendering(_ error: Error?) {
        let completion = renderCompletion
        renderCompletion = nil
        completion?(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Link clicks are intercepted in JS and handled via the "link" message handler; any link
        // navigation that still reaches here is cancelled so the webview never navigates on its own.
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - Link bridge

    weak var linkDelegate: MarkdownPreviewViewDelegate?

    private func handleLinkMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let href = body["href"] as? String, !href.isEmpty else { return }
        handleLink(href: href)
    }

    private func handleLink(href: String) {
        let decoded = href.removingPercentEncoding ?? href

        if decoded.hasPrefix("#") {
            scrollToAnchor(String(decoded.dropFirst()))
            return
        }

        // Any explicit non-file scheme (http/https/mailto/tel/…) goes to the system handler.
        if let url = URL(string: decoded), let scheme = url.scheme?.lowercased(), scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }

        // Relative or absolute path: resolve against the document's directory.
        guard let sourceURL else { return }
        let resolved = URL(fileURLWithPath: decoded, relativeTo: sourceURL.deletingLastPathComponent()).standardizedFileURL
        let ext = resolved.pathExtension.lowercased()
        let isMarkdown = ["md", "markdown", "mdown", "mkd", "txt"].contains(ext)
        if isMarkdown, FileManager.default.fileExists(atPath: resolved.path) {
            linkDelegate?.previewView(self, openLinkedFile: resolved)
        } else {
            NSWorkspace.shared.open(resolved)
        }
    }

    private func scrollToAnchor(_ fragment: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [fragment]),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "var e=document.getElementById(\(json)[0]); if(e){e.scrollIntoView({behavior:'smooth',block:'start'});}"
        webView.evaluateJavaScript(script)
    }
}
