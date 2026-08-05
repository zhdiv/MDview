# Vendored MathJax 3.2.2 (SVG output)

Source: the `mathjax` npm package, version 3.2.2, `es5/` directory. Apache-2.0, see `LICENSE`.
Checked in rather than fetched because the viewer makes no network requests — see the offline
guarantee in the top-level `README.md`.

## Why these files and not `es5/tex-svg.js`

The prebuilt combined bundles (`tex-svg.js`, `tex-chtml.js`, …) include `ui/menu`, which pulls in the
speech-rule engine. SRE initialises **at load time** and reaches for `window.document`, falling back
to a Node `require("xmldom-sre")`. In JavaScriptCore — which is how Quick Look pre-renders a
document — neither exists, and loading the bundle throws
`Cannot read properties of null (reading 'DOMImplementation')` before any TeX is seen.

The individual components below contain no SRE, so the same files run in the browser, in the app's
`WKWebView`, and in the extension's bare `JSContext`.

| File | Why |
| --- | --- |
| `startup.js` | loader + startup; the only file a page loads directly |
| `core.js` | MathML internals shared by input and output |
| `input/tex-full.js` | every TeX package preloaded. The plain `input/tex` component autoloads extensions on demand, which offline means a failed fetch mid-document |
| `output/svg.js`, `output/svg/fonts/tex.js` | SVG output. Chosen over CommonHTML because it needs no web fonts: glyphs are paths, so one directory is the whole dependency |
| `adaptors/liteDOM.js` | DOM-free adaptor, used only by the Quick Look renderer |

## Updating

```sh
npm pack mathjax@<version>
tar xzf mathjax-<version>.tgz
```

Copy the files above out of `package/es5/` (keeping this layout) and `package/LICENSE`. Then run both
suites — `node --test tests/markdown.test.js` and `./macOS/test.sh`; the latter typesets through
JavaScriptCore and fails loudly if a new release reintroduces the DOM dependency.

MathJax 4 splits font data into separate packages that are fetched on demand, so moving to it means
vendoring a font package too and re-checking the offline path.
