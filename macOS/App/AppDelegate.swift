import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var documentController: DocumentViewController?
    private var settingsWindowController: NSWindowController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenus()
        let controller = DocumentViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markdown Viewer"
        window.minSize = NSSize(width: 620, height: 420)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.center()
        window.delegate = controller

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        documentController = controller
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        if let pendingURL {
            controller.open(url: pendingURL)
            self.pendingURL = nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let documentController {
            documentController.open(url: url)
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Default Markdown application

    /// Markdown extensions the app claims. `.mkd` has no system type, so it is only reachable
    /// through the imported declaration in Info.plist.
    private static let markdownExtensions = ["md", "markdown", "mdown", "mkd"]

    /// Registers this copy of the app as the handler for every Markdown type it claims.
    ///
    /// Needed because a locally built, ad-hoc signed app is easy for Launch Services to lose track
    /// of; `build.sh` pins the code signature to a stable designated requirement so the choice made
    /// here survives a rebuild.
    @objc private func makeDefaultMarkdownApp() {
        let bundleURL = Bundle.main.bundleURL
        var types = [UTType]()
        for identifier in ["net.daringfireball.markdown"] {
            if let type = UTType(identifier), !types.contains(type) { types.append(type) }
        }
        for fileExtension in Self.markdownExtensions {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) { types.append(type) }
        }

        let group = DispatchGroup()
        var failure: Error?
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { error in
                if failure == nil { failure = error }
                group.leave()
            }
        }
        group.notify(queue: .main) { [bundleURL] in
            let alert = NSAlert()
            if let failure {
                alert.alertStyle = .warning
                alert.messageText = "Could not set Markdown Viewer as the default"
                alert.informativeText = """
                \(failure.localizedDescription)

                Move the app into /Applications and open it once from there, then try again.
                """
            } else {
                alert.messageText = "Markdown Viewer is now the default Markdown app"
                alert.informativeText = """
                Markdown files (\(Self.markdownExtensions.map { ".\($0)" }.joined(separator: ", "))) \
                open in \(bundleURL.lastPathComponent).
                """
            }
            alert.runModal()
        }
    }

    // MARK: - Menus

    private func configureMenus() {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(titled: "Markdown Viewer", items: appMenuItems()))
        mainMenu.addItem(submenu(titled: "File", items: fileMenuItems()))
        mainMenu.addItem(submenu(titled: "Edit", items: editMenuItems()))
        mainMenu.addItem(submenu(titled: "View", items: viewMenuItems()))

        let windowItem = submenu(titled: "Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)))
        ])
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowItem.submenu
    }

    private func appMenuItems() -> [NSMenuItem] {
        let setDefault = item("Set as Default Markdown App…", #selector(makeDefaultMarkdownApp))
        setDefault.target = self
        let settings = item("Settings…", #selector(showSettings(_:)), key: ",")
        settings.target = self
        return [
            item("About Markdown Viewer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            settings,
            .separator(),
            setDefault,
            .separator(),
            item("Hide Markdown Viewer", #selector(NSApplication.hide(_:)), key: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                 modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Markdown Viewer", #selector(NSApplication.terminate(_:)), key: "q")
        ]
    }

    private func fileMenuItems() -> [NSMenuItem] {
        [
            item("Open…", #selector(DocumentViewController.chooseFile), key: "o"),
            item("Save", #selector(DocumentViewController.save), key: "s"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), key: "w")
        ]
    }

    /// The standard Edit menu. Without it the editor has no ⌘Z/⌘X/⌘C/⌘V/⌘A at all — AppKit delivers
    /// those key equivalents through menu items, not through the text view itself. Every action here
    /// travels the responder chain, so it works in the editor and in the preview's text selection.
    private func editMenuItems() -> [NSMenuItem] {
        let find = submenu(titled: "Find", items: [
            finderAction("Find…", key: "f", modifiers: .command, action: .showFindInterface),
            finderAction("Find Next", key: "g", modifiers: .command, action: .nextMatch),
            finderAction("Find Previous", key: "g", modifiers: [.command, .shift], action: .previousMatch),
            finderAction("Use Selection for Find", key: "e", modifiers: .command, action: .setSearchString)
        ])
        return [
            item("Undo", Selector(("undo:")), key: "z"),
            item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), key: "x"),
            item("Copy", #selector(NSText.copy(_:)), key: "c"),
            item("Paste", #selector(NSText.paste(_:)), key: "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "v",
                 modifiers: [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            find
        ]
    }

    private func viewMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            item("Preview", #selector(DocumentViewController.showPreviewMode), key: "1"),
            item("Split", #selector(DocumentViewController.showSplitMode), key: "2"),
            item("Editor", #selector(DocumentViewController.showEditorMode), key: "3"),
            .separator(),
            item("Cycle View Mode", #selector(DocumentViewController.cycleMode), key: "e",
                 modifiers: [.command, .shift]),
            item("Quick Menu", #selector(DocumentViewController.showQuickMenu), key: "p"),
            item("Show Preview", #selector(DocumentViewController.togglePreviewPane)),
            item("Show Full Path in Title", #selector(DocumentViewController.toggleFullPathInTitle)),
            .separator()
        ]
        for (index, title) in ["Theme: Auto", "Theme: Light", "Theme: Dark"].enumerated() {
            let themeItem = item(title, #selector(DocumentViewController.selectThemeFromMenu(_:)))
            themeItem.tag = index
            items.append(themeItem)
        }
        return items
    }

    @objc func showSettings(_ sender: Any?) {
        guard let documentController else { return }
        if settingsWindowController == nil {
            let settingsController = SettingsViewController(documentController: documentController)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 178),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentViewController = settingsController
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        (settingsWindowController?.contentViewController as? SettingsViewController)?.refresh()
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Menu construction helpers

    private func item(_ title: String, _ action: Selector?, key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        return menuItem
    }

    private func submenu(titled title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private func finderAction(_ title: String, key: String, modifiers: NSEvent.ModifierFlags,
                              action: NSTextFinder.Action) -> NSMenuItem {
        let menuItem = item(title, #selector(NSTextView.performTextFinderAction(_:)), key: key, modifiers: modifiers)
        menuItem.tag = action.rawValue
        return menuItem
    }
}

private final class SettingsViewController: NSViewController {
    private weak var documentController: DocumentViewController?
    private let themeControl = NSSegmentedControl(
        labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let fullPathToggle = NSButton(
        checkboxWithTitle: "Show the full pathname in the window title", target: nil, action: nil
    )

    init(documentController: DocumentViewController) {
        self.documentController = documentController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 178))

        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearanceLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        appearanceLabel.alignment = .right
        themeControl.target = self
        themeControl.action = #selector(themeChanged)

        let titleLabel = NSTextField(labelWithString: "Window title")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.alignment = .right
        fullPathToggle.target = self
        fullPathToggle.action = #selector(titlePreferenceChanged)

        let grid = NSGridView(views: [
            [appearanceLabel, themeControl],
            [titleLabel, fullPathToggle]
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            themeControl.widthAnchor.constraint(equalToConstant: 210)
        ])
        refresh()
    }

    func refresh() {
        guard isViewLoaded, let documentController else { return }
        themeControl.selectedSegment = ThemeSync.order.firstIndex(of: documentController.themePreference) ?? 0
        fullPathToggle.state = documentController.showsFullPathInTitle ? .on : .off
        view.window?.appearance = documentController.view.window?.appearance
    }

    @objc private func themeChanged() {
        guard ThemeSync.order.indices.contains(themeControl.selectedSegment) else { return }
        documentController?.setThemePreference(ThemeSync.order[themeControl.selectedSegment])
        view.window?.appearance = documentController?.view.window?.appearance
    }

    @objc private func titlePreferenceChanged() {
        documentController?.setShowsFullPathInTitle(fullPathToggle.state == .on)
    }
}
