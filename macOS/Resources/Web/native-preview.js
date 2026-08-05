"use strict";
// Returns a promise the host awaits before it scrolls: math changes block heights, so a scroll
// issued before typesetting finishes would land in the wrong place.
window.renderMarkdown = function (markdown) {
  var preview = document.getElementById("preview");
  preview.innerHTML = MDViewerMarkdown.renderMarkdown(markdown);
  return MDViewerMath.typesetDocument(preview, "mathjax/startup.js");
};

// Editor -> preview position sync. Every block carries the source line it was rendered from, so the
// host can say "the caret is on line N" and we find the block that owns it.
function blockForSourceLine(line) {
  var blocks = document.querySelectorAll("[data-src-line]");
  var match = null;
  for (var index = 0; index < blocks.length; index += 1) {
    if (Number(blocks[index].getAttribute("data-src-line")) > line) break;
    match = blocks[index];
  }
  return match;
}

window.scrollToSourceLine = function (line) {
  var target = blockForSourceLine(line);
  if (!target) return false;

  var previous = document.querySelector(".source-active");
  if (previous && previous !== target) previous.classList.remove("source-active");
  target.classList.add("source-active");

  // Only scroll when the block is off-screen, so the preview does not twitch on every keystroke.
  // When it does scroll, park the block a third of the way down rather than at the very edge.
  var box = target.getBoundingClientRect();
  var margin = 24;
  if (box.top >= margin && box.bottom <= window.innerHeight - margin) return true;
  var offset = window.scrollY + box.top - window.innerHeight / 3;
  window.scrollTo({ top: Math.max(0, offset), behavior: "auto" });
  return true;
};

// Intercept link clicks and hand the raw href to the native host. Reading the raw attribute (rather
// than letting WKWebView resolve it) matters because relative links resolve against this template's
// directory, not the document's.
document.addEventListener("click", function (event) {
  var link = event.target.closest ? event.target.closest("a") : null;
  if (!link) return;
  var href = link.getAttribute("href");
  if (!href) return;
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.link;
  if (!bridge) return;
  event.preventDefault();
  bridge.postMessage({ href: href });
});
