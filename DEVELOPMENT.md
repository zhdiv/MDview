# Development notes

Things that were expensive to work out. Read before touching the layout or the renderer.

## Running the tests

```bash
node --test tests/markdown.test.js   # renderer, no dependencies
./macOS/test.sh                      # compiles the app sources + a smoke harness, runs headless
```

`macOS/test.sh` builds `macOS/Tests/main.swift` against the real app sources — there is no Xcode
project and no XCTest. It drives a `DocumentViewController` directly, so anything it asserts is
asserted against production code paths.

---

## Gotcha: NSSplitView keeps a divider for a hidden pane

**Symptom.** After using Split mode, a 1 pt vertical hairline stayed on screen in Preview and Editor
mode. Moving the window did not clear it. **Resizing the window did.**

**Why.** Single-pane modes originally hid the other pane with `isHidden = true`. That is not enough:

- NSSplitView keeps the hidden subview in its model, so it still has *two* panes and *one* divider.
- `adjustSubviews()` reserves `dividerThickness` for it, so the visible pane got **979 of 980 pt**.
- The divider is drawn into the split view's own backing store. The window is layer-backed (a
  `WKWebView` anywhere in the tree forces that), so the drawn line survived in the layer until
  something invalidated the whole view — which is what a resize does and a move does not.

`splitView(_:shouldHideDividerAt:)` fixes the *reserved pixel* (the pane then measures a full 980)
but is not a reliable fix for the *drawn* line, because the two are separate problems: geometry vs.
what is already in the layer.

**The fix.** `syncPanes()` in `DocumentViewController` assigns `splitView.subviews` so the split view
contains *exactly* the panes that are on screen. One subview means no divider exists to model,
reserve space for, or draw. Nothing to go stale.

```swift
var wanted = [NSView]()
if mode.showsEditor { wanted.append(editorPane) }
if mode.showsPreview { wanted.append(previewPane) }
if splitView.subviews != wanted { splitView.subviews = wanted }
```

**If you change pane visibility, do it there.** Reintroducing `isHidden` on a pane brings the
hairline back.

### Why the tests did not catch it

Two independent failures worth remembering:

1. **The assertion had slack.** It read `editorWidth >= splitWidth - 1`, and the bug was exactly
   1 pt. The suite now asserts `== splitWidth` — no tolerance, because any tolerance here is the
   defect. Do not loosen it.
2. **Headless snapshots cannot see it.** `NSView.cacheDisplay(in:to:)` re-draws the tree into a fresh
   bitmap and ignores cached layer contents, so a stale-layer artifact is invisible to it. A raster
   probe reported a clean window while the real app showed the line.

The general lesson: geometry assertions catch reserved space; nothing headless here catches "what is
actually composited on screen". For anything that smells like a redraw problem, the sequence
"resize clears it, move does not" is the tell — it means layout, not compositing, and it means the
model still contains something it should not.

### Probing layout without the screen

Screen recording permission may not be available, in which case `screencapture` returns only the
desktop and menu bar. To inspect layout, build a throwaway harness against the app sources:

```swift
let controller = DocumentViewController()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentViewController = controller
window.setContentSize(NSSize(width: 900, height: 600))   // required: without it bounds height is 0
window.makeKeyAndOrderFront(nil)
controller.view.layoutSubtreeIfNeeded()
```

Then print `splitView.subviews.map(\.frame)`, or rasterise with
`bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` and scan a row for colour changes.
Note the two limits: `cacheDisplay` does not capture `WKWebView` content (it is out of process), and
it does not reflect layer staleness (above).

---

## Gotcha: one control, one stored value

