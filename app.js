(function () {
  "use strict";

  const STORAGE_KEY = "mdviewer.document.v1";
  const THEME_KEY = "mdviewer.theme";
  const DEFAULT_DOCUMENT = `# Offline Markdown Viewer

Open or drop a local **Markdown** file, then edit it with an instant preview.

> Everything runs locally. This app makes no network requests.

## Included

- [x] Live split preview
- [x] Open, edit, save, export, and print
- [x] Tables, task lists, code blocks, links, and local images
- [x] Light and dark themes
- [ ] Write something excellent

| Shortcut | Action |
| :--- | :--- |
| Ctrl/Cmd + O | Open |
| Ctrl/Cmd + S | Save |
| Ctrl/Cmd + F | Find |
| Ctrl/Cmd + B | Bold |

\`\`\`js
const offline = true;
console.log("No CDN required.", offline);
\`\`\`
`;

  const elements = {
    app: document.getElementById("app"),
    workspace: document.getElementById("workspace"),
    editor: document.getElementById("editor"),
    preview: document.getElementById("preview"),
    fileName: document.getElementById("fileName"),
    fileInput: document.getElementById("fileInput"),
    dirtyDot: document.getElementById("dirtyDot"),
    documentStats: document.getElementById("documentStats"),
    cursorPosition: document.getElementById("cursorPosition"),
    saveStatus: document.getElementById("saveStatus"),
    syncButton: document.getElementById("syncButton"),
    searchBar: document.getElementById("searchBar"),
    searchInput: document.getElementById("searchInput"),
    searchStatus: document.getElementById("searchStatus"),
    dropOverlay: document.getElementById("dropOverlay")
  };

  let fileHandle = null;
  let lastSavedContent = "";
  let syncScroll = true;
  let scrollOwner = null;
  let searchMatches = [];
  let currentSearchMatch = -1;
  let saveStatusTimer = null;

  function loadDraft() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
      if (saved && typeof saved.content === "string") {
        elements.fileName.value = saved.name || "untitled.md";
        return saved.content;
      }
    } catch (_) {
      // Storage may be unavailable for file:// pages; the editor still works.
    }
    return DEFAULT_DOCUMENT;
  }

  function persistDraft() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        name: normalizedFileName(),
        content: elements.editor.value
      }));
    } catch (_) {
      // No persistence is preferable to preventing local editing.
    }
  }

  function setStatus(message) {
    elements.saveStatus.textContent = message;
    clearTimeout(saveStatusTimer);
    saveStatusTimer = setTimeout(() => {
      elements.saveStatus.textContent = isDirty() ? "Unsaved changes" : "Saved";
    }, 2200);
  }

  function isDirty() {
    return elements.editor.value !== lastSavedContent;
  }

  function updateDirtyState() {
    const dirty = isDirty();
    elements.dirtyDot.classList.toggle("visible", dirty);
    document.title = `${dirty ? "• " : ""}${normalizedFileName()} — Offline Markdown Viewer`;
  }

  function normalizedFileName(extension = ".md") {
    const raw = elements.fileName.value.trim() || `untitled${extension}`;
    if (extension && !raw.toLowerCase().endsWith(extension)) {
      return `${raw.replace(/\.[^.]+$/, "")}${extension}`;
    }
    return raw;
  }

  function updatePreview() {
    elements.preview.innerHTML = MDViewerMarkdown.renderMarkdown(elements.editor.value);
    const words = (elements.editor.value.trim().match(/\S+/g) || []).length;
    const characters = elements.editor.value.length;
    elements.documentStats.textContent = `${words.toLocaleString()} ${words === 1 ? "word" : "words"} · ${characters.toLocaleString()} ${characters === 1 ? "character" : "characters"}`;
    persistDraft();
    updateDirtyState();
    updateCursorPosition();
    if (!elements.searchBar.hidden) updateSearchMatches(false);
  }

  function updateCursorPosition() {
    const beforeCursor = elements.editor.value.slice(0, elements.editor.selectionStart);
    const lines = beforeCursor.split("\n");
    elements.cursorPosition.textContent = `Ln ${lines.length}, Col ${lines[lines.length - 1].length + 1}`;
  }

  function setDocument(name, content, handle = null) {
    elements.fileName.value = name || "untitled.md";
    elements.editor.value = content;
    fileHandle = handle;
    lastSavedContent = content;
    updatePreview();
    elements.editor.focus();
    elements.editor.setSelectionRange(0, 0);
    setStatus(`Opened ${elements.fileName.value}`);
  }

  function confirmDiscard() {
    return !isDirty() || window.confirm("Discard unsaved changes?");
  }

  async function openFile() {
    if (!confirmDiscard()) return;
    if ("showOpenFilePicker" in window) {
      try {
        const [handle] = await window.showOpenFilePicker({
          multiple: false,
          types: [{
            description: "Markdown",
            accept: { "text/markdown": [".md", ".markdown"], "text/plain": [".txt"] }
          }]
        });
        const file = await handle.getFile();
        setDocument(file.name, await file.text(), handle);
        return;
      } catch (error) {
        if (error && error.name === "AbortError") return;
      }
    }
    elements.fileInput.click();
  }

  async function readDroppedFile(file) {
    if (!file || !confirmDiscard()) return;
    const allowed = /\.(?:md|markdown|txt)$/i.test(file.name) || /^text\//.test(file.type);
    if (!allowed) {
      setStatus("Choose a Markdown or text file");
      return;
    }
    setDocument(file.name, await file.text());
  }

  function download(content, name, type) {
    const link = document.createElement("a");
    const url = URL.createObjectURL(new Blob([content], { type }));
    link.href = url;
    link.download = name;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }

  async function saveMarkdown() {
    const content = elements.editor.value;
    if (fileHandle) {
      try {
        const writable = await fileHandle.createWritable();
        await writable.write(content);
        await writable.close();
        lastSavedContent = content;
        updateDirtyState();
        setStatus(`Saved ${elements.fileName.value}`);
        return;
      } catch (error) {
        if (error && error.name === "AbortError") return;
        fileHandle = null;
      }
    }

    if ("showSaveFilePicker" in window) {
      try {
        fileHandle = await window.showSaveFilePicker({
          suggestedName: normalizedFileName(),
          types: [{
            description: "Markdown",
            accept: { "text/markdown": [".md"] }
          }]
        });
        const writable = await fileHandle.createWritable();
        await writable.write(content);
        await writable.close();
        elements.fileName.value = fileHandle.name;
        lastSavedContent = content;
        updateDirtyState();
        setStatus(`Saved ${elements.fileName.value}`);
        return;
      } catch (error) {
        if (error && error.name === "AbortError") return;
      }
    }

    download(content, normalizedFileName(), "text/markdown;charset=utf-8");
    lastSavedContent = content;
    updateDirtyState();
    setStatus(`Downloaded ${normalizedFileName()}`);
  }

  function exportedHtml() {
    const title = MDViewerMarkdown.escapeHtml(normalizedFileName().replace(/\.md$/i, ""));
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${document.querySelector("style[data-export]")?.textContent || exportStyles()}</style>
</head>
<body><main class="markdown-body">${elements.preview.innerHTML}</main></body>
</html>`;
  }

  function exportStyles() {
    return `:root{color-scheme:light dark}body{margin:0;background:#f6f7f9;color:#20242c;font:16px/1.65 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.markdown-body{box-sizing:border-box;max-width:900px;margin:0 auto;min-height:100vh;padding:48px 56px;background:#fff}h1,h2,h3,h4{line-height:1.25;margin:1.6em 0 .6em}h1{font-size:2.2em;border-bottom:1px solid #dfe2e7;padding-bottom:.3em}h2{font-size:1.65em;border-bottom:1px solid #e7e9ed;padding-bottom:.25em}p,ul,ol{margin:0 0 1.3em}li{margin:.3em 0}a{color:#3568d4}code{background:#eef1f5;border-radius:4px;padding:.15em .35em;font-family:ui-monospace,SFMono-Regular,Consolas,monospace}pre{overflow:auto;background:#171a21;color:#e9edf4;border-radius:8px;padding:18px;white-space:pre;tab-size:2;overflow-wrap:normal;word-break:normal}pre code{background:none;padding:0;line-height:1.5;overflow-wrap:normal;word-break:normal}blockquote{margin:0 0 1.3em;padding:.1em 1em;border-left:4px solid #6b83f2;color:#5e6673;background:#f7f8ff}table{border-collapse:collapse;width:100%;margin:0}th,td{border:1px solid #d9dde5;padding:8px 12px}th{background:#f3f5f8}.table-wrap{overflow:auto;margin-bottom:1.3em}.task-list{list-style:none;padding-left:0}img{max-width:100%}.blocked-media{color:#8b5a00;font-style:italic}@media(prefers-color-scheme:dark){body{background:#111319;color:#dce1ea}.markdown-body{background:#191c23}h1,h2{border-color:#373c47}a{color:#8aa8ff}code,th{background:#292e39}blockquote{background:#202536;color:#bcc5d6}th,td{border-color:#3d4350}}@media print{body,.markdown-body{background:#fff;color:#111}.markdown-body{padding:0;max-width:none}a{color:inherit}}`;
  }

  function exportHtml() {
    const name = normalizedFileName(".html");
    download(exportedHtml(), name, "text/html;charset=utf-8");
    setStatus(`Exported ${name}`);
  }

  function applyFormat(format) {
    const textarea = elements.editor;
    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const selected = textarea.value.slice(start, end);
    let replacement = selected;
    let selectionStart = start;
    let selectionEnd = end;

    const wrap = (before, after, placeholder) => {
      const content = selected || placeholder;
      replacement = `${before}${content}${after}`;
      selectionStart = start + before.length;
      selectionEnd = selectionStart + content.length;
    };

    switch (format) {
      case "bold": wrap("**", "**", "bold text"); break;
      case "italic": wrap("_", "_", "italic text"); break;
      case "strike": wrap("~~", "~~", "struck text"); break;
      case "code": wrap("`", "`", "code"); break;
      case "link": wrap("[", "](https://example.com)", "link text"); break;
      case "heading": prefixLines("## "); return;
      case "quote": prefixLines("> "); return;
      case "unordered-list": prefixLines("- "); return;
      case "task-list": prefixLines("- [ ] "); return;
      case "code-block": wrap("```\n", "\n```", "code"); break;
      default: return;
    }

    textarea.setRangeText(replacement, start, end, "end");
    textarea.setSelectionRange(selectionStart, selectionEnd);
    textarea.focus();
    updatePreview();
  }

  function prefixLines(prefix) {
    const textarea = elements.editor;
    const value = textarea.value;
    const start = value.lastIndexOf("\n", Math.max(0, textarea.selectionStart - 1)) + 1;
    const nextNewline = value.indexOf("\n", textarea.selectionEnd);
    const end = nextNewline === -1 ? value.length : nextNewline;
    const replacement = value.slice(start, end).split("\n").map((line) => `${prefix}${line}`).join("\n");
    textarea.setRangeText(replacement, start, end, "select");
    textarea.focus();
    updatePreview();
  }

  function setView(view) {
    elements.workspace.className = `workspace ${view}`;
    document.querySelectorAll("[data-view]").forEach((button) => {
      button.classList.toggle("active", button.dataset.view === view);
    });
    if (view === "edit") elements.editor.focus();
    if (view === "preview") elements.preview.focus();
    try { localStorage.setItem("mdviewer.view", view); } catch (_) {}
  }

  function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem(THEME_KEY, theme); } catch (_) {}
  }

  function toggleTheme() {
    const current = document.documentElement.dataset.theme;
    applyTheme(current === "dark" ? "light" : "dark");
  }

  function syncPaneScroll(source, target) {
    if (!syncScroll || scrollOwner === target) return;
    scrollOwner = source;
    const sourceRange = source.scrollHeight - source.clientHeight;
    const targetRange = target.scrollHeight - target.clientHeight;
    if (sourceRange > 0 && targetRange > 0) {
      target.scrollTop = (source.scrollTop / sourceRange) * targetRange;
    }
    requestAnimationFrame(() => { scrollOwner = null; });
  }

  function toggleSearch(show) {
    elements.searchBar.hidden = show === undefined ? !elements.searchBar.hidden : !show;
    if (!elements.searchBar.hidden) {
      elements.searchInput.focus();
      elements.searchInput.select();
      updateSearchMatches(false);
    } else {
      elements.editor.focus();
    }
  }

  function updateSearchMatches(moveToFirst = true) {
    const query = elements.searchInput.value;
    searchMatches = [];
    currentSearchMatch = -1;
    if (!query) {
      elements.searchStatus.textContent = "";
      return;
    }
    const haystack = elements.editor.value.toLocaleLowerCase();
    const needle = query.toLocaleLowerCase();
    let position = 0;
    while ((position = haystack.indexOf(needle, position)) !== -1) {
      searchMatches.push(position);
      position += Math.max(needle.length, 1);
    }
    elements.searchStatus.textContent = searchMatches.length ? `${searchMatches.length} matches` : "No matches";
    if (moveToFirst && searchMatches.length) moveSearch(1);
  }

  function moveSearch(direction) {
    if (!searchMatches.length) return;
    currentSearchMatch = (currentSearchMatch + direction + searchMatches.length) % searchMatches.length;
    const start = searchMatches[currentSearchMatch];
    elements.editor.focus();
    elements.editor.setSelectionRange(start, start + elements.searchInput.value.length);
    elements.searchStatus.textContent = `${currentSearchMatch + 1} of ${searchMatches.length}`;
  }

  function handlePreviewClick(event) {
  const link = event.target.closest("a");
  if (!link) return;
  const href = link.getAttribute("href") || "";
  if (!href) return;

  if (href.startsWith("#")) {
    event.preventDefault();
    const id = decodeURIComponent(href.slice(1));
    const target = id ? elements.preview.querySelector(`[id="${CSS.escape(id)}"]`) : null;
    if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
    return;
  }

  // Remote schemes (http/https/mailto/tel/…) already carry target="_blank"; let the browser handle them.
  // Relative paths: best-effort open. The browser sandbox has no file-path access, so loading a sibling
  // document in-place is native-app-only — here we hand it to a new tab, falling back to a hint.
  if (!/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(href)) {
    event.preventDefault();
    const opened = window.open(href, "_blank", "noopener,noreferrer");
    if (!opened) {
      const name = decodeURIComponent(href.split(/[\\/]/).pop() || href);
      setStatus(`Open “${name}” via Open`);
    }
  }
}

