import AppKit
import WebKit

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

_ = NSApplication.shared
guard CommandLine.arguments.count == 2 else {
    fatalError("Expected a Markdown fixture path")
}
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let controller = DocumentViewController()
controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
controller.open(url: fixtureURL)
// UserDefaults is empty on a fresh CI runner, so the controller starts in minimal Preview mode.
// That mode deliberately removes the editor pane from the split view. Establish Split before
// inspecting both panes so this smoke test does not depend on preferences left on the host.
controller.setMode(.split)
controller.view.layoutSubtreeIfNeeded()

let views = descendants(of: controller.view)
guard let editor = views.compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }) else {
    fatalError("Edit tab has no editable NSTextView")
}
guard editor.string.contains("Offline guarantee") else {
    fatalError("Editor did not receive the opened file's Markdown source")
}
guard let modeControl = views.compactMap({ $0 as? NSSegmentedControl })
    .first(where: { $0.segmentCount == 3 && $0.label(forSegment: 0) == "Preview" }) else {
    fatalError("Preview/Split/Editor control is missing")
}
guard modeControl.label(forSegment: 1) == "Split", modeControl.label(forSegment: 2) == "Editor" else {
    fatalError("Mode control segments are not Preview/Split/Editor")
}
guard let toolbar = modeControl.superview as? NSStackView else {
    fatalError("Mode control is not in the app toolbar")
}

guard let splitView = views.compactMap({ $0 as? NSSplitView }).first else {
    fatalError("Content area is not a split view")
}
guard let previewPane = views.compactMap({ $0 as? WKWebView }).first else {
    fatalError("There is no preview web view")
}
guard splitView.isVertical else {
    fatalError("The preview must sit beside the editor, not below it")
}
guard let editorScrollView = editor.enclosingScrollView else {
    fatalError("Editor is not in a scroll view")
}

func layout() { controller.view.layoutSubtreeIfNeeded() }
// A pane that is not in the window's tree at all counts as zero width — single-pane modes remove
// the other pane from the split view rather than hiding it.
func visibleWidth(_ view: NSView) -> CGFloat {
    guard view.isDescendant(of: controller.view), !view.isHiddenOrHasHiddenAncestor else { return 0 }
    return view.frame.width
}

// --- Split: both panes share the width, editor on the left, roughly 55/45 by default.
controller.setMode(.split)
layout()
let splitWidth = splitView.bounds.width
guard visibleWidth(editorScrollView) > 200, visibleWidth(previewPane) > 200 else {
    fatalError("Split does not show both panes: editor \(visibleWidth(editorScrollView)), preview \(visibleWidth(previewPane))")
}
guard editorScrollView.convert(editorScrollView.bounds, to: splitView).minX
        < previewPane.convert(previewPane.bounds, to: splitView).minX else {
    fatalError("Preview is not on the right of the editor")
}
guard abs(editorScrollView.frame.width / splitWidth - 0.55) < 0.05 else {
    fatalError("Default split is not roughly 55/45: editor \(editorScrollView.frame.width) of \(splitWidth)")
}

// --- Editor: the source takes the whole window. No sliver of preview may survive.
controller.setMode(.editor)
layout()
guard visibleWidth(previewPane) == 0 else {
    fatalError("Editor mode still shows \(visibleWidth(previewPane))pt of preview")
}
guard controller.splitView(splitView, shouldHideDividerAt: 0) else {
    fatalError("Editor mode still asks NSSplitView to draw its divider")
}
guard editorScrollView.frame.width == splitWidth else {
    fatalError("Editor mode leaves \(splitWidth - editorScrollView.frame.width)pt of divider showing")
}

// --- Preview: the rendered document takes the whole window.
controller.setMode(.preview)
layout()
guard toolbar.isHidden, toolbar.frame.height == 0 else {
    fatalError("Preview is not minimal: toolbar remains visible at \(toolbar.frame.height)pt")
}
guard visibleWidth(editorScrollView) == 0 else {
    fatalError("Preview mode still shows \(visibleWidth(editorScrollView))pt of editor")
}
guard controller.splitView(splitView, shouldHideDividerAt: 0) else {
    fatalError("Preview mode still asks NSSplitView to draw its divider")
}
guard previewPane.frame.width == splitWidth else {
    fatalError("Preview mode leaves \(splitWidth - previewPane.frame.width)pt of divider showing")
}

