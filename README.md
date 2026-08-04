# Markdown Viewer

An offline Markdown viewer and editor that makes no network requests — no server, CDN, account,
analytics, or telemetry. Two builds share one renderer:

- **`macOS/`** builds a native **Markdown Viewer.app** with Finder file associations and an embedded
  Quick Look preview extension. Preview, Split and Editor are three modes on one toolbar control.
- **`index.html`** is a portable browser version that runs from the filesystem.

Requires macOS 13 or later for the native app; the browser version runs in any modern browser.

## Install the macOS app

```bash
./macOS/install.sh
```

It builds the app, replaces the copy in `/Applications`, re-registers it with Launch Services, and
makes it the default handler for `.md`, `.markdown`, `.mdown` and `.mkd`. Use `./macOS/build.sh` on
its own if you only want the bundle in `macOS/build/`.

You can then choose **Markdown Viewer** under Finder's **Open With**, or select a Markdown file and
press Space for a formatted preview without opening the editor. File association and Quick Look use
the same system Markdown type, so setting **Open With → Change All** keeps the formatted Space-bar
preview. If macOS disables the extension, enable Markdown Viewer under **System Settings → General →
Login Items & Extensions → Quick Look**.

The app is dependency-free and ad-hoc signed, and builds as one universal Apple Silicon/Intel bundle.
It is **not notarized**, so on first launch macOS may require Control-click → Open.

## Editing

One control in the toolbar picks what the window shows:

| Mode | Shortcut | Shows |
| --- | --- | --- |
| **Preview** | `⌘1` | only the rendered document, full width (minimal mode) |
| **Split** | `⌘2` | source on the left, live preview on the right |
| **Editor** | `⌘3` | the Markdown source alone, full width |

The mode is remembered across launches *and across opening another file* — nothing silently puts the
preview back. Preview hides the toolbar so the Markdown is the only content on screen. Press `⇧⌘E`
to cycle **Preview → Editor → Split → Preview** (`⌘E` remains the standard macOS “Use Selection for
Find” shortcut). Press `⌘P` for a compact quick menu with mode, theme, file, and title commands.

In Split, drag the divider to resize either side; the position is remembered and comes back when you
return from Editor. Double-clicking the divider collapses the preview. The preview follows your
typing without reloading, so it keeps its scroll position.

The preview also follows the caret. Every rendered block records the source line it came from
(`data-src-line`), so moving the insertion point — typing, clicking, arrow keys — marks the matching
block with an accent bar in the margin, and scrolls to it only when it is off-screen. That keeps
your place visible in a long document without the preview twitching on every keystroke.

Undo, redo, cut, copy, paste, paste-and-match-style, select all and find live in the **Edit** menu
with their usual shortcuts, and are also on the editor's right-click menu. Copy works in the preview
too — select rendered text and press `⌘C`.

An **Auto/Light/Dark** toggle in the toolbar themes the window, editor, and preview together and
remembers your choice (**Auto** follows the macOS system appearance). The choice is also used by
Finder's Quick Look preview. **Settings** (`⌘,`) contains the same appearance preference plus a
toggle between showing only the filename or the full pathname in the window title; that title
toggle is also available from the `⌘P` quick menu. Links work in the preview — a
link to another Markdown file (e.g. `[notes](./notes.md)`) opens it in the viewer, any other link
goes to the system default app, and `#anchor` links scroll to that heading.

### If Finder stops opening Markdown files in this app

Rebuilding used to break the association: an ad-hoc code signature's designated requirement is its
`cdhash`, which changes on every build, so Launch Services treated each rebuild as a *different*
application and dropped the "always open with" choice. `build.sh` pins an identifier-based
designated requirement that survives rebuilds, and the app claims Markdown as `LSHandlerRank = Owner`
rather than `Alternate` (an Alternate handler can never become the default).

If the association is still wrong — usually because several copies of the bundle are registered —
re-run `./macOS/install.sh`, which unregisters the stale copies before installing. From inside the
app, **Markdown Viewer → Set as Default Markdown App…** re-claims the file types at any time.

