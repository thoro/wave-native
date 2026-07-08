// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveApp — the real BlockViewProvider that bridges the chrome (WaveUI) to the
// content modules. The chrome (WaveUI) never imports WaveWeb/WaveTerminal; the
// composition root (this executable) does, and injects this provider via
// `runWaveApp(provider:)`.
//
//   "web"  -> a live WebBlockView (WKWebView, GUARDS §W).
//   "term" -> a live GhosttyTerminalView backed by libghostty-vt (PROTOCOL §4).
//   else   -> the chrome placeholder.
//
// This is also the only place that sees BOTH the config keys (WaveUI's coordinator)
// and the content views, so it owns the LIVE-APPLY of the appearance settings:
//   term:fontsize / term:fontfamily / term:transparency / term:theme  -> terminals
//   web:defaultsearch                                                  -> web panes
// It caches the latest settings/themes from the coordinator's config-reload
// notification (which the coordinator also posts once at bootstrap) and re-applies
// them to the live views with no remount.

import AppKit
import WaveCore
import WaveUI
import WaveWeb
import WaveTerminal

/// Produces real content NSViews for block view types.
final class ComposedBlockViewProvider: BlockViewProvider {
    /// One live terminal: a weak view plus the store/ref needed to re-resolve its
    /// per-pane `term:theme` on a config reload, and its block-meta subscription token.
    private final class TermEntry {
        weak var view: GhosttyTerminalView?
        let store: ObjectStoreProtocol
        let blockRef: ORef
        var token: SubscriptionToken?
        /// Latest shell-reported cwd (OSC 7). Read by `cwdForBlock` so a split can start
        /// the new pane in the source pane's directory.
        var currentCwd: String?
        init(view: GhosttyTerminalView, store: ObjectStoreProtocol, blockRef: ORef) {
            self.view = view
            self.store = store
            self.blockRef = blockRef
        }
    }

    private let fallback = DefaultBlockViewProvider()
    private var termEntries: [String: TermEntry] = [:]
    private let webViews = NSHashTable<WebBlockView>.weakObjects()

    // Latest config snapshot (seeded by the coordinator's config-reload notification).
    private var latestSettings: [String: JSONValue] = [:]
    private var latestThemes: [String: TermThemeColors] = [:]
    private var configObserver: NSObjectProtocol?