// --- The cycle follows the reading workflow: Preview -> Editor -> Split -> Preview.
controller.cycleMode()
guard controller.mode == .editor else { fatalError("Preview did not cycle to Editor") }
controller.cycleMode()
guard controller.mode == .split else { fatalError("Editor did not cycle to Split") }
controller.cycleMode()
layout()
guard controller.mode == .preview, toolbar.isHidden else {
    fatalError("Split did not cycle back to minimal Preview")
}

// --- Opening another file must not silently change the mode.
controller.setMode(.editor)
layout()
controller.open(url: fixtureURL)
layout()
guard controller.mode == .editor, visibleWidth(previewPane) == 0 else {
    fatalError("Opening a file reset the mode to \(controller.mode)")
}

// --- The Show Preview action flips Editor <-> Split and restores the divider position.
controller.togglePreviewPane()
layout()
guard controller.mode == .split, visibleWidth(previewPane) > 200 else {
    fatalError("Toggle did not restore the split")
}
guard abs(editorScrollView.frame.width / splitWidth - 0.55) < 0.05 else {
    fatalError("Toggle lost the divider position: editor \(editorScrollView.frame.width) of \(splitWidth)")
}
controller.togglePreviewPane()
layout()
guard controller.mode == .editor, visibleWidth(previewPane) == 0 else {
    fatalError("Toggle did not return to a full-width editor")
}

controller.setMode(.split)
layout()
print("Native editor smoke test passed: split \(Int(editorScrollView.frame.width))/\(Int(previewPane.frame.width)), "
      + "Preview and Editor both full width, mode survives open")

// Window-title preference is immediate and reversible from Settings or the quick menu.
let titleController = DocumentViewController()
let titleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                           styleMask: [.titled], backing: .buffered, defer: false)
titleWindow.contentViewController = titleController
titleController.open(url: fixtureURL)
let originalTitlePreference = titleController.showsFullPathInTitle
titleController.setShowsFullPathInTitle(false)
guard titleWindow.title == fixtureURL.lastPathComponent else {
    fatalError("Filename title preference produced \(titleWindow.title)")
}
titleController.setShowsFullPathInTitle(true)
guard titleWindow.title == fixtureURL.path else {
    fatalError("Full-path title preference produced \(titleWindow.title)")
}
titleController.setShowsFullPathInTitle(originalTitlePreference)
print("Window title preference smoke test passed: filename and full path")

// The WKWebView preview is the path the editor and the split pane actually use. Render a document
// whose delimiter row is the short GitHub form (`--:`) and confirm a real table reaches the DOM.
let tableDocument = """
## Install the macOS app

```bash
./macOS/install.sh
```

| variant | H | min ms |
|---------|--:|-------:|
| dense c32d1 (ref) | — | 2.286 |
| **resnet 8x4** | 8 | **2.427** |
"""
var renderError: Error?
var renderFinished = false
let standalonePreview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
standalonePreview.render(markdown: tableDocument, sourceURL: nil) { error in
    renderError = error
    renderFinished = true
}
let renderDeadline = Date().addingTimeInterval(20)
while !renderFinished, Date() < renderDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard renderFinished, renderError == nil else {
    fatalError("Live preview did not render: \(String(describing: renderError))")
}

guard let previewWebView = descendants(of: standalonePreview).compactMap({ $0 as? WKWebView }).first else {
    fatalError("Preview has no web view")
}
var renderedTableCells: Int?
previewWebView.evaluateJavaScript("document.querySelectorAll('table td').length") { value, _ in
    renderedTableCells = value as? Int
}
let queryDeadline = Date().addingTimeInterval(10)
while renderedTableCells == nil, Date() < queryDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard let renderedTableCells, renderedTableCells == 6 else {
    fatalError("Live preview did not render the table: \(String(describing: renderedTableCells)) cells")
}
print("Live preview smoke test passed: \(renderedTableCells) table cells rendered")