function handleShortcut(event) {
    if (!(event.ctrlKey || event.metaKey)) return;
    const key = event.key.toLowerCase();
    const shortcuts = {
      o: () => openFile(),
      s: () => saveMarkdown(),
      f: () => toggleSearch(true),
      b: () => applyFormat("bold"),
      i: () => applyFormat("italic"),
      k: () => applyFormat("link")
    };
    if (shortcuts[key]) {
      event.preventDefault();
      shortcuts[key]();
    }
  }

  elements.editor.value = loadDraft();
  lastSavedContent = elements.editor.value;
  updatePreview();

  let preferredTheme = "light";
  try {
    preferredTheme = localStorage.getItem(THEME_KEY)
      || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  } catch (_) {}
  applyTheme(preferredTheme);
  try { setView(localStorage.getItem("mdviewer.view") || "split"); } catch (_) { setView("split"); }

  elements.editor.addEventListener("input", updatePreview);
  elements.editor.addEventListener("click", updateCursorPosition);
  elements.editor.addEventListener("keyup", updateCursorPosition);
  elements.editor.addEventListener("scroll", () => syncPaneScroll(elements.editor, elements.preview));
  elements.preview.addEventListener("scroll", () => syncPaneScroll(elements.preview, elements.editor));
  elements.preview.addEventListener("click", handlePreviewClick);
  elements.fileName.addEventListener("input", () => {
    persistDraft();
    updateDirtyState();
    fileHandle = null;
  });

  document.getElementById("newButton").addEventListener("click", () => {
    if (confirmDiscard()) setDocument("untitled.md", "");
  });
  document.getElementById("openButton").addEventListener("click", openFile);
  document.getElementById("saveButton").addEventListener("click", saveMarkdown);
  document.getElementById("exportButton").addEventListener("click", exportHtml);
  document.getElementById("printButton").addEventListener("click", () => window.print());
  document.getElementById("themeButton").addEventListener("click", toggleTheme);
  document.getElementById("searchButton").addEventListener("click", () => toggleSearch());
  document.getElementById("searchClose").addEventListener("click", () => toggleSearch(false));
  document.getElementById("searchPrevious").addEventListener("click", () => moveSearch(-1));
  document.getElementById("searchNext").addEventListener("click", () => moveSearch(1));
  document.getElementById("copyButton").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(elements.preview.innerHTML);
      setStatus("Rendered HTML copied");
    } catch (_) {
      setStatus("Clipboard permission was not available");
    }
  });

  elements.syncButton.addEventListener("click", () => {
    syncScroll = !syncScroll;
    elements.syncButton.classList.toggle("active", syncScroll);
    elements.syncButton.setAttribute("aria-pressed", String(syncScroll));
  });
  elements.searchInput.addEventListener("input", () => updateSearchMatches(true));
  elements.searchInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      moveSearch(event.shiftKey ? -1 : 1);
    } else if (event.key === "Escape") {
      toggleSearch(false);
    }
  });
  elements.fileInput.addEventListener("change", async () => {
    await readDroppedFile(elements.fileInput.files[0]);
    elements.fileInput.value = "";
  });
  document.querySelectorAll("[data-format]").forEach((button) => {
    button.addEventListener("click", () => applyFormat(button.dataset.format));
  });
  document.querySelectorAll("[data-view]").forEach((button) => {
    button.addEventListener("click", () => setView(button.dataset.view));
  });
  document.addEventListener("keydown", handleShortcut);

  let dragDepth = 0;
  window.addEventListener("dragenter", (event) => {
    if (!event.dataTransfer?.types.includes("Files")) return;
    event.preventDefault();
    dragDepth += 1;
    elements.dropOverlay.hidden = false;
  });
  window.addEventListener("dragover", (event) => event.preventDefault());
  window.addEventListener("dragleave", (event) => {
    event.preventDefault();
    dragDepth -= 1;
    if (dragDepth <= 0) {
      dragDepth = 0;
      elements.dropOverlay.hidden = true;
    }
  });
  window.addEventListener("drop", async (event) => {
    event.preventDefault();
    dragDepth = 0;
    elements.dropOverlay.hidden = true;
    await readDroppedFile(event.dataTransfer.files[0]);
  });
  window.addEventListener("beforeunload", (event) => {
    if (!isDirty()) return;
    event.preventDefault();
    event.returnValue = "";
  });
})();
