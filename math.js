/// Turns the `.math` elements produced by `markdown.js` into typeset SVG.
///
/// Shared by the same three targets as the renderer, in two flavours: `typesetDocument` walks a live
/// DOM (browser page, the app's WKWebView) and loads MathJax on first use; `typesetHTML` rewrites a
/// markup *string* and is what the Quick Look extension calls from JavaScriptCore, where there is no
/// DOM at all. Both read the TeX from `data-tex`, so typesetting is idempotent and a re-render never
/// has to reparse SVG to find the source.
(function (root) {
  "use strict";

  const MATH_SELECTOR = ".math[data-tex]:not(.math-typeset)";
  // Block-level math carries `data-src-line` ahead of its class, so the attributes are matched as a
  // whole and re-emitted untouched: dropping that attribute would break editor-to-preview sync.
  const MATH_ELEMENT = /<(span|div)\s+([^>]*class="math math-(inline|display)"[^>]*)>[\s\S]*?<\/\1>/g;
  const MATH_TEX = /data-tex="([^"]*)"/;
  const UNESCAPES = Object.freeze({
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": '"',
    "&#39;": "'",
    "&#96;": "`",
    "&amp;": "&"
  });

  function unescapeTex(value) {
    return String(value).replace(/&(?:lt|gt|quot|#39|#96|amp);/g, (entity) => UNESCAPES[entity]);
  }

  /// The MathJax configuration, in one place because the two hosts set it up differently: a page
  /// derives the component directory from the script tag, JavaScriptCore has to be handed both the
  /// directory and a `require` that can read it.
  ///
  /// `input/tex-full` preloads every TeX package: the smaller `input/tex` autoloads extensions on
  /// demand, which offline is a fetch that cannot succeed. SVG output needs no web fonts.
  function mathJaxConfig(loader) {
    return {
      loader: Object.assign({ load: ["input/tex-full", "output/svg"] }, loader || {}),
      startup: { typeset: false },
      svg: { fontCache: "local" }
    };
  }

  let loadingMathJax = null;

  /// Loads MathJax once, on the first document that actually contains math. Roughly 1.8 MB of
  /// components is not worth parsing for the documents that have none.
  function loadMathJax(startupURL) {
    if (loadingMathJax) return loadingMathJax;
    loadingMathJax = new Promise((resolve, reject) => {
      root.MathJax = mathJaxConfig();
      const script = document.createElement("script");
      script.src = startupURL;
      script.onerror = () => reject(new Error(`MathJax was not loaded from ${startupURL}`));
      script.onload = () => root.MathJax.startup.promise.then(() => {
        document.head.appendChild(root.MathJax.svgStylesheet());
        resolve(root.MathJax);
      }, reject);
      document.head.appendChild(script);
    });
    return loadingMathJax;
  }

  function typesetElement(element) {
    const display = element.classList.contains("math-display");
    element.replaceChildren(root.MathJax.tex2svg(element.getAttribute("data-tex"), { display }));
    element.classList.add("math-typeset");
  }

  /// Typesets every untypeset formula under `container`, loading MathJax first if this is the first
  /// one. Resolves to the number of formulas typeset. Malformed TeX is MathJax's business: it
  /// renders the error in place rather than throwing.
  async function typesetDocument(container, startupURL) {
    const elements = Array.from(container.querySelectorAll(MATH_SELECTOR));
    if (!elements.length) return 0;
    await loadMathJax(startupURL);
    elements.forEach(typesetElement);
    return elements.length;
  }

  /// The DOM-free counterpart: replaces the contents of every math element in a markup string.
  /// MathJax must already be initialised in this context — in the extension, Swift does that.
  function typesetHTML(html) {
    const adaptor = root.MathJax.startup.adaptor;
    return String(html).replace(MATH_ELEMENT, (element, tag, attributes, kind) => {
      const tex = MATH_TEX.exec(attributes);
      if (!tex) throw new Error(`Math element carries no TeX: ${element}`);
      const node = root.MathJax.tex2svg(unescapeTex(tex[1]), { display: kind === "display" });
      const typeset = attributes.replace(`class="math math-${kind}"`,
                                         `class="math math-${kind} math-typeset"`);
      return `<${tag} ${typeset}>${adaptor.outerHTML(node)}</${tag}>`;
    });
  }

  /// The CSS MathJax's SVG output needs. A live page gets it from `loadMathJax`; a static page
  /// (an exported HTML file, a Quick Look reply) has to carry it inline.
  function stylesheetText() {
    const adaptor = root.MathJax.startup.adaptor;
    return adaptor.textContent(root.MathJax.svgStylesheet());
  }

  root.MDViewerMath = Object.freeze({
    mathJaxConfig,
    stylesheetText,
    typesetDocument,
    typesetHTML
  });
})(globalThis);
