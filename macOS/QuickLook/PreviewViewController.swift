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
        let baseCSS = try resource(named: "native-preview", extension: "css", bundle: bundle)
        let themeCSS = try resource(named: "native-theme-overrides", extension: "css", bundle: bundle)
        let rendered = try render(markdown: markdown, bundle: bundle)
        let theme = resolvedTheme(themePreference)

        let html = """
        <!doctype html>
        <html lang="en" data-theme="\(theme)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
          <meta name="color-scheme" content="light dark">
          <style>\(baseCSS)\n\(themeCSS)\n\(rendered.mathCSS)</style>
        </head>
        <body><main class="markdown-body">\(rendered.html)</main></body>
        </html>
        """
        guard let data = html.data(using: .utf8) else { throw PreviewError.invalidHTML }
        return data
    }

    /// Renders the Markdown and, when the document contains math, typesets it in the same context.
    /// Finder displays this reply as static data and never runs its scripts, so a formula that is not
    /// already SVG here is a formula the reader never sees.
    private static func render(markdown: String, bundle: Bundle) throws -> (html: String, mathCSS: String) {
        guard let context = JSContext() else {
            throw PreviewError.rendererFailed("JavaScriptCore context creation failed")
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString() ?? "Unknown renderer exception"
        }
        func evaluate(_ source: String, _ label: String) throws {
            exceptionMessage = nil
            context.evaluateScript(source)
            if let exceptionMessage { throw PreviewError.rendererFailed("\(label): \(exceptionMessage)") }
        }
        func value(of expression: String, _ label: String) throws -> JSValue {
            exceptionMessage = nil
            let result = context.evaluateScript(expression)
            if let exceptionMessage { throw PreviewError.rendererFailed("\(label): \(exceptionMessage)") }
            guard let result else { throw PreviewError.rendererFailed("\(label) produced no value") }
            return result
        }

        try evaluate(resource(named: "markdown", extension: "js", bundle: bundle), "markdown.js")
        try evaluate(resource(named: "math", extension: "js", bundle: bundle), "math.js")

        exceptionMessage = nil
        guard let renderer = context
            .objectForKeyedSubscript("MDViewerMarkdown")?
            .objectForKeyedSubscript("renderMarkdown"),
              let rendered = renderer.call(withArguments: [markdown])?.toString() else {
            throw PreviewError.rendererFailed("Markdown renderer was not exported")
        }
        if let exceptionMessage { throw PreviewError.rendererFailed(exceptionMessage) }
        guard rendered.contains("class=\"math math-") else { return (rendered, "") }

        try loadMathJax(into: context, bundle: bundle, evaluate: evaluate)
        // A component bundle that half-loads would otherwise surface as an unrelated failure inside
        // the typesetter, so confirm the entry point exists before reaching for it.
        guard try value(of: "typeof MathJax.tex2svg === 'function'", "MathJax startup").toBool() else {
            throw PreviewError.rendererFailed("MathJax did not finish loading")
        }

        exceptionMessage = nil
        guard let typesetter = context
            .objectForKeyedSubscript("MDViewerMath")?
            .objectForKeyedSubscript("typesetHTML"),
              let typeset = typesetter.call(withArguments: [rendered])?.toString() else {
            throw PreviewError.rendererFailed("Math typesetter was not exported")
        }
        if let exceptionMessage { throw PreviewError.rendererFailed(exceptionMessage) }
        guard let css = try value(of: "MDViewerMath.stylesheetText()", "MathJax stylesheet").toString() else {
            throw PreviewError.rendererFailed("MathJax produced no stylesheet")
        }
        return (typeset, css)
    }

    /// Boots MathJax inside a bare `JSContext`. There is no DOM and no `require`, so the component
    /// loader is handed a native one and the DOM-free `liteDOM` adaptor. See `vendor/mathjax/README.md`
    /// for why the prebuilt `tex-svg.js` bundle cannot be used here.
    private static func loadMathJax(into context: JSContext, bundle: Bundle,
                                    evaluate: (String, String) throws -> Void) throws {
        guard let directory = bundle.resourceURL?.appendingPathComponent("Web/mathjax"),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("startup.js").path) else {
            throw PreviewError.missingResource("Web/mathjax")
        }

        // Non-nil by construction: the block only runs while JavaScript is calling into it.
        let loadComponent: @convention(block) (String) -> Void = { path in
            let current = JSContext.current()!
            let url = URL(fileURLWithPath: path)
            do {
                current.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
            } catch {
                current.exception = JSValue(newErrorFromMessage: "MathJax component \(path) is unreadable: \(error)",
                                            in: current)
            }
        }
        context.setObject(loadComponent, forKeyedSubscript: "mdviewerLoadMathJaxComponent" as NSString)
        context.setObject(directory.path, forKeyedSubscript: "mdviewerMathJaxDirectory" as NSString)

        try evaluate("""
        globalThis.MathJax = MDViewerMath.mathJaxConfig({
          paths: { mathjax: mdviewerMathJaxDirectory },
          require: (file) => mdviewerLoadMathJaxComponent(file),
          load: ["adaptors/liteDOM", "input/tex-full", "output/svg"]
        });
        """, "MathJax configuration")
        // Every component is loaded synchronously through the native loader, and JavaScriptCore
        // drains its microtask queue as each API call returns, so MathJax has started up by the time
        // this returns rather than at some later turn of a run loop that a Quick Look reply never has.
        try evaluate(String(contentsOf: directory.appendingPathComponent("startup.js"), encoding: .utf8),
                     "MathJax startup.js")
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
