// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the native macOS menu bar (NSApp.mainMenu). Mirrors Electron's
// `emain-menu.ts makeFullAppMenu`: App / File / Edit / View / Window / Workspace
// / Help. Item actions route into the key window's `WaveWindowController`, which
// already centralizes every coordinator op (`menuNewTab`, `menuSplit`, …), so the
// menu generalizes unchanged when the MultiWindow phase introduces N controllers.
//
// Double-firing with `WaveWindowController.handleGlobalKey` is avoided by AppKit's
// documented key-equivalent order: `NSApp.sendEvent` consults the KEY WINDOW's
// `performKeyEquivalent` (the terminal's Cmd-C/V/D/M and the window-level global
// handler) BEFORE `NSApp.mainMenu.performKeyEquivalent`. Every shortcut the global
// handler owns (Cmd-T/N/W/D/M/1-9/[/], Cmd-Shift-W, Cmd-K, Cmd-Shift-O) is therefore
// consumed at the window before the menu is reached — so the matching menu key
// equivalents are DISPLAY-ONLY (discoverability) and never double-fire. Clicking the
// item still works because it routes through the same controller op. The only menu
// equivalents that actually fire are the ones the window declines: the Edit standard
// selectors (first-responder), and Workspace switch (Cmd-Ctrl-1..9, which the global
// handler skips because it requires no Control modifier).

import AppKit

@MainActor
final class MenuBarController: NSObject {
    /// Resolver for the controller a menu action targets — the key window's
    /// `WaveWindowController`, falling back to the main window's. Set by the app
    /// delegate; abstracts away how many windows exist (single today, N in phase F).
    var resolveController: (() -> WaveWindowController?)?

    private weak var workspaceMenu: NSMenu?
    private var workspaceItems: [WorkspaceMenuItem] = []
    private var activeWorkspaceId: String?

    private static let appName = "Wave Terminal"
    private static let helpURL = "https://docs.waveterm.dev"

    /// Build and install the main menu.
    func install() {
        NSApp.mainMenu = buildMainMenu()
    }

    private func controller() -> WaveWindowController? {
        resolveController?()
    }

    // MARK: - Workspace submenu (dynamic, rebuilt on workspace:update-equivalents)

    /// Refresh the Workspace submenu from the active controller's cached list.
    /// Mirrors Electron rebuilding the menu on `workspace:update`.
    func updateWorkspaces(_ items: [WorkspaceMenuItem], activeId: String?) {
        workspaceItems = items
        activeWorkspaceId = activeId
        guard let menu = workspaceMenu else { return }
        rebuildWorkspaceMenu(menu)
    }

