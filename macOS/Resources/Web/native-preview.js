"use strict";
// Returns a promise the host awaits before it scrolls: math changes block heights, so a scroll
// issued before typesetting finishes would land in the wrong place.
window.renderMarkdown = function (markdown) {
  sourceLineCount = String(markdown).split("\n").length;
  anchorCache = null;
  var preview = document.getElementById("preview");
  preview.innerHTML = MDViewerMarkdown.renderMarkdown(markdown);
  return MDViewerMath.typesetDocument(preview, "mathjax/startup.js").then(function (result) {
    // Typesetting swaps TeX text for SVG, which moves everything below it.
    anchorCache = null;
    return result;
  });
};

// The page and the host editor stay on the same *source line*. Every block carries the line it was
// rendered from, so interpolating between consecutive stamped blocks converts a fractional line to
// a page offset and back. The host drives through scrollPreviewToSourceLine; user scrolls and
// clicks are posted back over the `scrollSync` and `caret` bridges. Quick Look serves this markup
// as static data with scripts never run, so the bridge checks only matter in the app's web view.
var sourceLineCount = 1;
var anchorCache = null;
window.addEventListener("resize", function () { anchorCache = null; });

function lineAnchors() {
  if (anchorCache) return anchorCache;
  var anchors = [];
  function push(line, top) {
    var previous = anchors[anchors.length - 1];
    if (!previous || (line > previous.line && top > previous.top)) anchors.push({ line: line, top: top });
  }
  var blocks = document.querySelectorAll("[data-src-line]");
  for (var index = 0; index < blocks.length; index += 1) {
    push(Number(blocks[index].getAttribute("data-src-line")),
         blocks[index].getBoundingClientRect().top + window.scrollY);
  }
  var preview = document.getElementById("preview");
  var last = preview && preview.lastElementChild;
  if (last) push(sourceLineCount, last.getBoundingClientRect().bottom + window.scrollY);
  anchorCache = anchors;
  return anchors;
}

function interpolate(points, from, to, value) {
  if (!points.length) return 0;
  var first = points[0];
  var last = points[points.length - 1];
  if (value <= first[from]) return first[to];
  if (value >= last[from]) return last[to];
  var low = 0;
  var high = points.length - 2;
  while (low < high) {
    var mid = (low + high + 1) >> 1;
    if (points[mid][from] <= value) low = mid; else high = mid - 1;
  }
  var a = points[low];
  var b = points[low + 1];
  var span = b[from] - a[from];
  return span > 0 ? a[to] + ((value - a[from]) / span) * (b[to] - a[to]) : a[to];
}

// Programmatic scrolls must not echo back to the host as if the reader scrolled. The echo is
// recognized by *position*: it lands exactly on the requested offset, while a real reader scroll
// moves away from it.
var suppressScrollY = null;
var suppressScrollUntil = 0;
function programmaticScroll(y) {
  suppressScrollY = y;
  suppressScrollUntil = Date.now() + 300;
  window.scrollTo(0, y);
}

window.restoreScrollOffset = function (y) {
  programmaticScroll(y);
};

var guide = null;
var guideTimer = null;
function flashGuide(viewportY) {
  if (!guide) {
    guide = document.createElement("div");
    guide.id = "sync-guide";
    document.body.appendChild(guide);
  }
  guide.style.top = Math.min(Math.max(viewportY, 0), window.innerHeight - 2) + "px";
  guide.classList.add("visible");
  clearTimeout(guideTimer);
  guideTimer = setTimeout(function () { guide.classList.remove("visible"); }, 900);
}

window.scrollPreviewToSourceLine = function (line) {
  var y = line <= 0 ? 0 : interpolate(lineAnchors(), "line", "top", line);
  programmaticScroll(y);
  flashGuide(y - window.scrollY);
};

window.addEventListener("scroll", function () {
  if (Date.now() < suppressScrollUntil && suppressScrollY !== null
      && Math.abs(window.scrollY - suppressScrollY) < 2) return;
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollSync;
  if (!bridge) return;
  var anchors = lineAnchors();
  var line = anchors.length && window.scrollY < anchors[0].top
    ? 0
    : interpolate(anchors, "top", "line", window.scrollY);
  bridge.postMessage({ line: line });
});

// A click on prose asks the host to put the caret on the matching source line. The block gives the
// first line, the next stamped block bounds it, and the click's vertical fraction within the block
// picks a position inside that span — the host owns the source text, so it does the line-level
// refinement (trimming trailing blank separator lines) itself.
function postCaretRequest(event) {
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.caret;
  if (!bridge) return;
  var selection = window.getSelection();
  if (selection && !selection.isCollapsed) return;
  var payload;
  var block = event.target.closest ? event.target.closest("[data-src-line]") : null;
  if (block) {
    var rect = block.getBoundingClientRect();
    var start = Number(block.getAttribute("data-src-line"));
    var end = sourceLineCount;
    var anchors = lineAnchors();
    for (var index = 0; index < anchors.length; index += 1) {
      if (anchors[index].line > start) {
        end = Math.min(anchors[index].line, sourceLineCount);
        break;
      }
    }
    var frac = rect.height > 0 ? Math.min(Math.max((event.clientY - rect.top) / rect.height, 0), 1) : 0;
    payload = { start: start, end: end, fraction: frac, viewportY: event.clientY };
  } else {
    var line = Math.floor(interpolate(lineAnchors(), "top", "line", event.clientY + window.scrollY));
    payload = { start: line, end: line + 1, fraction: 0, viewportY: event.clientY };
  }
  bridge.postMessage(payload);
}

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
  programmaticScroll(Math.max(0, window.scrollY + box.top - window.innerHeight / 3));
  return true;
};

// Intercept link clicks and hand the raw href to the native host. Reading the raw attribute (rather
// than letting WKWebView resolve it) matters because relative links resolve against this template's
// directory, not the document's.
document.addEventListener("click", function (event) {
  var link = event.target.closest ? event.target.closest("a") : null;
  if (!link) {
    postCaretRequest(event);
    return;
  }
  var href = link.getAttribute("href");
  if (!href) return;
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.link;
  if (!bridge) return;
  event.preventDefault();
  bridge.postMessage({ href: href });
});