// A forced Light theme must not apply the pale inline-code chip to a fenced code block. That made
// commands such as the README install snippet nearly invisible in Preview.
standalonePreview.setTheme(ThemeSync.light)
var fencedCodeStyle: [String: Any]?
previewWebView.evaluateJavaScript("""
(() => {
  const code = document.querySelector('pre code');
  const pre = code && code.closest('pre');
  if (!code || !pre) return null;
  return {
    text: code.textContent,
    background: getComputedStyle(code).backgroundColor,
    color: getComputedStyle(code).color,
    preColor: getComputedStyle(pre).color
  };
})()
""") { value, _ in
    fencedCodeStyle = value as? [String: Any]
}
let styleDeadline = Date().addingTimeInterval(10)
while fencedCodeStyle == nil, Date() < styleDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard fencedCodeStyle?["text"] as? String == "./macOS/install.sh",
      fencedCodeStyle?["background"] as? String == "rgba(0, 0, 0, 0)",
      fencedCodeStyle?["color"] as? String == fencedCodeStyle?["preColor"] as? String else {
    fatalError("Light-theme fenced code has the wrong style: \(String(describing: fencedCodeStyle))")
}
print("Fenced code theme smoke test passed: README install command remains legible in Light")

// Caret sync: pointing the preview at a source line must mark the block that owns that line.
var syncDocumentRendered = false
standalonePreview.render(markdown: "# Title\n\nFirst paragraph.\n\n- item one\n- item two\n\nLast paragraph.",
                         sourceURL: nil) { _ in syncDocumentRendered = true }
let syncDeadline = Date().addingTimeInterval(20)
while !syncDocumentRendered, Date() < syncDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard syncDocumentRendered else { fatalError("Sync fixture did not render") }

func activeBlockText(forCaretOn line: Int) -> String {
    standalonePreview.focus(sourceLine: line)
    var text: String?
    // The focus call and this read are queued on the same page, so the read observes the result.
    previewWebView.evaluateJavaScript("(document.querySelector('.source-active') || {}).tagName || 'none'") { value, _ in
        text = value as? String
    }
    let deadline = Date().addingTimeInterval(10)
    while text == nil, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let text else { fatalError("Preview did not answer which block is active") }
    return text
}

// Line 0 is the heading, line 2 the first paragraph, line 5 the second list item.
for (line, expected) in [(0, "H1"), (2, "P"), (5, "LI")] {
    let actual = activeBlockText(forCaretOn: line)
    guard actual == expected else {
        fatalError("Caret on line \(line) marked <\(actual)>, expected <\(expected)>")
    }
}
print("Caret sync smoke test passed: heading, paragraph and list item all resolved")

