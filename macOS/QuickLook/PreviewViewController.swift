import AppKit
import JavaScriptCore
import QuickLookUI
import UniformTypeIdentifiers

/// Returns static HTML for Finder to display in its own preview service. Embedding WKWebView in a
/// Quick Look extension makes WebKit's sandboxed helper processes crash; a data-based HTML reply is
/// the supported way to keep the app's rendered markup and CSS without a second live web process.
@objc(PreviewViewController)
final class PreviewViewController: QLPreviewProvider, QLPreviewingController {
    private enum PreviewError: Error {
        case missingResource(String)
        case rendererFailed(String)
        case invalidHTML
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let preference = ThemeSync.preference
        let data = try Self.previewData(for: request.fileURL, themePreference: preference)
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 820, height: 640)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return data
        }
        reply.title = request.fileURL.lastPathComponent
        return reply
    }

    /// Internal so the native harness can exercise the exact data handed to Finder without needing
    /// to construct the system-owned `QLFilePreviewRequest` type.
    static func previewData(for url: URL, themePreference: String) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let bundle = Bundle(for: PreviewViewController.self)
        let script = try resource(named: "markdown", extension: "js", bundle: bundle)
        let baseCSS = try resource(named: "native-preview", extension: "css", bundle: bundle)
        let themeCSS = try resource(named: "native-theme-overrides", extension: "css", bundle: bundle)
        let rendered = try render(markdown: markdown, script: script)
        let theme = resolvedTheme(themePreference)

        let html = """
        <!doctype html>
        <html lang="en" data-theme="\(theme)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
          <meta name="color-scheme" content="light dark">
          <style>\(baseCSS)\n\(themeCSS)</style>
        </head>
        <body><main class="markdown-body">\(rendered)</main></body>
        </html>
        """
        guard let data = html.data(using: .utf8) else { throw PreviewError.invalidHTML }
        return data
    }

    private static func render(markdown: String, script: String) throws -> String {
        guard let context = JSContext() else {
            throw PreviewError.rendererFailed("JavaScriptCore context creation failed")
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString() ?? "Unknown renderer exception"
        }
        context.evaluateScript(script)
        if let exceptionMessage { throw PreviewError.rendererFailed(exceptionMessage) }
        guard let renderer = context
            .objectForKeyedSubscript("MDViewerMarkdown")?
            .objectForKeyedSubscript("renderMarkdown"),
              let rendered = renderer.call(withArguments: [markdown])?.toString() else {
            throw PreviewError.rendererFailed("Markdown renderer was not exported")
        }
        if let exceptionMessage { throw PreviewError.rendererFailed(exceptionMessage) }
        return rendered
    }

    private static func resource(named name: String, extension fileExtension: String,
                                 bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Web") else {
            throw PreviewError.missingResource("\(name).\(fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func resolvedTheme(_ preference: String) -> String {
        switch preference {
        case ThemeSync.light, ThemeSync.dark:
            return preference
        default:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? ThemeSync.dark : ThemeSync.light
        }
    }
}
