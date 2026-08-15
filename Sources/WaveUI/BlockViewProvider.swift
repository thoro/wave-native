// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the seam between the chrome (this module) and the content modules
// (WaveTerminal §4, WaveWeb §5). The chrome tiles blocks (PROTOCOL.md §6) but
// does NOT render terminal/web content — that belongs to WaveTerminal/WaveWeb.
//
// A `BlockViewProvider` produces the NSView for a block's *content* given the
// block's view type (`meta.view`, `pkg/waveobj/metaconsts.go:9`) and a
// `BlockEnv` carrying the transport + store the content view needs to do its own
// I/O (e.g. a terminal subscribes to its own `blockfile` events, PROTOCOL §4).
//
// This module ships a `DefaultBlockViewProvider` placeholder so the chrome is
// fully runnable/testable before WaveTerminal/WaveWeb land. They will provide the
// real provider via dependency injection — the chrome never imports their views.

import AppKit
import WaveCore

/// The wiring seam between a web block's navigation chrome (the header, in WaveUI)
/// and its content view (a WKWebView, in WaveWeb). The chrome NEVER imports WaveWeb:
/// the composition root's provider populates the action closures from the live
/// `WebBlockView` and pushes URL updates via `updateURL`, while the header invokes
/// the actions and observes `onURLChange`. Both ends touch this on the main thread.
public final class WebNavBridge: @unchecked Sendable {
    /// Navigation actions, set by the provider to point at the live web view.
    public var goBack: (() -> Void)?
    public var goForward: (() -> Void)?
    public var reload: (() -> Void)?
    /// Load a raw (un-normalized) URL string typed into the address bar.
    public var load: ((String) -> Void)?

    /// The header sets this to mirror the live page URL in the address bar.
    public var onURLChange: ((String?) -> Void)?

    private var _currentURL: String?
    /// The last URL pushed by the provider (so a header mounting late can seed itself).
    public var currentURL: String? { _currentURL }

    public init() {}

    /// Pushed by the provider whenever the page URL changes.
    public func updateURL(_ url: String?) {
        _currentURL = url
        onURLChange?(url)
    }
}

/// Raw `termthemes` colours (hex strings) for one theme, parsed from the live config
/// by the coordinator. The composition root converts these to a renderer palette; the
/// chrome only forwards them, so it stays free of WaveTerminal. Hex strings (not parsed
/// colours) keep this AppKit-free and Sendable.
public struct TermThemeColors: Sendable, Equatable {
    public let name: String
    public let displayName: String
    public let order: Double
    /// ANSI 0–15 (black…white, then bright variants); a nil entry keeps the default.
    public let ansi: [String?]
    public let foreground: String?
    public let background: String?
    public let cursor: String?
    public let selection: String?

    public init(
        name: String, displayName: String, order: Double, ansi: [String?],
        foreground: String?, background: String?, cursor: String?, selection: String?
    ) {
        self.name = name
        self.displayName = displayName
        self.order = order
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
    }
}

/// One entry in the per-pane terminal "Themes" submenu (name = `term:theme` value).
public struct TermThemeMenuItem: Sendable, Equatable {
    public let name: String
    public let displayName: String
    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

/// Everything a block content view needs to talk to the backend.
public struct BlockEnv: Sendable {
    public let transport: WaveTransport
    public let store: ObjectStoreProtocol
    /// The block this content view renders.
    public let blockRef: ORef
    /// The tab the block lives in (needed for ControllerResync, PROTOCOL §4).
    public let tabId: String
    /// The window id (for UIContext on mutations).
    public let windowId: String
    /// The workspace this window is bound to (the tasks pane's workspace scope).
    /// Empty for content-only callers/tests that never navigate.
    public let workspaceId: String
    /// Navigate to a mentioned tab/pane: (workspaceId, tabId, blockId or nil for a
    /// tab-only target). A cross-workspace target focuses/opens that workspace's
    /// window first (task-pill click in global mode).
    public let onNavigate: (@Sendable (String, String, String?) -> Void)?
    /// Raised when this block's content view requests a tab split (Cmd-D /
    /// Cmd-Shift-D). Carries (originating blockId, direction "horizontal"|"vertical").
    public let onSplit: (@Sendable (String, String) -> Void)?
    /// Raised when this block's content view requests magnify toggle (Cmd-M).
    /// Carries the originating blockId.
    public let onMagnify: (@Sendable (String) -> Void)?
    /// Raised when the block requests to be closed (block right-click → "Close Block").
    /// Carries the originating blockId.
    public let onClose: (@Sendable (String) -> Void)?
    /// Raised when the header connection label is clicked: open the connection
    /// typeahead picker for this block. Carries the originating blockId.
    public let onPickConnection: (@Sendable (String) -> Void)?
    /// Raised when a content view requests opening a URL in a new web pane (terminal
    /// OSC-8 Cmd-click / "Open Link"). Carries (originating blockId, raw URL) and
    /// splits a `view:"web"` pane to its right (mirrors `splitFocusedBlock`).
    public let onOpenWebURL: (@Sendable (String, String) -> Void)?
    /// Raised when this block's CONTENT view is clicked / gains focus — moves the green
    /// focus border + keyboard focus to this pane. Carries the originating blockId.
    public let onRequestFocus: (@Sendable (String) -> Void)?
    /// Raised when this terminal rings the BELL. Carries (blockId, tabId). The
    /// coordinator badges the tab + (when not focused) raises a desktop notification.
    public let onBell: (@Sendable (String, String) -> Void)?
    /// Raised when this terminal emits an OSC 9 / OSC 777 desktop notification. Carries
    /// (blockId, tabId, title, body) — `title` is nil for OSC 9.
    public let onNotification: (@Sendable (String, String, String?, String) -> Void)?
    /// Raised when this terminal emits an OSC 52 clipboard WRITE: the decoded contents to
    /// place on the pasteboard. Not block-scoped — a copy just targets the system pasteboard.
    public let onClipboardCopy: (@Sendable (Data) -> Void)?
    /// Live connection-status cache (for the header icon tint + connect overlay).
    /// Also the source of the local-machine display name. Optional so existing
    /// content-only callers/tests need not provide one.
    public let connections: ConnectionStore?
    /// The web block's nav chrome <-> content bridge. Always present (one per block);
    /// only used when the block's view is "web".
    public let webNav: WebNavBridge
    /// Term theme names for the terminal "Themes" submenu (ordered). Empty for non-term
    /// callers/tests.
    public let termThemes: [TermThemeMenuItem]
    /// The global default term theme name (`term:theme` setting, else "default-dark");
    /// the checkmark base when a pane has no per-block override.
    public let defaultTermThemeName: String

