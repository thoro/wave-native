// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveWeb — implements PROTOCOL.md §5 + GUARDS §W: the (WebKit-free) model that
// binds a web block's `meta` to the view. It loads the block from the object
// store, stays live on `waveobj:update` (PROTOCOL.md §2), and persists meta
// changes via the wshrpc "setmeta" command (`webview.tsx:382-386`,
// `wshclient.go:857-859`).
//
// Kept free of WebKit/AppKit so the meta<->state plumbing is testable; the
// WKWebView lives in WebBlockView, which observes `onStateChange`.

import Foundation
import WaveCore

/// Per-block model for a web view. Not a singleton (one instance per block);
/// owns the store subscription and all meta persistence.
public final class WebBlockModel: @unchecked Sendable {
    public let blockId: String
    public let oref: ORef

    private let transport: WaveTransport
    private let store: ObjectStoreProtocol

    private let lock = NSLock()
    private var _state: WebBlockState
    private var subscription: SubscriptionToken?

    /// Invoked (on the main thread) whenever the derived `WebBlockState` changes.
    public var onStateChange: ((WebBlockState) -> Void)?

    public init(blockId: String, transport: WaveTransport, store: ObjectStoreProtocol) {
        precondition(!blockId.isEmpty, "web block requires a non-empty blockId")
        self.blockId = blockId
        self.oref = .block(blockId)
        self.transport = transport
        self.store = store
        let block = store.get(.block(blockId))?.asBlock
        self._state = block.map(WebBlockState.from(block:)) ?? WebBlockState()
    }

    deinit { subscription?.cancel() }

    /// The current derived state (thread-safe snapshot).
    public var state: WebBlockState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Begin tracking live block updates (PROTOCOL.md §2). Idempotent.
    public func start() {
        lock.lock()
        let alreadySubscribed = subscription != nil
        lock.unlock()
        if alreadySubscribed { return }

        let token = store.subscribe(.block(blockId)) { [weak self] obj in
            guard let self else { return }
            let newState = obj?.asBlock.map(WebBlockState.from(block:)) ?? WebBlockState()
            self.applyState(newState)
        }
        lock.lock()
        subscription = token
        lock.unlock()
    }

    /// Stop tracking updates and release the subscription.
    public func stop() {
        lock.lock()
        let token = subscription
        subscription = nil
        lock.unlock()
        token?.cancel()
    }

    private func applyState(_ newState: WebBlockState) {
        lock.lock()
        let changed = newState != _state
        _state = newState
        lock.unlock()
        guard changed else { return }
        dispatchMain { [weak self] in self?.onStateChange?(newState) }
    }

    // MARK: - Persistence (wshrpc "setmeta", GUARDS §W)

    /// GUARDS §W [MUST]: persist navigation so the URL survives reload
    /// (`webview.tsx:382-386`).
    public func persistURL(_ url: String) {
        setMeta([WebMetaKeys.url: .string(url)])
    }

    /// Persist the page homepage (`webview.tsx:setHomepageUrl` block scope).
    public func persistPinnedURL(_ url: String?) {
        setMeta([WebMetaKeys.pinnedUrl: jsonOrNull(url.map(JSONValue.string))])
    }

    /// Persist zoom (`webview.tsx:setZoomFactor` 603-606). nil removes the key.
    public func persistZoom(_ zoom: Double?) {
        let clamped = WebBlockState.clampZoom(zoom)
        setMeta([WebMetaKeys.webZoom: jsonOrNull(clamped.map(JSONValue.double))])
    }

    /// Persist nav-hidden toggle (`webview.tsx:712-721`).
    public func persistHideNav(_ hidden: Bool) {
        setMeta([WebMetaKeys.webHideNav: .bool(hidden)])
    }

    /// Persist user-agent type (`webview.tsx:644-686`). nil resets to default.
    public func persistUserAgentType(_ type: String?) {
        setMeta([WebMetaKeys.webUserAgentType: jsonOrNull(type.map(JSONValue.string))])
    }

    /// Issue a fire-and-forget `setmeta` for `block:<id>` over the default route.
    private func setMeta(_ meta: MetaMapType) {
        precondition(oref.otype == OType.block, "web meta must target a block oref")
        let data = CommandSetMetaData(oref: oref, meta: meta)
        let transport = self.transport
        Task { try? await transport.callVoid(command: WebBlockConst.setMetaCommand, data: data) }
    }

    private func jsonOrNull(_ value: JSONValue?) -> JSONValue { value ?? .null }

    private func dispatchMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
