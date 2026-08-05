(function (root) {
  "use strict";

  const ESCAPES = Object.freeze({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  });

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (character) => ESCAPES[character]);
  }

  function escapeAttribute(value) {
    return escapeHtml(value).replace(/`/g, "&#96;");
  }

  function slugify(value) {
    const slug = String(value)
      .toLowerCase()
      .replace(/<[^>]*>/g, "")
      .replace(/[^\p{L}\p{N}\s-]/gu, "")
      .trim()
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-");
    return slug || "section";
  }

  function isSafeImageUrl(url) {
    const value = String(url).trim();
    if (/^(?:data:image\/(?:png|gif|jpeg|webp|svg\+xml);|blob:)/i.test(value)) return true;
    return !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(value);
  }

  function isSafeLinkUrl(url) {
    const value = String(url).trim();
    return /^(?:#|\.{0,2}\/|[^:/?#]+(?:[/?#]|$))/i.test(value)
      || /^(?:https?:|mailto:)/i.test(value);
  }

  function escapedUrlAttribute(url) {
    return escapeAttribute(String(url).replace(/&amp;/g, "&"));
  }

  /// A math span. The TeX is kept twice on purpose: as `data-tex` for the typesetter to read back
  /// exactly what the author wrote, and as the element's text so the source is on screen for the
  /// moment between rendering and typesetting rather than a gap that reflows when it fills.
  function mathElement(tag, kind, tex) {
    const source = String(tex).trim();
    return `<${tag} class="math math-${kind}" data-tex="${escapeAttribute(source)}">${escapeHtml(source)}</${tag}>`;
  }

  /// `$x$` is ambiguous with prose about money, so both ends are constrained the way GitHub and
  /// pandoc constrain them: no space just inside either delimiter, and no digit right after the
  /// closing one. That leaves "it cost $5 and $10 more" as text while "$x_1$" is math.
  const INLINE_MATH = [
    [/\\\[([\s\S]+?)\\\]/g, "display"],
    [/\$\$([\s\S]+?)\$\$/g, "display"],
    [/\\\(([\s\S]+?)\\\)/g, "inline"],
    [/(?<![\\$])\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)/g, "inline"]
  ];

  function renderInline(source) {
    const codeTokens = [];
    let value = String(source).replace(/(`+)([\s\S]*?)\1/g, (_, ticks, code) => {
      const token = `\uE000${codeTokens.length}\uE001`;
      codeTokens.push(`<code>${escapeHtml(code.trim())}</code>`);
      return token;
    });

    // Math is pulled out before escaping and before the emphasis rules run: `$a_1 * b_2$` is one
    // formula, not italics and a bullet. Code spans were taken first, so `` `$5` `` stays literal.
    const mathTokens = [];
    INLINE_MATH.forEach(([pattern, kind]) => {
      value = value.replace(pattern, (_, tex) => {
        const token = `\uE002${mathTokens.length}\uE003`;
        mathTokens.push(mathElement("span", kind, tex));
        return token;
      });
    });

    value = escapeHtml(value).replace(/\\\$/g, "$");
    value = value.replace(/!\[([^\]]*)\]\((\S+?)(?:\s+&quot;(.+?)&quot;)?\)/g, (_, alt, url, title) => {
      if (!isSafeImageUrl(url)) {
        return `<span class="blocked-media" title="Remote images are blocked in offline mode">[image: ${alt || url}]</span>`;
      }
      const titleAttribute = title ? ` title="${escapeAttribute(title)}"` : "";
      return `<img src="${escapedUrlAttribute(url)}" alt="${escapeAttribute(alt)}"${titleAttribute}>`;
    });
    value = value.replace(/\[([^\]]+)\]\((\S+?)(?:\s+&quot;(.+?)&quot;)?\)/g, (_, label, url, title) => {
      if (!isSafeLinkUrl(url)) return `${label} (${escapeHtml(url)})`;
      const external = /^https?:/i.test(url);
      const titleAttribute = title ? ` title="${escapeAttribute(title)}"` : "";
      const externalAttributes = external ? ' target="_blank" rel="noreferrer noopener"' : "";
      return `<a href="${escapedUrlAttribute(url)}"${titleAttribute}${externalAttributes}>${label}</a>`;
    });
    value = value
      .replace(/\*\*([\s\S]+?)\*\*/g, "<strong>$1</strong>")
      .replace(/__([\s\S]+?)__/g, "<strong>$1</strong>")
      .replace(/~~([\s\S]+?)~~/g, "<del>$1</del>")
      .replace(/(^|[\s(])\*([^*\n]+?)\*(?=$|[\s).,!?:;])/g, "$1<em>$2</em>")
      .replace(/(^|[\s(])_([^_\n]+?)_(?=$|[\s).,!?:;])/g, "$1<em>$2</em>");

    // A literal replacement string would treat `$&` and friends inside TeX as substitutions.
    mathTokens.forEach((html, index) => {
      value = value.replace(`\uE002${index}\uE003`, () => html);
    });
    codeTokens.forEach((html, index) => {
      value = value.replace(`\uE000${index}\uE001`, html);
    });
    return value;
  }

  function splitTableRow(line) {
    let value = line.trim();
    if (value.startsWith("|")) value = value.slice(1);
    if (value.endsWith("|")) value = value.slice(0, -1);
    return value.split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, "|"));
  }

  // GitHub only requires a single dash per delimiter cell, so `|--:|` is a valid right-aligned
  // column. Requiring three would silently demote the whole table to a paragraph.
  function isTableDivider(line) {
    if (!line.includes("|")) return false;
    const cells = splitTableRow(line);
    return cells.length > 0 && cells.every((cell) => /^:?-+:?$/.test(cell));
  }

  function tableAlignment(cell) {
    if (/^:-+:$/.test(cell)) return "center";
    if (/^-+:$/.test(cell)) return "right";
    return "left";
  }

  const HORIZONTAL_RULE = /^ {0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/;
  const LIST_MARKER = /^(\s*)([-+*]|\d+[.)])(\s+)(.*)$/;
  const MATH_BLOCK = /^ {0,3}(\$\$|\\\[)/;

  /// Display math that opens a line owns every line up to its closing delimiter, the way a fenced
  /// code block does. Without that, the paragraph path would reflow the TeX and the list, table and
  /// rule patterns would fire on lines like `\\ -- 1 & 2`.
  ///
  /// Returns `null` when the delimiter never closes, or when prose follows the closer on its line —
  /// then this was inline math inside an ordinary paragraph, and the inline pass should handle it.
  function parseMathBlock(lines, start) {
    const open = MATH_BLOCK.exec(lines[start]);
    if (!open) return null;
    const closer = open[1] === "$$" ? "$$" : "\\]";
    const body = [];
    let index = start;
    let rest = lines[start].slice(lines[start].indexOf(open[1]) + open[1].length);

    for (;;) {
      const at = rest.indexOf(closer);
      if (at !== -1) {
        if (rest.slice(at + closer.length).trim() !== "") return null;
        body.push(rest.slice(0, at));
        return { tex: body.join("\n").trim(), next: index + 1 };
      }
      body.push(rest);
      index += 1;
      if (index >= lines.length) return null;
      rest = lines[index];
    }
  }

  function indentWidth(value) {
    return value.replace(/\t/g, "    ").length;
  }

  /// A list item's marker, its indent, and the column its content starts at. A nested list has to
  /// reach that content column; anything shallower is a sibling of the current item.
  function listMarker(line) {
    if (HORIZONTAL_RULE.test(line)) return null;
    const match = LIST_MARKER.exec(line);
    if (!match) return null;
    const indent = indentWidth(match[1]);
    return {
      indent,
      ordered: /\d/.test(match[2]),
      content: match[4],
      contentIndent: indent + match[2].length + indentWidth(match[3])
    };
  }

  /// Joins the source lines of one paragraph. A single newline is a *soft* break — it collapses to a
  /// space so the text reflows with the window, which is what makes hard-wrapped documents readable.
  /// Only an explicit two-space or backslash line ending survives as a `<br>` (kept as "\n" here).
  function joinParagraph(sourceLines) {
    return sourceLines
      .map((raw, position) => {
        const text = raw.trim().replace(/\\$/, "");
        if (position === sourceLines.length - 1) return text;
        return text + (/(?: {2,}|\\)$/.test(raw) ? "\n" : " ");
      })
      .join("");
  }

  function renderParagraphText(sourceLines) {
    return renderInline(joinParagraph(sourceLines)).replace(/\n/g, "<br>");
  }

  /// Stamps the 0-based source line a block came from onto its opening tag. This is what lets a
  /// split editor point the preview at whatever the caret is on; nothing else reads it.
  function withSourceLine(html, line) {
    return html.replace(/^<([a-z][\w-]*)/i, (match) => `${match} data-src-line="${line}"`);
  }

  function startsBlock(lines, index) {
    const line = lines[index] || "";
    const next = lines[index + 1] || "";
    return /^\s*$/.test(line)
      || /^ {0,3}(#{1,6})\s+/.test(line)
      || /^ {0,3}(```+|~~~+)/.test(line)
      || /^ {0,3}>\s?/.test(line)
      || /^ {0,3}(?:[-+*]|\d+[.)])\s+/.test(line)
      || MATH_BLOCK.test(line)
      || HORIZONTAL_RULE.test(line)
      || (line.includes("|") && isTableDivider(next));
  }

  /// Renders one list (and, recursively, any list nested inside its items) starting at `start`.
  /// Returns the markup plus the index of the first line after the list.
  function parseList(lines, start, lineOffset) {
    const first = listMarker(lines[start]);
    const ordered = first.ordered;
    const baseIndent = first.indent;
    const items = [];
    let index = start;

    while (index < lines.length) {
      const line = lines[index];

      if (/^\s*$/.test(line)) {
        // A blank line only ends the list if nothing after it still belongs to the list.
        let lookahead = index;
        while (lookahead < lines.length && /^\s*$/.test(lines[lookahead])) lookahead += 1;
        if (lookahead >= lines.length) break;
        const upcoming = listMarker(lines[lookahead]);
        const stillInList = upcoming
          ? upcoming.indent >= baseIndent
          : indentWidth(lines[lookahead].match(/^\s*/)[0]) > baseIndent;
        if (!stillInList) break;
        index = lookahead;
        continue;
      }

      const marker = listMarker(line);
      const current = items[items.length - 1];

      if (marker) {
        if (current && marker.indent >= current.contentIndent) {
          const nested = parseList(lines, index, lineOffset);
          current.children.push(nested.html);
          index = nested.next;
          continue;
        }
        if (marker.indent < baseIndent || marker.ordered !== ordered) break;
        items.push({
          lines: [marker.content],
          children: [],
          contentIndent: marker.contentIndent,
          line: lineOffset + index
        });
        index += 1;
        continue;
      }

      // Not a marker: a lazy/indented continuation of the item's own paragraph. Text that follows a
      // nested list, or that opens a block of its own, ends the list instead.
      if (!current || current.children.length || startsBlock(lines, index)) break;
      current.lines.push(line);
      index += 1;
    }

    const tag = ordered ? "ol" : "ul";
    let hasTask = false;
    const html = items.map((item) => {
      const text = joinParagraph(item.lines);
      const task = !ordered && text.match(/^\[([ xX])\]\s+([\s\S]+)$/);
      let body;
      let className = "";
      if (task) {
        hasTask = true;
        className = ' class="task-list-item"';
        const checked = task[1].toLowerCase() === "x";
        body = `<input type="checkbox" disabled${checked ? " checked" : ""}> ${renderInline(task[2]).replace(/\n/g, "<br>")}`;
      } else {
        body = renderInline(text).replace(/\n/g, "<br>");
      }
      return withSourceLine(`<li${className}>${body}${item.children.join("")}</li>`, item.line);
    }).join("");

    return {
      html: withSourceLine(`<${tag}${hasTask ? ' class="task-list"' : ""}>${html}</${tag}>`,
                           items.length ? items[0].line : lineOffset + start),
      next: index
    };
  }

  /// `lineOffset` is the source line the first entry of `markdown` came from. It is only non-zero
  /// for the recursive blockquote pass, whose text is a slice of the document.
  function renderMarkdown(markdown, lineOffset) {
    const lines = String(markdown).replace(/\r\n?/g, "\n").split("\n");
    const output = [];
    const headingCounts = new Map();
    const offset = lineOffset || 0;
    let index = 0;

    while (index < lines.length) {
      const line = lines[index];
      const blockLine = offset + index;

      if (/^\s*$/.test(line)) {
        index += 1;
        continue;
      }

      const fence = line.match(/^ {0,3}(```+|~~~+)\s*([\w.+-]*)\s*$/);
      if (fence) {
        const marker = fence[1][0];
        const minimumLength = fence[1].length;
        const code = [];
        index += 1;
        while (index < lines.length && !new RegExp(`^ {0,3}${marker}{${minimumLength},}\\s*$`).test(lines[index])) {
          code.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        const language = fence[2] ? ` class="language-${escapeAttribute(fence[2])}"` : "";
        output.push(withSourceLine(`<pre><code${language}>${escapeHtml(code.join("\n"))}</code></pre>`, blockLine));
        continue;
      }

      const mathBlock = parseMathBlock(lines, index);
      if (mathBlock) {
        output.push(withSourceLine(mathElement("div", "display", mathBlock.tex), blockLine));
        index = mathBlock.next;
        continue;
      }

      const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (heading) {
        const level = heading[1].length;
        const baseSlug = slugify(heading[2]);
        const count = headingCounts.get(baseSlug) || 0;
        headingCounts.set(baseSlug, count + 1);
        const id = count ? `${baseSlug}-${count + 1}` : baseSlug;
        output.push(withSourceLine(`<h${level} id="${escapeAttribute(id)}">${renderInline(heading[2])}</h${level}>`, blockLine));
        index += 1;
        continue;
      }

      if (HORIZONTAL_RULE.test(line)) {
        output.push(withSourceLine("<hr>", blockLine));
        index += 1;
        continue;
      }

      if (/^ {0,3}>\s?/.test(line)) {
        const quoted = [];
        while (index < lines.length && /^ {0,3}>\s?/.test(lines[index])) {
          quoted.push(lines[index].replace(/^ {0,3}>\s?/, ""));
          index += 1;
        }
        output.push(withSourceLine(`<blockquote>${renderMarkdown(quoted.join("\n"), blockLine)}</blockquote>`, blockLine));
        continue;
      }

      const marker = listMarker(line);
      if (marker && marker.indent <= 3) {
        const list = parseList(lines, index, offset);
        output.push(list.html);
        index = list.next;
        continue;
      }

      if (line.includes("|") && index + 1 < lines.length && isTableDivider(lines[index + 1])) {
        const headers = splitTableRow(line);
        const dividers = splitTableRow(lines[index + 1]);
        const aligns = dividers.map(tableAlignment);
        const bodyRows = [];
        index += 2;
        while (index < lines.length && lines[index].includes("|") && !/^\s*$/.test(lines[index])) {
          bodyRows.push(splitTableRow(lines[index]));
          index += 1;
        }
        const headerHtml = headers.map((cell, cellIndex) =>
          `<th class="align-${aligns[cellIndex] || "left"}">${renderInline(cell)}</th>`
        ).join("");
        const bodyHtml = bodyRows.map((row) => `<tr>${headers.map((_, cellIndex) =>
          `<td class="align-${aligns[cellIndex] || "left"}">${renderInline(row[cellIndex] || "")}</td>`
        ).join("")}</tr>`).join("");
        output.push(withSourceLine(`<div class="table-wrap"><table><thead><tr>${headerHtml}</tr></thead><tbody>${bodyHtml}</tbody></table></div>`, blockLine));
        continue;
      }

      const paragraph = [line];
      index += 1;
      while (index < lines.length && !startsBlock(lines, index)) {
        paragraph.push(lines[index]);
        index += 1;
      }
      output.push(withSourceLine(`<p>${renderParagraphText(paragraph)}</p>`, blockLine));
    }

    return output.join("\n");
  }

  root.MDViewerMarkdown = Object.freeze({
    escapeHtml,
    renderInline,
    renderMarkdown,
    slugify
  });
})(globalThis);