    private var appearanceObserver: NSObjectProtocol?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: AppCoordinator.configReloadedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let coordinator = note.object as? AppCoordinator else { return }
            MainActor.assumeIsolated {
                self.applyConfig(
                    settings: coordinator.currentSettings(),
                    themes: coordinator.currentTermThemes())
            }
        }
        // A window's gear popover toggling transparency/blur re-dims its terminals. Each
        // terminal re-derives from its OWN window's `isOpaque`, so re-applying to all live
        // terminals correctly leaves other windows untouched (per-window appearance).
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppCoordinator.windowAppearanceChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self.reapplyTerminalAppearance(in: window) }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    func makeContentView(view: String?, env: BlockEnv) -> NSView {
        switch view {
        case WebBlockConst.viewType:
            // WebBlockView.init starts the model and owns its lifecycle (stop on
            // deinit). It reads `meta.url` and persists navigation on didFinish.
            let model = WebBlockModel(blockId: env.blockRef.oid, transport: env.transport, store: env.store)
            let view = WebBlockView(model: model)
            view.searchTemplate = Self.webSearchTemplate(from: latestSettings)
            webViews.add(view)
            wireWebNav(view: view, bridge: env.webNav)
            // Clicking / focusing the web content focuses this pane (green border).
            let webBlockId = env.blockRef.oid
            view.onFocusRequest = { env.onRequestFocus?(webBlockId) }
            return view
        case TerminalBlockConst.viewType:
            return makeTerminalView(env: env)
        default:
            return fallback.makeContentView(view: view, env: env)
        }
    }

    /// Wire the header's `WebNavBridge` (WaveUI) to the live `WebBlockView` (WaveWeb).
    /// This composition root is the only place that sees both sides, keeping the
    /// chrome free of WaveWeb. Actions point at the view; URL changes flow back into
    /// the bridge so the address bar reflects the live page.
    private func wireWebNav(view: WebBlockView, bridge: WebNavBridge) {
        bridge.goBack = { [weak view] in view?.goBack() }
        bridge.goForward = { [weak view] in view?.goForward() }
        bridge.reload = { [weak view] in view?.reload() }
        bridge.load = { [weak view] in view?.load(rawURL: $0) }
        view.onURLChange = { [weak bridge] url in bridge?.updateURL(url) }
        bridge.updateURL(view.currentURL)
    }

    /// The last working directory a terminal block reported (OSC 7), or nil if it never
    /// reported one. The coordinator's split path queries this (via the delegate seam) to
    /// start the new pane in the source pane's directory — WaveUI never imports
    /// WaveTerminal, so the cwd cache lives here in the composition root.
    func cwdForBlock(_ blockId: String) -> String? {
        return termEntries[blockId]?.currentCwd
    }

    /// GUARDS §W cleanup: drop a deleted web block's persistent data store so its
    /// partition doesn't leak disk. The partition is derived from block meta exactly
    /// as `WebPartitionStore` maps it.
    func releaseResources(forBlock block: Block) {
        // Drop a terminal block's theme subscription when its pane is deleted.
        if let entry = termEntries.removeValue(forKey: block.oid) { entry.token?.cancel() }
        guard block.view == WebBlockConst.viewType else { return }
        let partition = WebBlockState.from(block: block).partition
        WebPartitionStore.shared.removeDataStore(for: partition)
    }

    /// Build the terminal stack: a libghostty-vt-backed sink, a controller that
    /// drives PROTOCOL §4 (resync/backfill/reconcile + input), and the native
    /// render view. Query responses + keystrokes both flow to the pty via the
    /// controller. `mount()` runs async (subscribe-before-backfill, GUARDS §T).
    private func makeTerminalView(env: BlockEnv) -> NSView {
        let blockMeta = env.store.get(env.blockRef)?.asBlock?.meta
        let scrollbackLines = Self.terminalScrollback(from: latestSettings, blockMeta: blockMeta)
        let sink = GhosttySink(
            cols: TermSize.default.cols, rows: TermSize.default.rows,
            // libghostty's max_scrollback is a byte budget; size it for the
            // configured line count at a generous width (wide panes wrap, which
            // costs rows not cells, so this stays roughly line-accurate)
            maxScrollback: GhosttySink.scrollbackBytes(lines: scrollbackLines, cols: 250))
        let controller = TerminalController(
            blockId: env.blockRef.oid,
            tabId: env.tabId,
            transport: env.transport,
            sink: sink,
            initialSize: .default)
        // VT query responses are emitted synchronously inside feed() under the
        // controller lock; respondToPTY defers the send so it never re-enters that
        // non-reentrant lock (which would deadlock + freeze a querying TUI).
        sink.onOutput = { [weak controller] data in controller?.respondToPTY(data) }
        // Bell + OSC desktop notifications: the sink fires these already-deferred on the
        // main queue (off the vt_write/lock stack); the controller stamps block/tab ids
        // and the coordinator (via env) badges the tab + raises a desktop notification.
        sink.onBell = { [weak controller] in controller?.handleBell() }
        sink.onNotification = { [weak controller] title, body in
            controller?.handleNotification(title: title, body: body)
        }
        // OSC 52 clipboard writes: sink → controller → env, already on the main queue.
        sink.onClipboardCopy = { [weak controller] data in controller?.handleClipboardCopy(data) }
        // OSC 7 working-directory reports: the sink fires this already-deferred on the
        // main queue. Record it on the controller AND in this block's TermEntry so a
        // later split can resolve the source pane's cwd by blockId (cwdForBlock).
        let cwdBlockId = env.blockRef.oid
        sink.onPwdChanged = { [weak self, weak controller] cwd in
            controller?.handlePwdChanged(cwd)
            self?.termEntries[cwdBlockId]?.currentCwd = cwd
        }
        controller.onBell = { blockId, tabId in env.onBell?(blockId, tabId) }
        controller.onNotification = { blockId, tabId, title, body in
            env.onNotification?(blockId, tabId, title, body)
        }
        controller.onClipboardCopy = { data in env.onClipboardCopy?(data) }
        let view = GhosttyTerminalView(controller: controller, sink: sink, font: Self.terminalFont(from: latestSettings))
        // Cmd-D / Cmd-Shift-D: the view reports its own blockId; the coordinator
        // queues the backend split (via env.onSplit, wired from BlockEnvFactory).
        view.onSplit = env.onSplit
        // Cmd-M: toggle magnify on this pane (via env.onMagnify, wired from
        // BlockEnvFactory through to the coordinator's local layout dispatch).
        view.onMagnify = env.onMagnify
        // Right-click "Close" closes this pane (via env.onClose, same seam the block
        // frame's header menu uses).
        view.onClose = env.onClose
        // Cmd-click / "Open Link" on an OSC-8 hyperlink splits a web pane (via
        // env.onOpenWebURL, wired through to the coordinator's create path).
        view.onOpenWebURL = env.onOpenWebURL
        // Clicking the terminal content focuses this pane (green border + keyboard focus).
        let termBlockId = env.blockRef.oid
        view.onFocusRequest = { env.onRequestFocus?(termBlockId) }
        // Re-derive translucency when the pane lands in (or moves to) a window, so a split
        // into an already-transparent window comes up translucent immediately.
        view.onDidMoveToWindow = { [weak self, weak view] in
            guard let self, let view, let entry = self.termEntries[termBlockId] else { return }
            self.applyTerminalAppearance(to: view, blockMeta: entry.store.get(entry.blockRef)?.asBlock?.meta)
        }

        // Register + apply the live appearance (font/transparency/theme) up front, then
        // watch this block's meta so a per-pane `term:theme` change re-renders live.
        let entry = TermEntry(view: view, store: env.store, blockRef: env.blockRef)
        termEntries[env.blockRef.oid] = entry
        applyTerminalAppearance(to: view, blockMeta: env.store.get(env.blockRef)?.asBlock?.meta)
        entry.token = env.store.subscribe(env.blockRef) { [weak self, weak view] obj in
            let meta = obj?.asBlock?.meta
            DispatchQueue.main.async {
                guard let self, let view else { return }
                self.applyTermTheme(to: view, blockMeta: meta)
            }
        }

        // Dev/test affordance: run a command shortly after mount (used to drive
        // styled output for renderer verification). Real bytes through the pty.
        if let cmd = ProcessInfo.processInfo.environment["WAVE_NATIVE_DEBUG_TERMCMD"], !cmd.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                controller.sendText(cmd + "\n")
            }
        }
        // Re-run catch-up backfill on every transport reconnect (gap G3). onReconnect
        // is a single slot shared across the transport, so chain onto any prior hook
        // (capture-previous) to keep every mounted terminal's handleReconnect running.
        let previous = env.transport.onReconnect
        env.transport.onReconnect = { [weak controller] in
            previous?()
            Task { try? await controller?.handleReconnect() }
        }
        Task { try? await controller.mount() }
        return view
    }

    // MARK: - Live appearance application

    /// Re-apply the new config to every live view. Called on the coordinator's
    /// config-reload notification (which fires on a `setconfig` AND once at bootstrap).
    private func applyConfig(settings: [String: JSONValue], themes: [String: TermThemeColors]) {
        latestSettings = settings
        latestThemes = themes
        let search = Self.webSearchTemplate(from: settings)
        for view in webViews.allObjects { view.searchTemplate = search }
        for (blockId, entry) in termEntries {
            guard let view = entry.view else {
                entry.token?.cancel()
                termEntries.removeValue(forKey: blockId)
                continue
            }
            applyTerminalAppearance(to: view, blockMeta: entry.store.get(entry.blockRef)?.asBlock?.meta)
        }
    }

    /// Re-apply appearance to live terminals after a window's transparency or
    /// tab background changes. Both signals are PER-WINDOW, so only that
    /// window's terminals are touched (`window` non-nil); other windows'
    /// panes cannot be affected. nil re-applies everywhere (config reloads).
    private func reapplyTerminalAppearance(in window: NSWindow? = nil) {
        for (blockId, entry) in termEntries {
            guard let view = entry.view else {
                entry.token?.cancel()
                termEntries.removeValue(forKey: blockId)
                continue
            }
            if let window, view.window !== window { continue }
            applyTerminalAppearance(to: view, blockMeta: entry.store.get(entry.blockRef)?.asBlock?.meta)
        }
    }

    private func applyTerminalAppearance(to view: GhosttyTerminalView, blockMeta: [String: JSONValue]?) {
        let font = Self.terminalFont(from: latestSettings)
        var alpha = TerminalFontSettings.backgroundAlpha(
            transparency: latestSettings["term:transparency"]?.doubleValue)
        // When the pane's WINDOW is translucent (gear popover transparent/blur), force the
        // terminal background see-through so the blur/desktop shows behind the text — even
        // if `term:transparency` is 0. Composes with term:transparency (whichever is more
        // transparent wins). `view.window?.isOpaque == false` is the per-window signal,
        // standard AppKit, so WaveUI need not reach into WaveTerminal.
        if view.window?.isOpaque == false {
            alpha = min(alpha, CGFloat(WindowAppearance.translucentContentAlpha))
        }
        // A tab background must show through the terminal body (Electron parity:
        // terminals default to 0.5 transparency there). Composes with the rules
        // above -- whichever is more transparent wins.
        if WaveWindowInfo.hasTabBackground(view.window) {
            alpha = min(alpha, 0.5)
        }
        view.applyAppearance(font: font, backgroundAlpha: alpha)
        applyTermTheme(to: view, blockMeta: blockMeta)
    }

    private func applyTermTheme(to view: GhosttyTerminalView, blockMeta: [String: JSONValue]?) {
        let name = AppCoordinator.resolveTermThemeName(blockMeta: blockMeta, settings: latestSettings)
        view.applyTheme(Self.palette(for: name, themes: latestThemes))
    }

    // MARK: - Pure settings → content mappings

    /// The terminal font for the live `term:*` settings (Hack 12 fallback).
    static func terminalFont(from settings: [String: JSONValue]) -> NSFont {
        TerminalFontSettings.font(
            family: settings["term:fontfamily"]?.stringValue,
            size: settings["term:fontsize"]?.doubleValue)
    }

    static let defaultScrollbackLines = 15_000
    static let maxScrollbackLines = 50_000

    /// Effective libghostty max_scrollback (lines) for a NEW sink: `term:scrollback`
    /// with block meta overriding the global setting. The sink stays modest -- the
    /// full on-disk history is reachable through the virtualized history layer, so
    /// this only bounds the always-in-memory live buffer. libghostty cannot change
    /// max_scrollback on a live terminal, so the value applies on sink creation
    /// (new panes / remount / relaunch).
    static func terminalScrollback(from settings: [String: JSONValue], blockMeta: MetaMapType?) -> Int {
        let lines = blockMeta?["term:scrollback"]?.intValue
            ?? settings["term:scrollback"]?.intValue
            ?? Int64(defaultScrollbackLines)
        return Swift.min(Swift.max(Int(lines), 1000), maxScrollbackLines)
    }

    /// `web:defaultsearch` template (Electron default `https://www.google.com/search?q={query}`).
    static func webSearchTemplate(from settings: [String: JSONValue]) -> String? {
        let v = settings["web:defaultsearch"]?.stringValue
        if let v, !v.isEmpty { return v }
        return "https://www.google.com/search?q={query}"
    }

    /// Convert a named theme's hex colours to the renderer palette (empty = no override).
    static func palette(for name: String, themes: [String: TermThemeColors]) -> TerminalColorPalette {
        guard let t = themes[name] else { return TerminalColorPalette() }
        return TerminalColorPalette(
            ansi: t.ansi.map { TermRGB.fromHex($0) },
            foreground: TermRGB.fromHex(t.foreground),
            background: TermRGB.fromHex(t.background),
            cursor: TermRGB.fromHex(t.cursor),
            selection: TermRGB.fromHex(t.selection))
    }
}