Layout used to be two independent toggles — a Preview/Edit tab plus a "show the preview pane"
switch. Two booleans describe four states for three meanings, and the fourth ("Editor, but with a
preview") kept leaking through. `open(url:)` also forced the mode back to Preview on every file
open, which read to the user as the setting silently resetting.

There is now a single `Mode` enum (`preview` / `split` / `editor`), persisted, and it is the only
input to `applyLayout()`. Opening a file deliberately does **not** change it.

Keep it that way: if a new layout option is needed, extend `Mode` rather than adding a second flag
that has to agree with it.

---

## Gotcha: the Markdown renderer is shared by three targets

`markdown.js` (and `math.js` with it) is loaded by the app's `MarkdownPreviewView`/`WKWebView`, by
Quick Look through `JavaScriptCore`, and by the browser page. Quick Look returns the rendered markup plus the same native
CSS as a static HTML data reply for Finder to display. A change affects all three, and only the
browser one has fast feedback — run `./macOS/test.sh` too.

Do not embed `WKWebView` directly in the Quick Look extension. Its sandboxed WebKit helper processes
crash unless the extension receives outbound-network capability, producing Finder's infinite loading
spinner. The data-based `QLPreviewReply` avoids that capability and is Apple's supported route for
HTML previews. Do not bring back the `NSAttributedString` importer either: it supports much less CSS
and caused the spacing, fonts, and dark-mode colors to differ from the app.


### Table delimiter rows

GitHub accepts a single dash per delimiter cell. `|--:|` is a valid right-aligned column, and
requiring three (`-{3,}`) silently demoted whole tables to paragraphs. Covered by a test; the large
fixture in `tests/fixtures/` is full of them.

### Soft breaks

A single newline inside a paragraph collapses to a space so hard-wrapped documents reflow with the
window. Only two trailing spaces or a trailing backslash produce `<br>`. Tests assert both.

---

## Gotcha: MathJax has to run in three places, one of which has no DOM

`markdown.js` never typesets. It only *extracts* TeX — before escaping, before the emphasis rules, so
`$a_1 * b_2$` cannot become italics — and emits `<span class="math math-inline" data-tex="…">`, with
the TeX kept both in the attribute and as the element's text. `math.js` turns those into SVG, in two
flavours, because the three targets do not share an environment:

| Target | Call | Notes |
| --- | --- | --- |
| browser page, app `WKWebView` | `typesetDocument(root, url)` | loads MathJax on first use, walks the DOM |
| Quick Look extension | `typesetHTML(html)` | no DOM: rewrites the markup string, MathJax booted from Swift |

**Quick Look must pre-render.** Finder displays a `QLPreviewReply` as static data and does not run its
scripts, so a formula that is not already SVG in that reply is a formula the reader never sees. The
extension boots MathJax inside its `JSContext` and typesets before handing the data over.

**The prebuilt bundles cannot be used.** `es5/tex-svg.js` includes `ui/menu`, which pulls in the
speech-rule engine; SRE initialises *at load* and needs `window.document` or a Node `require`.
JavaScriptCore has neither, and the bundle throws before it sees any TeX. `vendor/mathjax/` therefore
holds the individual SRE-free components, loaded through a native `require` shim
(`loadMathJax(into:bundle:evaluate:)`) plus the `liteDOM` adaptor. Its README has the details and the
update procedure — both suites fail loudly if a future version reintroduces the DOM dependency.

Everything is loaded synchronously through that shim, and JavaScriptCore drains its microtask queue
as each API call returns, so MathJax has started up by the time `evaluateScript` returns. That
matters: a Quick Look reply has no run loop to come back to later.

### The preview render is asynchronous

`window.renderMarkdown` returns a promise and `MarkdownPreviewView.paint` **awaits** it. Typesetting
changes block heights, so scrolling before it settles — restoring the reader's offset, or jumping to
the caret's line — lands somewhere else. If you add work to the render path, keep it inside that
promise. In the browser page the same window is why `assertMathTypeset` refuses an export or a print
that would otherwise write raw TeX into the file.

### CSP needs `style-src 'unsafe-inline'`

MathJax's SVG output puts `vertical-align` in a `style` attribute and ships its stylesheet as an
injected `<style>` element. Both need `style-src 'unsafe-inline'`; without it formulas sit on the
wrong baseline. `connect-src 'none'` is untouched, and scripts are still same-origin only.

### `$` is usually money

A formula may not open with a space after `$`, close on a space, or be followed by a digit, which
leaves `$5 and $10` as prose. `\$` is an escape for a literal dollar. Both are covered by tests —
they are the cases a naive delimiter regex silently eats.

---

## Gotcha: ad-hoc signatures break Finder associations

An ad-hoc signature's designated requirement is its `cdhash`, which changes on every build. Launch
Services then treats each rebuild as a different application and drops the user's "always open with"
choice. `macOS/build.sh` pins an identifier-based designated requirement so the association survives
a rebuild:

```sh
codesign --force --sign - --identifier app.mdviewer \
  -r='designated => identifier "app.mdviewer"' "$APP"
```

Verify with `codesign -d -r- "path/to/Markdown Viewer.app"` — it must print
`designated => identifier "app.mdviewer"`, never a `cdhash`.

The trade-off is that any bundle claiming that identifier satisfies the requirement. That is
inherent to unsigned local builds; signing with a real identity (`CODESIGN_IDENTITY=…`) keeps the
certificate in the requirement and skips this path entirely.

`LSHandlerRank` must stay `Owner`. An `Alternate` handler appears under "Open With" but Launch
Services will never rank it as the default, so "Change All" does not stick.
