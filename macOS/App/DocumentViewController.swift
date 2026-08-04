import AppKit
import UniformTypeIdentifiers
import WebKit

final class DocumentViewController: NSViewController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private let preview = MarkdownPreviewView()
    private let editor: NSTextView
    private let scrollView: NSScrollView
    private let modeControl = NSSegmentedControl(labels: Mode.allCases.map(\.title),
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let themeControl = NSSegmentedControl(labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Drop or open a Markdown file")
    private let toolbar = NSStackView()
    private let splitView = NSSplitView()
    private let editorPane = NSView()
    private let previewPane = NSView()
    private var fileURL: URL?
    private var savedText = ""
    private var currentPreference = ThemeSync.auto
    private var appearanceObserver: NSKeyValueObservation?
    /// Coalesces keystrokes so the live preview re-renders once the typing pauses.
    private var livePreviewTimer: Timer?
    /// Separate, shorter debounce for caret moves — they are cheap (no re-render) and should feel
    /// immediate, unlike a full re-render.
    private var caretSyncTimer: Timer?
    private var hasPositionedDivider = false
    private var toolbarHeightConstraint: NSLayoutConstraint!
    /// True while this controller is the one moving the divider, so its own collapse/expand passes
    /// are not mistaken for the user dragging.
    private var isAdjustingLayout = false

    private static let modeDefaultsKey = "viewMode"
    private static let dividerFractionKey = "splitDividerFraction"
    private static let fullPathTitleDefaultsKey = "showFullPathInWindowTitle"

    /// What the window shows. One control, one stored value — there is no way to be "in Editor with
    /// a preview" or "in Preview without one", which is what two independent toggles allowed.
    enum Mode: String, CaseIterable {
        case preview, split, editor

        var title: String {
            switch self {
            case .preview: return "Preview"
            case .split: return "Split"
            case .editor: return "Editor"
            }
        }

        var showsEditor: Bool { self != .preview }
        var showsPreview: Bool { self != .editor }
    }

    /// Remembered across launches and across opening another file. Preview is only the default for
    /// a fresh install — after that the app comes back the way you left it.
    private(set) var mode: Mode = .preview {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey) }
    }

    /// Share of the split taken by the editor. Remembered across launches, clamped so neither pane
    /// can be restored to an unusable sliver.
    private var dividerFraction: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.dividerFractionKey) as? Double ?? 0.55
            return CGFloat(min(max(stored, 0.2), 0.8))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.dividerFractionKey) }
    }

    private var storedMode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeDefaultsKey) ?? "") ?? .preview
    }

    private(set) var showsFullPathInTitle: Bool = UserDefaults.standard.bool(
        forKey: DocumentViewController.fullPathTitleDefaultsKey
    )

    init() {
        let scrollView = NSTextView.scrollableTextView()
        guard let editor = scrollView.documentView as? NSTextView else {
            fatalError("AppKit did not create the text view")
        }
        self.scrollView = scrollView
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        livePreviewTimer?.invalidate()
        caretSyncTimer?.invalidate()
    }

    override func loadView() {
        view = NSView()
        configureUI()
        preview.linkDelegate = self

        let preference = ThemeSync.preference
        themeControl.selectedSegment = ThemeSync.order.firstIndex(of: preference) ?? 0
        applyPreference(preference)
        observeSystemAppearance()

        showWelcome()
        mode = storedMode
        applyLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.appearance = NSAppearance(named: resolvedDark() ? .darkAqua : .aqua)
        updateWindowTitle()
    }

    private func configureUI() {
        let openButton = NSButton(title: "Open…", target: self, action: #selector(chooseFile))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false

        modeControl.target = self
        modeControl.action = #selector(modeControlChanged)
        modeControl.toolTip = "Preview (⌘1) · Split (⌘2) · Editor (⌘3) · Cycle (⇧⌘E)"

        themeControl.target = self
        themeControl.action = #selector(changeTheme)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [openButton, saveButton, spacer, statusLabel, themeControl, modeControl].forEach(toolbar.addArrangedSubview)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        configureEditor()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        configureSplitView()

        view.addSubview(toolbar)
        view.addSubview(splitView)
        splitView.translatesAutoresizingMaskIntoConstraints = false

        toolbarHeightConstraint = toolbar.heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarHeightConstraint,
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureEditor() {
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 22, height: 20)
        editor.delegate = self
        // Cut/Copy/Paste land on the editor through the responder chain; these make the standard
        // Edit menu's paste-as-plain-text and Find items behave on Markdown source.
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.importsGraphics = false
        editor.isAutomaticLinkDetectionEnabled = false
    }

    /// Editor on the left, live preview on the right, one draggable divider between them. Either
    /// pane can be hidden: Preview mode hides the editor, the toolbar toggle hides the preview.
    private func configureSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        fill(pane: editorPane, with: scrollView)
        fill(pane: previewPane, with: preview)
        // Plain addSubview (not addArrangedSubview): arranged subviews put NSSplitView into
        // constraint-driven mode, where a later layout pass overrides setPosition(_:ofDividerAt:).
        splitView.addSubview(editorPane)
        splitView.addSubview(previewPane)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionDividerIfNeeded()
    }

    /// Places the divider once the split view has a real width. Left to itself, AppKit hands the
    /// whole window to one pane and pins the other at its minimum.
    private func positionDividerIfNeeded() {
        guard !hasPositionedDivider, hasBothPanes else { return }
        let width = splitView.bounds.width
        guard width > 1 else { return }
        hasPositionedDivider = true
        isAdjustingLayout = true
        defer { isAdjustingLayout = false }
        splitView.setPosition((width * dividerFraction).rounded(), ofDividerAt: 0)
    }

    private func fill(pane: NSView, with content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pane.topAnchor),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
    }

    func open(url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            savedText = text
            editor.string = text
            preview.render(markdown: text, sourceURL: url)
            statusLabel.stringValue = url.path
            updateWindowTitle()
            saveButton.isEnabled = false
            // Deliberately keeps the current mode. Snapping back to Preview on every open is what
            // made a full-width editor feel like it kept losing the setting.
            applyLayout()
        } catch {
            presentError(error)
        }
    }

    private func showWelcome() {
        let welcome = """
        # Markdown Viewer

        Open a `.md` or `.markdown` file to preview it offline.

        - **Preview** (`⌘1`) renders it, **Split** (`⌘2`) puts the source and a live preview
          side by side, **Editor** (`⌘3`) is the source alone, full width.
        - Preview is minimal: only the rendered file is shown. Press `⇧⌘E` to cycle through
          Preview → Editor → Split, or `⌘P` for the quick menu.
        - In Split, drag the divider to resize.
        - Cut, copy, paste, undo and find are in the **Edit** menu and the editor's context menu.
        - Press `⌘S` to save.
        - Links to other Markdown files open here; web links open in your browser.
        - Press Space on a Markdown file in Finder for Quick Look.
        """
        editor.string = welcome
        savedText = welcome
        preview.render(markdown: welcome, sourceURL: nil)
        updateWindowTitle()
    }

    @objc func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    @objc func save() {
        guard let fileURL else { return }
        do {
            try editor.string.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = editor.string
            saveButton.isEnabled = false
            renderPreview(preservingScroll: true)
            statusLabel.stringValue = "Saved \(fileURL.path)"
        } catch {
            presentError(error)
        }
    }

    // MARK: - Layout

    @objc private func modeControlChanged() {
        let index = modeControl.selectedSegment
        guard Mode.allCases.indices.contains(index) else { return }
        setMode(Mode.allCases[index])
    }

    @objc func showPreviewMode() { setMode(.preview) }
    @objc func showSplitMode() { setMode(.split) }
    @objc func showEditorMode() { setMode(.editor) }

    /// Preview is deliberately first: it is the chrome-free reading state. `Command-E` belongs to
    /// AppKit's Find menu, so the app exposes this loop as Shift-Command-E.
    @objc func cycleMode() {
        switch mode {
        case .preview: setMode(.editor)
        case .editor: setMode(.split)
        case .split: setMode(.preview)
        }
    }

    /// Flips between Split and Editor, and from Preview opens the editor beside the rendered file.
    @objc func togglePreviewPane() {
        setMode(mode == .split ? .editor : .split)
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        applyLayout()
    }

    private func applyLayout() {
        modeControl.selectedSegment = Mode.allCases.firstIndex(of: mode) ?? 0
        let minimal = mode == .preview
        toolbar.isHidden = minimal
        toolbarHeightConstraint.constant = minimal ? 0 : 50
        isAdjustingLayout = true
        syncPanes()
        splitView.adjustSubviews()
        // NSSplitView can retain its last divider in a layer-backed window even after the second
        // pane has been removed. Hide it at the delegate level as well, then invalidate the whole
        // split view so that cached divider pixel is cleared immediately (without a window resize).
        splitView.needsLayout = true
        splitView.setNeedsDisplay(splitView.bounds)
        splitView.layer?.setNeedsDisplay()
        splitView.displayIfNeeded()
        isAdjustingLayout = false
        // Hiding a pane drops the divider; re-place it from the remembered fraction the next time
        // both panes are up, so Editor -> Split returns to the same proportions.
        if !hasBothPanes { hasPositionedDivider = false }
        positionDividerIfNeeded()

        if mode.showsPreview {
            renderPreview(preservingScroll: mode == .split)
        }
        if mode.showsEditor {
            view.window?.makeFirstResponder(editor)
        }
    }

    private var hasBothPanes: Bool { splitView.subviews.count == 2 }

    /// The split view holds *exactly* the panes that are on screen — a single-pane mode leaves it
    /// with one subview and no second pane to put a divider against.
    ///
    /// Merely hiding a subview is not enough: NSSplitView keeps the divider in its model, reserves
    /// its thickness, and draws it into its own (layer-backed) backing store, where it survives
    /// until something forces a full redraw. That is the hairline that only a window resize cleared.
    private func syncPanes() {
        var wanted = [NSView]()
        if mode.showsEditor { wanted.append(editorPane) }
        if mode.showsPreview { wanted.append(previewPane) }
        guard splitView.subviews != wanted else { return }
        splitView.subviews = wanted
    }

    // MARK: - Live preview

    func textDidChange(_ notification: Notification) {
        saveButton.isEnabled = editor.string != savedText && fileURL != nil
        scheduleLivePreview()
    }

    /// Moving the caret (typing, clicking, arrow keys) walks the preview to the matching block.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard mode.showsPreview, livePreviewTimer == nil else { return }
        caretSyncTimer?.invalidate()
        caretSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.caretSyncTimer = nil
            self.preview.focus(sourceLine: self.caretSourceLine())
        }
    }

    private func scheduleLivePreview() {
        guard mode.showsPreview else { return }
        livePreviewTimer?.invalidate()
        livePreviewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.renderPreview(preservingScroll: true)
        }
    }

    private func renderPreview(preservingScroll: Bool) {
        livePreviewTimer?.invalidate()
        livePreviewTimer = nil
        caretSyncTimer?.invalidate()
        caretSyncTimer = nil
        preview.render(markdown: editor.string, sourceURL: fileURL,
                       preservingScroll: preservingScroll,
                       focusLine: preservingScroll ? caretSourceLine() : nil)
    }

    /// 0-based source line the caret sits on. Counted over UTF-16 units, which is what
    /// `selectedRange()` is expressed in, and without copying the document.
    private func caretSourceLine() -> Int {
        let location = editor.selectedRange().location
        guard location > 0 else { return 0 }
        let units = editor.string.utf16
        guard let caret = units.index(units.startIndex, offsetBy: location, limitedBy: units.endIndex) else {
            return 0
        }
        var line = 0
        var cursor = units.startIndex
        while cursor < caret {
            if units[cursor] == 10 { line += 1 }
            cursor = units.index(after: cursor)
        }
        return line
    }

    // MARK: - Theme

    @objc private func changeTheme() {
        applyPreference(ThemeSync.order[themeControl.selectedSegment])
    }

    var themePreference: String { currentPreference }

    func setThemePreference(_ preference: String) {
        let normalized = ThemeSync.normalize(preference)
        themeControl.selectedSegment = ThemeSync.order.firstIndex(of: normalized) ?? 0
        applyPreference(normalized)
    }

    @objc func selectThemeFromMenu(_ sender: NSMenuItem) {
        guard ThemeSync.order.indices.contains(sender.tag) else { return }
        themeControl.selectedSegment = sender.tag
        applyPreference(ThemeSync.order[sender.tag])
    }

    private func resolvedDark() -> Bool {
        switch currentPreference {
        case ThemeSync.dark: return true
        case ThemeSync.light: return false
        default: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func applyPreference(_ preference: String) {
        currentPreference = ThemeSync.normalize(preference)
        applyResolved(dark: resolvedDark())
        ThemeSync.setPreference(currentPreference)
    }

    private func applyResolved(dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.window?.appearance = appearance

        preview.setTheme(dark ? ThemeSync.dark : ThemeSync.light)
        editor.drawsBackground = true
        editor.backgroundColor = EditorPalette.background(dark)
        editor.textColor = EditorPalette.text(dark)
        editor.insertionPointColor = EditorPalette.text(dark)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorPalette.background(dark)
    }

    /// In Auto mode, follow the system appearance as it changes.
    private func observeSystemAppearance() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.currentPreference == ThemeSync.auto else { return }
                self.applyResolved(dark: self.resolvedDark())
            }
        }
    }

    // MARK: - Window title and quick menu

    func setShowsFullPathInTitle(_ showFullPath: Bool) {
        showsFullPathInTitle = showFullPath
        UserDefaults.standard.set(showFullPath, forKey: Self.fullPathTitleDefaultsKey)
        updateWindowTitle()
    }

    @objc func toggleFullPathInTitle() {
        setShowsFullPathInTitle(!showsFullPathInTitle)
    }

    private func updateWindowTitle() {
        guard let window = view.window else { return }
        guard let fileURL else {
            window.representedURL = nil
            window.title = "Markdown Viewer"
            return
        }
        window.representedURL = fileURL
        window.title = showsFullPathInTitle ? fileURL.path : fileURL.lastPathComponent
    }

    /// A native menu makes the palette keyboard-navigable while keeping Preview mode completely
    /// free of app chrome. It also avoids introducing a second command implementation.
    @objc func showQuickMenu() {
        let menu = NSMenu(title: "Quick Menu")

        func add(_ title: String, action: Selector, state: NSControl.StateValue = .off,
                 target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target ?? self
            item.state = state
            menu.addItem(item)
        }

        add("Open…", action: #selector(chooseFile))
        add("Save", action: #selector(save))
        menu.addItem(.separator())
        add("Preview", action: #selector(showPreviewMode), state: mode == .preview ? .on : .off)
        add("Editor", action: #selector(showEditorMode), state: mode == .editor ? .on : .off)
        add("Split", action: #selector(showSplitMode), state: mode == .split ? .on : .off)
        add("Cycle View Mode", action: #selector(cycleMode))
        menu.addItem(.separator())
        add("Show Full Path in Title", action: #selector(toggleFullPathInTitle),
            state: showsFullPathInTitle ? .on : .off)
        menu.addItem(.separator())
        for (index, title) in ["Theme: Auto", "Theme: Light", "Theme: Dark"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectThemeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == themeControl.selectedSegment ? .on : .off
            menu.addItem(item)
        }
        if let appDelegate = NSApp.delegate {
            menu.addItem(.separator())
            add("Settings…", action: Selector(("showSettings:")), target: appDelegate)
        }

        let point = NSPoint(x: max(20, view.bounds.midX - 120), y: view.bounds.maxY - 8)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: - Menu state

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(save):
            return fileURL != nil
        case #selector(showPreviewMode):
            menuItem.state = mode == .preview ? .on : .off
            return true
        case #selector(showSplitMode):
            menuItem.state = mode == .split ? .on : .off
            return true
        case #selector(showEditorMode):
            menuItem.state = mode == .editor ? .on : .off
            return true
        case #selector(cycleMode):
            return true
        case #selector(togglePreviewPane):
            menuItem.state = mode.showsPreview ? .on : .off
            return true
        case #selector(selectThemeFromMenu(_:)):
            menuItem.state = menuItem.tag == themeControl.selectedSegment ? .on : .off
            return true
        case #selector(toggleFullPathInTitle):
            menuItem.state = showsFullPathInTitle ? .on : .off
            return true
        default:
            return true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfNeeded()
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard editor.string != savedText else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Changes to \(fileURL?.lastPathComponent ?? "this document") have not been saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private enum EditorPalette {
    static func background(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 21/255, green: 24/255, blue: 31/255, alpha: 1)
             : NSColor(srgbRed: 251/255, green: 252/255, blue: 254/255, alpha: 1)
    }
    static func text(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 228/255, green: 232/255, blue: 239/255, alpha: 1)
             : NSColor(srgbRed: 32/255, green: 35/255, blue: 42/255, alpha: 1)
    }
}

extension DocumentViewController: MarkdownPreviewViewDelegate {
    func previewView(_ view: MarkdownPreviewView, openLinkedFile url: URL) {
        open(url: url)
    }
}

extension DocumentViewController: NSSplitViewDelegate {
    private static let minimumPaneWidth: CGFloat = 260

    // Both minimums only apply while both panes are on screen. Clamping unconditionally would
    // reserve `minimumPaneWidth` for a hidden pane and leave a strip of it visible in Editor mode.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard hasBothPanes else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, Self.minimumPaneWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard hasBothPanes else { return proposedMaximumPosition }
        return min(proposedMaximumPosition, splitView.bounds.width - Self.minimumPaneWidth)
    }

    /// A single-pane mode has no meaningful divider. This also tells AppKit not to draw a cached
    /// divider while the split view is transitioning away from Split mode.
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        !hasBothPanes
    }

    /// Double-clicking the divider collapses the preview rather than the editor.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === previewPane
    }

    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        subview === previewPane
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Remember only what the user did, not the passes this controller makes itself.
        guard !isAdjustingLayout, hasPositionedDivider, hasBothPanes else { return }
        let width = splitView.bounds.width
        guard width > 1, editorPane.frame.width > 1, previewPane.frame.width > 1 else { return }
        dividerFraction = editorPane.frame.width / width
    }
}