    private func rebuildWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let create = NSMenuItem(title: "Create Workspace", action: #selector(createWorkspace), keyEquivalent: "")
        create.target = self
        menu.addItem(create)
        guard !workspaceItems.isEmpty else { return }
        menu.addItem(.separator())
        for (index, item) in workspaceItems.enumerated() {
            let menuItem = NSMenuItem(title: item.name.isEmpty ? "Workspace" : item.name,
                                      action: #selector(switchWorkspace(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.workspaceId
            // Electron assigns Cmd+Ctrl+1..9 to the first nine workspaces. The
            // Control modifier means the window-level global handler (Cmd-only)
            // declines, so these are the one menu shortcut that genuinely fires.
            if index < 9 {
                menuItem.keyEquivalent = String(index + 1)
                menuItem.keyEquivalentModifierMask = [.command, .control]
            }
            if item.workspaceId == activeWorkspaceId {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
    }

    // MARK: - Menu construction

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(makeAppMenu())
        main.addItem(makeFileMenu())
        main.addItem(makeEditMenu())
        main.addItem(makeViewMenu())
        main.addItem(makeWindowMenu())
        main.addItem(makeWorkspaceMenu())
        main.addItem(makeHelpMenu())
        return main
    }

    private func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    /// First-responder action (target nil → responder chain), e.g. the Edit menu
    /// standard selectors and the app-level `terminate:`/`hide:` roles.
    private func responderItem(_ title: String, _ selector: Selector, key: String = "",
                               mask: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        if let mask { item.keyEquivalentModifierMask = mask }
        return item
    }

    /// Controller-routed action (target self → resolves the key window's controller).
    private func controllerItem(_ title: String, _ selector: Selector, key: String = "",
                                mask: NSEvent.ModifierFlags? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let mask { item.keyEquivalentModifierMask = mask }
        if !enabled {
            // Disable explicitly; the parent menu turns off auto-enable so the
            // state sticks regardless of responder validation.
            item.isEnabled = false
        }
        return item
    }

    private func makeAppMenu() -> NSMenuItem {
        submenu(Self.appName) { menu in
            menu.autoenablesItems = false
            menu.addItem(controllerItem("About \(Self.appName)", #selector(showAbout)))
            menu.addItem(.separator())
            let settings = controllerItem("Settings…", #selector(showSettings), key: ",")
            menu.addItem(settings)
            menu.addItem(controllerItem("Edit Config…", #selector(editConfig)))
            menu.addItem(.separator())
            menu.addItem(responderItem("Hide \(Self.appName)", #selector(NSApplication.hide(_:)), key: "h"))
            let hideOthers = responderItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                                           key: "h", mask: [.command, .option])
            menu.addItem(hideOthers)
            menu.addItem(responderItem("Show All", #selector(NSApplication.unhideAllApplications(_:))))
            menu.addItem(.separator())
            // Standard Quit (also Dock → Quit and Cmd-Q): terminates the app, which tears
            // down wavesrv (see WaveAppDelegate.applicationWillTerminate). Closing the last
            // window no longer quits the app, so this is the way out.
            menu.addItem(responderItem("Quit \(Self.appName)", #selector(NSApplication.terminate(_:)), key: "q"))
            // Destructive variant: kills the durable local shells (which normal Quit
            // leaves running for reconnect) before terminating. Routed to the controller
            // so the backend teardown runs first.
            menu.addItem(controllerItem("Quit and Close All Shells", #selector(quitAndCloseAllShells),
                                        key: "q", mask: [.command, .option]))
        }
    }

    private func makeFileMenu() -> NSMenuItem {
        submenu("File") { menu in
            menu.autoenablesItems = false
            menu.addItem(controllerItem("New Tab", #selector(newTab), key: "t"))
            // Cmd-N opens a new window. The window-level global handler consumes Cmd-N
            // first, so this equivalent is display-only; clicking still routes through
            // the controller.
            menu.addItem(controllerItem("New Window", #selector(newWindow), key: "n"))
            menu.addItem(.separator())
            menu.addItem(controllerItem("Reattach Shell Session…", #selector(reattachSession),
                                        key: "j", mask: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(controllerItem("Close Tab", #selector(closeTab), key: "w", mask: [.command, .shift]))
            // No Cmd-W here: the window-level global handler binds Cmd-W to
            // close-focused-block (Wave semantics), so giving Close Window the same
            // equivalent would only mislead — it would never fire (window wins).
            menu.addItem(controllerItem("Close Window", #selector(closeWindow)))
        }
    }

    private func makeEditMenu() -> NSMenuItem {
        // Standard first-responder selectors. Auto-enable stays ON so Copy/Paste/etc.
        // grey out when the responder can't handle them. Cmd-C/Cmd-V overlap the
        // terminal's own `performKeyEquivalent`, which the window consults first — so
        // the terminal handles them and these equivalents only fire for other
        // responders (e.g. the inline tab-rename field).
        submenu("Edit") { menu in
            menu.addItem(responderItem("Undo", Selector(("undo:")), key: "z"))
            menu.addItem(responderItem("Redo", Selector(("redo:")), key: "z", mask: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(responderItem("Cut", #selector(NSText.cut(_:)), key: "x"))
            menu.addItem(responderItem("Copy", #selector(NSText.copy(_:)), key: "c"))
            menu.addItem(responderItem("Paste", #selector(NSText.paste(_:)), key: "v"))
            menu.addItem(responderItem("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        }
    }

    private func makeViewMenu() -> NSMenuItem {
        submenu("View") { menu in
            menu.autoenablesItems = false
            menu.addItem(controllerItem("Split Right", #selector(splitRight), key: "d"))
            menu.addItem(controllerItem("Split Down", #selector(splitDown), key: "d", mask: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(controllerItem("Magnify Block", #selector(magnify), key: "m"))
        }
    }

    private func makeWindowMenu() -> NSMenuItem {
        let item = submenu("Window") { menu in
            // No Cmd-M on Minimize: Wave binds Cmd-M to Magnify (View menu / global
            // handler), so the standard Minimize accelerator is omitted to avoid
            // implying it minimizes.
            menu.addItem(responderItem("Minimize", #selector(NSWindow.performMiniaturize(_:))))
            menu.addItem(responderItem("Zoom", #selector(NSWindow.performZoom(_:))))
            menu.addItem(.separator())
            menu.addItem(responderItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        }
        // Let AppKit append the live window list + manage check marks.
        NSApp.windowsMenu = item.submenu
        return item
    }

    private func makeWorkspaceMenu() -> NSMenuItem {
        let item = submenu("Workspace") { menu in
            menu.autoenablesItems = false
        }
        workspaceMenu = item.submenu
        if let menu = item.submenu { rebuildWorkspaceMenu(menu) }
        return item
    }

    private func makeHelpMenu() -> NSMenuItem {
        let item = submenu("Help") { menu in
            menu.addItem(controllerItem("\(Self.appName) Help", #selector(openHelp)))
        }
        NSApp.helpMenu = item.submenu
        return item
    }

    // MARK: - Actions (routed to the key window's controller)

    @objc private func newTab() { controller()?.menuNewTab() }
    @objc private func reattachSession() { controller()?.showJobPicker() }
    @objc private func newWindow() { controller()?.menuNewWindow() }
    @objc private func closeTab() { controller()?.menuCloseActiveTab() }
    @objc private func closeWindow() { controller()?.window?.performClose(nil) }
    @objc private func splitRight() { controller()?.menuSplit(direction: "horizontal") }
    @objc private func splitDown() { controller()?.menuSplit(direction: "vertical") }
    @objc private func magnify() { controller()?.menuMagnify() }
    @objc private func createWorkspace() { controller()?.menuCreateWorkspace() }
    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller()?.menuSwitchWorkspace(id)
    }
    @objc private func showSettings() { controller()?.menuShowSettings() }
    @objc private func editConfig() { controller()?.menuEditConfig() }
    @objc private func quitAndCloseAllShells() { controller()?.menuQuitAndCloseAllShells() }
    @objc private func showAbout() {
        // CFBundleVersion is the git commit (set by bundle-app.sh); the standard panel
        // shows it as "Version <short> (<commit>)". Add a labeled credits line too.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let credits = NSAttributedString(
            string: "Native build · commit \(build)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    @objc private func openHelp() {
        guard let url = URL(string: Self.helpURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
