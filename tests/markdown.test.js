"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

require("../markdown.js");

const { renderInline, renderMarkdown, slugify } = globalThis.MDViewerMarkdown;

/// Every block carries the source line it came from, so the split editor can point the preview at
/// whatever the caret is on. Structural assertions read better without those attributes.
const structure = (markdown) => renderMarkdown(markdown).replace(/ data-src-line="\d+"/g, "");

test("renders common Markdown blocks", () => {
  const html = renderMarkdown(`# Title

> Local only

- [x] Done
- [ ] Next

| Name | Status |
| :--- | ---: |
| Viewer | Ready |

\`\`\`js
const value = "<safe>";
\`\`\``);

  assert.match(html, /<h1 [^>]*id="title">Title<\/h1>/);
  assert.match(html, /<blockquote[^>]*><p[^>]*>Local only<\/p><\/blockquote>/);
  assert.match(html, /<ul [^>]*class="task-list">/);
  assert.match(html, /type="checkbox" disabled checked/);
  assert.match(html, /<table>/);
  assert.match(html, /class="align-right"/);
  assert.match(html, /class="language-js"/);
  assert.match(html, /&lt;safe&gt;/);
});

test("escapes raw HTML and unsafe URLs", () => {
  const html = renderMarkdown(`<script>alert("no")</script>

![tracker](https://example.test/pixel.png)

[bad](javascript:alert(1))`);

  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
  assert.doesNotMatch(html, /src="https:/);
  assert.match(html, /Remote images are blocked/);
  assert.doesNotMatch(html, /href="javascript:/);
});

test("allows deliberate external links but marks them safe for a new tab", () => {
  const html = renderInline('[docs](https://example.test/?a=1&b=2 "Reference")');
  assert.equal(
    html,
    '<a href="https://example.test/?a=1&amp;b=2" title="Reference" target="_blank" rel="noreferrer noopener">docs</a>'
  );
});

test("generates stable readable heading slugs", () => {
  assert.equal(slugify("Hello, Мир!"), "hello-мир");
  assert.equal(slugify("!!!"), "section");
});

test("deduplicates repeated heading anchors", () => {
  const html = renderMarkdown("# Repeat\n\n# Repeat");
  assert.match(html, /id="repeat"/);
  assert.match(html, /id="repeat-2"/);
});

test("accepts short GitHub delimiter cells such as |--:|", () => {
  const html = renderMarkdown(`| variant | H | min ms |
|---------|--:|-------:|
| resnet | 8 | **2.427** |`);

  assert.match(html, /<table>/);
  assert.match(html, /<th class="align-right">min ms<\/th>/);
  assert.match(html, /<td class="align-right"><strong>2.427<\/strong><\/td>/);
  assert.doesNotMatch(html, /<p>\|/);
});

test("reflows soft-wrapped paragraphs and keeps explicit hard breaks", () => {
  assert.equal(
    structure("Hard-wrapped prose\nkeeps flowing."),
    "<p>Hard-wrapped prose keeps flowing.</p>"
  );
  assert.equal(structure("stop here  \nnew line"), "<p>stop here<br>new line</p>");
  assert.equal(structure("stop here\\\nnew line"), "<p>stop here<br>new line</p>");
});

test("nests indented lists inside their parent item", () => {
  assert.equal(
    structure("- outer one\n  - inner\n- outer two"),
    "<ul><li>outer one<ul><li>inner</li></ul></li><li>outer two</li></ul>"
  );
  assert.equal(
    structure("1. first\n   1. nested\n2. second"),
    "<ol><li>first<ol><li>nested</li></ol></li><li>second</li></ol>"
  );
});

test("keeps a lazy continuation line inside its list item", () => {
  assert.equal(
    structure("* CONST wins the grid\n  — effectively free.\n* UBO is worst."),
    "<ul><li>CONST wins the grid — effectively free.</li><li>UBO is worst.</li></ul>"
  );
});

test("ends a list at a horizontal rule rather than swallowing it", () => {
  assert.equal(structure("- a\n\n---\n\n- b"), "<ul><li>a</li></ul>\n<hr>\n<ul><li>b</li></ul>");
});

test("stamps each block with the source line it came from", () => {
  const html = renderMarkdown(`# Title

First paragraph.

- item one
- item two

> quoted`);

  assert.match(html, /<h1 data-src-line="0"/);
  assert.match(html, /<p data-src-line="2"/);
  assert.match(html, /<ul data-src-line="4"/);
  assert.match(html, /<li data-src-line="5">item two<\/li>/);
  // A blockquote's contents keep document-absolute lines, not quote-relative ones.
  assert.match(html, /<blockquote data-src-line="7"><p data-src-line="7"/);
});

test("keeps LaTeX out of the inline rules and hands it to the typesetter", () => {
  // Underscores and asterisks are TeX syntax, not emphasis, and `<` must survive as an entity.
  assert.equal(
    renderInline("mass $a_1 * b_2 < c$ here"),
    'mass <span class="math math-inline" data-tex="a_1 * b_2 &lt; c">a_1 * b_2 &lt; c</span> here'
  );
  assert.equal(
    renderInline("also \\(x^2\\) inline"),
    'also <span class="math math-inline" data-tex="x^2">x^2</span> inline'
  );
  // The TeX is carried twice on purpose: `data-tex` for MathJax, text for the moment before it runs.
  assert.match(renderInline("$\\alpha$"), /data-tex="\\alpha">\\alpha<\/span>/);
});

test("reads $ as money unless it delimits a formula", () => {
  assert.equal(structure("It cost $5 and $10 more."), "<p>It cost $5 and $10 more.</p>");
  assert.equal(structure("A range of $5-$10."), "<p>A range of $5-$10.</p>");
  // An explicit escape is the way to write a lone dollar next to something math-shaped.
  assert.equal(structure("\\$5 for $x$"), '<p>$5 for <span class="math math-inline" data-tex="x">x</span></p>');
  assert.doesNotMatch(renderInline("`$5` in code"), /class="math/);
});

test("renders display math as its own block", () => {
  assert.equal(
    structure("$$\n\\frac{a}{b}\n$$"),
    '<div class="math math-display" data-tex="\\frac{a}{b}">\\frac{a}{b}</div>'
  );
  assert.equal(
    structure("\\[\ny = mx + b\n\\]"),
    '<div class="math math-display" data-tex="y = mx + b">y = mx + b</div>'
  );
  assert.equal(structure("$$x^2$$"), '<div class="math math-display" data-tex="x^2">x^2</div>');
  // A display block ends the paragraph above it and does not swallow the text below.
  assert.equal(
    structure("before\n$$z$$\nafter"),
    '<p>before</p>\n<div class="math math-display" data-tex="z">z</div>\n<p>after</p>'
  );
});

test("protects a math block from the other block rules", () => {
  // `\\` opens an alignment row in TeX and a horizontal rule in Markdown; `&` and `|` are column
  // separators. Inside a math block none of the block patterns may fire.
  const html = structure("$$\n\\begin{aligned}\na &= 1 \\\\\nb &= 2\n\\end{aligned}\n$$");
  assert.match(html, /^<div class="math math-display"/);
  assert.doesNotMatch(html, /<hr>|<table>|<p>/);
  assert.match(html, /data-tex="\\begin\{aligned\}\na &amp;= 1 \\\\\nb &amp;= 2\n\\end\{aligned\}"/);
});

test("leaves math alone inside code, and code alone inside math", () => {
  assert.doesNotMatch(structure("```\n$$ x $$\n```"), /class="math/);
  assert.equal(structure("unclosed $$ math"), "<p>unclosed $$ math</p>");
});

test("renders a large real-world document without dropping blocks", () => {
  const source = fs.readFileSync(path.join(__dirname, "fixtures/large-document.md"), "utf8");
  assert.ok(source.length > 40000, "fixture should be large enough to be interesting");

  const started = process.hrtime.bigint();
  const html = renderMarkdown(source);
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;

  // Every table in the fixture uses short delimiter cells (`|--:|`), the shape that used to fall
  // back to a paragraph and take the whole document's tabular content with it.
  const tables = html.match(/<table>/g) || [];
  assert.ok(tables.length >= 25, `expected the fixture's tables to render, got ${tables.length}`);
  assert.doesNotMatch(html, /<p[^>]*>\|/, "a table row leaked into a paragraph");

  // The fixture is hard-wrapped prose; none of those wraps should become forced line breaks.
  assert.doesNotMatch(html, /<br>/);

  assert.ok(elapsedMs < 1000, `rendering took ${elapsedMs.toFixed(0)}ms`);
});