    public init(
        transport: WaveTransport, store: ObjectStoreProtocol,
        blockRef: ORef, tabId: String, windowId: String,
        workspaceId: String = "",
        onNavigate: (@Sendable (String, String, String?) -> Void)? = nil,
        onSplit: (@Sendable (String, String) -> Void)? = nil,
        onMagnify: (@Sendable (String) -> Void)? = nil,
        onClose: (@Sendable (String) -> Void)? = nil,
        onPickConnection: (@Sendable (String) -> Void)? = nil,
        onOpenWebURL: (@Sendable (String, String) -> Void)? = nil,
        onRequestFocus: (@Sendable (String) -> Void)? = nil,
        onBell: (@Sendable (String, String) -> Void)? = nil,
        onNotification: (@Sendable (String, String, String?, String) -> Void)? = nil,
        onClipboardCopy: (@Sendable (Data) -> Void)? = nil,
        connections: ConnectionStore? = nil,
        webNav: WebNavBridge = WebNavBridge(),
        termThemes: [TermThemeMenuItem] = [],
        defaultTermThemeName: String = "default-dark"
    ) {
        self.transport = transport
        self.store = store
        self.blockRef = blockRef
        self.tabId = tabId
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.onNavigate = onNavigate
        self.onSplit = onSplit
        self.onMagnify = onMagnify
        self.onClose = onClose
        self.onPickConnection = onPickConnection
        self.onOpenWebURL = onOpenWebURL
        self.onRequestFocus = onRequestFocus
        self.onBell = onBell
        self.onNotification = onNotification
        self.onClipboardCopy = onClipboardCopy
        self.connections = connections
        self.webNav = webNav
        self.termThemes = termThemes
        self.defaultTermThemeName = defaultTermThemeName
    }
}

/// Produces the content `NSView` for a block. Implemented by WaveTerminal/WaveWeb
/// (and composed by the app); the chrome only calls into it.
public protocol BlockViewProvider: AnyObject {
    /// Build (or recycle) the content view for a block. `view` is `meta["view"]`
    /// (e.g. `"term"`, `"web"`); nil/unknown views get a generic placeholder.
    func makeContentView(view: String?, env: BlockEnv) -> NSView

    /// Release any external resources a deleted block held (e.g. a web block's
    /// persistent `WKWebsiteDataStore`). Called by the chrome on the block-close
    /// path so partitions don't leak disk. Default no-op for content-only providers.
    func releaseResources(forBlock block: Block)

    /// The last working directory a terminal block reported (OSC 7), or nil. The chrome
    /// (which never imports WaveTerminal) queries this through the coordinator delegate
    /// so a split can start the new pane in the source pane's cwd. Default nil for
    /// content-only providers / placeholders.
    func cwdForBlock(_ blockId: String) -> String?
}

public extension BlockViewProvider {
    func releaseResources(forBlock block: Block) {}
    func cwdForBlock(_ blockId: String) -> String? { nil }
}

/// Placeholder provider: renders a labeled panel per view type so the chrome can
/// be exercised end-to-end before the real content modules are wired in.
public final class DefaultBlockViewProvider: BlockViewProvider {
    public init() {}

    public func makeContentView(view: String?, env: BlockEnv) -> NSView {
        if view == TasksPaneView.viewType {
            return TasksPaneView(env: env)
        }
        let v = PlaceholderBlockContentView(view: view, blockRef: env.blockRef)
        return v
    }
}

/// A simple labeled content surface used until WaveTerminal/WaveWeb provide the
/// real views. Black like a terminal canvas (STYLE.md §3) with a centered label.
final class PlaceholderBlockContentView: NSView {
    init(view: String?, blockRef: ORef) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.background.cgColor

        let label = NSTextField(labelWithString: "\(view ?? "block") · \(blockRef.oid)")
        label.font = Theme.uiFontMono
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
