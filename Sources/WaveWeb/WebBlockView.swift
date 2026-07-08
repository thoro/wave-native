// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveWeb — implements PROTOCOL.md §5 + GUARDS §W: the WKWebView-backed NSView.
//
// "Native mapping" from PROTOCOL.md §5:
//   - Read `meta.url` → load (`webview.tsx:850-852,994`).
//   - On navigation finish → persist `url` via wshrpc setmeta (GUARDS §W,
//     `webview.tsx:380-391,1075-1077`).
//   - Map `web:partition` → WKWebsiteDataStore (GUARDS §W,
//     `webview.tsx:857-858,1120`).
//   - back/forward/reload/zoom = WKWebView API (`webview.tsx:315-345,590-607`).
//
// Threading: WKWebView is main-thread only. `WebBlockModel.onStateChange` already
// hops to main, and this view is constructed/driven on the main thread.

import AppKit
import WebKit
import WaveCore

/// The content view for a web block: a single WKWebView bound to block meta via
/// `WebBlockModel`. The navigation chrome (URL bar, back/forward) lives in the
/// block header (WaveUI); this view exposes the corresponding actions and the
/// `hideNav` flag through the model state.
public final class WebBlockView: NSView, WKNavigationDelegate, WKUIDelegate {
    public let model: WebBlockModel

    private var webView: WKWebView!
    /// The URL we last asked WKWebView to load (avoids reloading our own nav).
    private var loadedURL: String?
    /// The partition currently backing `webView` (rebuild required on change).
    private var currentPartition: String?
    /// The user-agent type currently applied (reload required on change).
    private var currentUserAgentType: String?
    /// Optional search-template (from `web:defaultsearch`); injected by WaveUI.
    public var searchTemplate: String?

    /// Notifies the host (the block header's address bar, wired by the composition
    /// root) of the URL to display. Emitted on load + navigation finish. The chrome
    /// (WaveUI) never imports this view; the provider bridges this callback to the
    /// header's `WebNavBridge`.
    public var onURLChange: ((String?) -> Void)?

    /// The URL the address bar should show: the page's committed URL, falling back
    /// to the state's effective (last-navigated / pinned) URL before first commit.
    public var currentURL: String? {
        webView.url?.absoluteString ?? model.state.effectiveURL
    }

    public init(model: WebBlockModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let state = model.state
        currentPartition = state.partition
        currentUserAgentType = state.userAgentType
        buildWebView(partition: state.partition, userAgentType: state.userAgentType)

        model.onStateChange = { [weak self] newState in
            self?.apply(newState)
        }
        model.start()
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { model.stop() }

    // MARK: - WebView construction

    private func buildWebView(partition: String?, userAgentType: String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebPartitionStore.shared.dataStore(for: partition)
        // Make the DEFAULT user agent read as desktop Safari (WKWebView omits the
        // Version/Safari token otherwise, which degrades Google et al.). A mobile
        // `web:useragenttype` still fully overrides this via `customUserAgent` below.
        config.applicationNameForUserAgent = WebUserAgent.desktopAppName

        let newWebView = WKWebView(frame: bounds, configuration: config)
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.autoresizingMask = [.width, .height]
        newWebView.allowsBackForwardNavigationGestures = true
        // STYLE.md §3: black behind the page (the Electron app paints #000 behind
        // the transparent canvas). `underPageBackgroundColor` is public (macOS 12+).
        newWebView.underPageBackgroundColor = .black
        newWebView.customUserAgent = WebUserAgent.string(for: userAgentType)

        if let old = webView {
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.removeFromSuperview()
        }
        webView = newWebView
        addSubview(newWebView)
        loadedURL = nil
    }

    // MARK: - State reconciliation

    private func apply(_ state: WebBlockState) {
        // Partition is immutable on a WKWebView — a change requires a rebuild.
        if state.partition != currentPartition {
            currentPartition = state.partition
            currentUserAgentType = state.userAgentType
            buildWebView(partition: state.partition, userAgentType: state.userAgentType)
            applyZoom(state.zoom)
            loadEffectiveURL(state)
            return
        }

        // User-agent type change → set UA + reload (`webview.tsx:999-1016`).
        if state.userAgentType != currentUserAgentType {
            currentUserAgentType = state.userAgentType
            webView.customUserAgent = state.userAgentString
            webView.reload()
        }

        applyZoom(state.zoom)
        loadEffectiveURL(state)
    }

    private func applyZoom(_ zoom: Double?) {
        let factor = WebBlockState.clampZoom(zoom) ?? 1.0
        if webView.pageZoom != factor {
            webView.pageZoom = factor
        }
    }

    private func loadEffectiveURL(_ state: WebBlockState) {
        guard let raw = state.effectiveURL, !raw.isEmpty else { return }
        load(rawURL: raw)
    }

    // MARK: - Public actions (driven by the block header in WaveUI)

    /// Normalize and load a URL (`webview.tsx:loadUrl` 431-445). Skips the load
    /// if we already requested it or the page is already showing it — this also
    /// prevents the `didFinish` → setmeta → state-change loop from re-loading.
    public func load(rawURL: String) {
        let normalized = WebURLNormalizer.ensureScheme(rawURL, searchTemplate: searchTemplate)
        if normalized == loadedURL { return }
        if webView.url?.absoluteString == normalized { return }
        guard let url = URL(string: normalized) else { return }
        loadedURL = normalized
        webView.load(URLRequest(url: url))
        onURLChange?(normalized)
    }

    public func goBack() { if webView.canGoBack { webView.goBack() } }
    public func goForward() { if webView.canGoForward { webView.goForward() } }
    public func reload() { webView.reload() }
    public func stopLoading() { webView.stopLoading() }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }

    /// Set + persist zoom (`webview.tsx:setZoomFactor`).
    public func setZoom(_ factor: Double?) {
        applyZoom(factor)
        model.persistZoom(factor)
    }

    /// Accept first responder so the block-frame focus path (`BlockFrameView.
    /// focusContent()` → `window.makeFirstResponder(self)`) actually routes keyboard
    /// focus into the web pane. Without this, `makeFirstResponder` skips the view
    /// (NSView defaults to `false`) and the pane never gets key focus — so the green
    /// focus border and window-level shortcuts (Cmd-W/Cmd-R) never target it, unlike a
    /// terminal (which accepts first responder).
    public override var acceptsFirstResponder: Bool { true }

    /// Raised when this pane gains focus, so the owner moves the green border to it.
    /// Wired by the composition root via `BlockEnv.onRequestFocus`.
    public var onFocusRequest: (() -> Void)?

    /// Give keyboard focus to the page (`webview.tsx:giveFocus`).
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        onFocusRequest?()
        return window?.makeFirstResponder(webView) ?? false
    }

    // MARK: - WKNavigationDelegate (GUARDS §W: persist on finish)

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let urlString = webView.url?.absoluteString, !urlString.isEmpty else { return }
        loadedURL = urlString
        model.persistURL(urlString)
        onURLChange?(urlString)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // -999 (NSURLErrorCancelled) is the WebKit analog of Electron's ERR_ABORTED;
        // it is expected during fast re-navigation and is not surfaced as an error.
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        NSLog("WebBlockView load failed for block %@: %@", model.blockId, error.localizedDescription)
    }

    // MARK: - WKUIDelegate (target=_blank → load in place)

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Mirror the renderer: open links targeting a new window in the same view
        // rather than spawning a detached window (`webview.tsx:1029-1033`).
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            loadedURL = url.absoluteString
            webView.load(navigationAction.request)
        }
        return nil
    }
}