// Quick Look receives static HTML rather than embedding WKWebView in its sandbox. Load the exact
// reply data here to verify that Finder gets the shared markup, CSS, and explicit Dark palette.
let quickLookData = try PreviewViewController.previewData(
    for: fixtureURL, themePreference: ThemeSync.dark
)
guard let quickLookHTML = String(data: quickLookData, encoding: .utf8),
      quickLookHTML.contains("data-theme=\"dark\""),
      quickLookHTML.contains("Offline guarantee") else {
    fatalError("Quick Look did not generate a complete static HTML reply")
}
let quickLookWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
quickLookWebView.loadHTMLString(quickLookHTML, baseURL: nil)
var quickLookPage: [String: Any]?
let quickLookQueryDeadline = Date().addingTimeInterval(10)
while (quickLookPage?["text"] as? String)?.contains("Offline guarantee") != true,
      Date() < quickLookQueryDeadline {
    quickLookPage = nil
    quickLookWebView.evaluateJavaScript("""
(() => ({
  text: document.body.innerText,
  theme: document.documentElement.dataset.theme,
  background: getComputedStyle(document.body).backgroundColor,
  maxWidth: getComputedStyle(document.querySelector('.markdown-body')).maxWidth
}))()
""") { value, _ in
        quickLookPage = value as? [String: Any]
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard (quickLookPage?["text"] as? String)?.contains("Offline guarantee") == true,
      quickLookPage?["theme"] as? String == ThemeSync.dark,
      quickLookPage?["background"] as? String == "rgb(25, 28, 35)",
      quickLookPage?["maxWidth"] as? String == "920px" else {
    fatalError("Quick Look does not match the opened-file preview: \(String(describing: quickLookPage))")
}
print("Quick Look data-preview smoke test passed: shared renderer, layout, and Dark theme")

// --- LaTeX. The live preview types math in its web view; Quick Look cannot, because Finder shows
// the reply as static data with scripts disabled, so the extension pre-renders through
// JavaScriptCore. Both paths must end up with real SVG and no leftover TeX.
let mathDocument = """
Inline $e^{i\\pi} + 1 = 0$ stays in the sentence.

$$
\\frac{\\partial u}{\\partial t} = h^2 \\nabla^2 u
$$

Prices like $5 and $10 are not math.
"""

var mathRenderError: Error?
var mathRenderFinished = false
standalonePreview.render(markdown: mathDocument, sourceURL: nil) { error in
    mathRenderError = error
    mathRenderFinished = true
}
let mathDeadline = Date().addingTimeInterval(30)
while !mathRenderFinished, Date() < mathDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard mathRenderFinished, mathRenderError == nil else {
    fatalError("Live preview did not render math: \(String(describing: mathRenderError))")
}

var mathPage: [String: Any]?
previewWebView.evaluateJavaScript("""
(() => ({
  inline: document.querySelectorAll('span.math-inline.math-typeset svg').length,
  display: document.querySelectorAll('div.math-display.math-typeset svg').length,
  untypeset: document.querySelectorAll('.math:not(.math-typeset)').length,
  keepsPrices: document.body.innerText.includes('$5 and $10')
}))()
""") { value, _ in
    mathPage = value as? [String: Any]
}
let mathQueryDeadline = Date().addingTimeInterval(10)
while mathPage == nil, Date() < mathQueryDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
// The render completion only fires after typesetting, so nothing here has to wait for MathJax.
guard mathPage?["inline"] as? Int == 1, mathPage?["display"] as? Int == 1,
      mathPage?["untypeset"] as? Int == 0, mathPage?["keepsPrices"] as? Bool == true else {
    fatalError("Live preview did not typeset math: \(String(describing: mathPage))")
}
print("Live preview math smoke test passed: inline and display formulas typeset in the web view")

let mathFixture = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mdviewer-math-fixture.md")
try mathDocument.write(to: mathFixture, atomically: true, encoding: .utf8)
let mathPreviewStarted = Date()
let mathQuickLookData = try PreviewViewController.previewData(
    for: mathFixture, themePreference: ThemeSync.light
)
let mathPreviewSeconds = Date().timeIntervalSince(mathPreviewStarted)
try? FileManager.default.removeItem(at: mathFixture)
guard let mathQuickLookHTML = String(data: mathQuickLookData, encoding: .utf8) else {
    fatalError("Quick Look math reply was not UTF-8")
}
// Two containers, the stylesheet they need, and no element still holding untypeset TeX.
let mathContainers = mathQuickLookHTML.components(separatedBy: "<mjx-container").count - 1
guard mathContainers == 2,
      mathQuickLookHTML.contains("mjx-container[jax=\"SVG\"]"),
      !mathQuickLookHTML.contains("class=\"math math-inline\""),
      !mathQuickLookHTML.contains("class=\"math math-display\"") else {
    fatalError("Quick Look did not pre-render math: \(mathContainers) containers")
}
print("Quick Look math smoke test passed: \(mathContainers) formulas pre-rendered to SVG "
      + "in \(String(format: "%.2f", mathPreviewSeconds))s")