### Sharing the theme with Quick Look

Quick Look uses the same rendered markup, CSS layout, and theme as opening the file in the app.
The editor's saved theme choice is shared with Quick Look. A Developer ID build uses the App Group
`group.app.mdviewer`; the default local ad-hoc build grants the extension read-only access to the
main app's preference domain, so both build paths stay consistent. To use the App Group path, build
with your identity:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./macOS/build.sh
```

and register the App Group `group.app.mdviewer` for both the app and the Quick Look extension. The
easiest route is Xcode automatic signing (free or paid Apple ID), which provisions the group for you.
Set the editor to **Light** or **Dark** and Quick Look uses that theme; in **Auto** both follow the
system.

## Browser version

Open `index.html` in a modern browser, or drag the file into a browser window. It supports:

- opening or dropping `.md`, `.markdown`, and plain-text files;
- live Edit, Split, and Preview layouts;
- save-in-place where the browser supports the File System Access API, with a download fallback;
- standalone HTML export and print/PDF output;
- find, synchronized scrolling, formatting shortcuts, dark mode, and local draft recovery.

| Shortcut | Action |
| --- | --- |
| `Ctrl/Cmd + O` | Open |
| `Ctrl/Cmd + S` | Save |
| `Ctrl/Cmd + F` | Find |
| `Ctrl/Cmd + B` | Bold |
| `Ctrl/Cmd + I` | Italic |
| `Ctrl/Cmd + K` | Link |

## Markdown support

`markdown.js` is a dependency-free renderer shared by the app, the Quick Look extension and the
browser page. It covers headings, emphasis, links, images, blockquotes, nested lists, task lists,
fenced code, horizontal rules and tables — including GitHub delimiter rows down to a single dash, so
`|--:|` aligns a column right.

Paragraphs reflow: a single newline in the source is a soft break, so a hard-wrapped document fits
the window instead of keeping the author's line endings. End a line with two spaces or a backslash
for a real `<br>`.

Raw HTML in the source is escaped rather than rendered.

## Offline guarantee

Every byte of JavaScript and CSS is in this repository. There is no analytics, service worker, remote
font, CDN, or `fetch`/XHR/WebSocket call, and the page's Content Security Policy sets
`connect-src 'none'`. Remote images are deliberately not loaded in Preview — they render as blocked
placeholders — while local, `data:` and `blob:` images work. An external link is opened, in your
default browser, only when you explicitly click it. Draft recovery uses only local storage.

## Repository layout

```
markdown.js              the renderer, shared by every target
index.html app.js        browser version
styles.css               browser version styles
assets/                  app icon (SVG source + 1024px raster)
macOS/App/               AppKit app: delegate, document view controller
macOS/QuickLook/         Quick Look preview extension
macOS/Shared/            preview web view + theme bridge
macOS/Resources/         Info.plists, entitlements, preview page assets
macOS/build.sh           build the .app bundle
macOS/install.sh         build, install to /Applications, claim the file types
macOS/test.sh            native smoke tests
tests/                   renderer tests (node:test) + fixtures
```

## Development

```bash
node --test tests/markdown.test.js   # renderer
./macOS/test.sh                      # Edit split layout, live preview, caret sync, Quick Look
```

Neither suite needs a package manager — the renderer tests run on Node's built-in test runner, and
the native tests compile with the Xcode command line tools.

[`DEVELOPMENT.md`](DEVELOPMENT.md) collects the non-obvious parts: AppKit split-view behaviour, how
to probe layout without screen recording permission, the shared-renderer constraints, and the code
signing rules that keep the Finder association working. Read it before changing layout or
`markdown.js`.

The app icon's only source artwork is the editable vector `assets/mdviewer-icon.svg`. The native
build rasterizes it with AppKit and packages the required sizes into
`AppIcon.icns`; the browser uses the SVG directly as its favicon and brand mark.

Thanks for choosing MDViewer!
