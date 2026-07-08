// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-6 — Web block (docs/E2E.md "E2E-6 Web block"), driven against a REAL
// `wavesrv` (no mocks of the broker/DB/pty — see WaveServerProcess.swift). Uses
// the REAL transport (WaveTransportClient), REAL object store (ObjectStore),
// REAL command wrappers (WaveCommands) and the REAL web model (WebBlockModel).
//
// Gates verified here:
//   GUARDS §W [MUST] "Persist navigation: on WKWebView didFinish, write
//     SetMetaCommand { oref: block:<id>, meta: { url } } so the URL survives
//     reload" (`webview.tsx:382-386`). The native navigate→persist path is
//     `WebBlockModel.persistURL` — exactly what WebBlockView's `didFinish`
//     delegate calls. We exercise it end-to-end, then "reload" by re-fetching
//     from the backend with a FRESH (empty-cache) object store.
//   GUARDS §B [MUST] the persisted change rides back as a `waveobj:update` event
//     (scope `block:<id>`, `wcore.SendWaveObjUpdate`) into the SAME store cache
//     the model subscribes to — asserted via the model's live state.
//   GUARDS §W [MUST] "Map web:partition → a distinct WKWebsiteDataStore so
//     per-block sessions/cookies stay isolated": two blocks with different
//     `web:partition` resolve to distinct, isolated data stores; same partition
//     shares one; nil/empty → the shared default.
//   PROTOCOL.md §5 — a web block is a generic Block with `meta.view == "web"`,
//     created over the HTTP `ObjectService.CreateBlock` service.
//
// MAC-LINK / scope note: the *content-level* cookie round-trip (write a cookie in
// block A's WKWebView, assert it is absent in block B's) requires a running
// windowserver + a live WKWebView, which belongs to the E2E-7 GUI lane
// (docs/E2E.md). Additionally a *named persistent* store
// (`WKWebsiteDataStore(forIdentifier:)`) is macOS 14+, so on the macOS 13 target
// persistent partitions intentionally fall back to the shared default
// (WebPartitionStore.swift). This test therefore asserts isolation at the
// data-store identity layer (deterministic, headless) — the part the native
// client controls — and the live-cookie assertion is flagged for the GUI lane.

import XCTest
import WebKit
import WaveCore
import WaveCommands
@testable import WaveProtocol
@testable import WaveStore
@testable import WaveWeb

final class WebBlockE2ETests: XCTestCase {
    private var server: WaveServerProcess!
    private var transport: WaveTransportClient!
    private var store: ObjectStore!
    private var commands: WaveCommands!

    private var windowId = ""
    private var workspaceId = ""
    private var tabId = ""

    override func setUp() async throws {
        // Real backend (no mocks). Skips cleanly when no wavesrv binary is present.
        server = try WaveServerProcess.startOrSkip()
        transport = WaveTransportClient(wavesrvPath: server.binaryPath)
        // The harness already spawned + discovered the server; inject that running
        // server (addrs + auth key) so the transport's HTTP client is live without
        // launching a second process (mirrors RecordingTransport.spawn).
        transport._configureServerForTesting(addrs: server.addrs, authKey: server.authKey)

        // PROTOCOL.md §7.2 — a fresh data dir makes wavesrv bootstrap a client +
        // starter workspace + tab + window (`wcore.go:32`), so GetClientData yields
        // a usable window.
        let clientRtn = try await transport.callService(
            WebCallType(service: "client", method: "GetClientData", args: []))
        windowId = clientRtn.data?["windowids"]?.arrayValue?.first?.stringValue ?? ""
        try XCTSkipIf(windowId.isEmpty, "wavesrv bootstrap produced no window")

        // PROTOCOL.md §7.3-4 — open the WS with ?stableid=window:<id> + announce.
        try await transport.connect(routeId: WaveRoute.window(windowId))

        store = ObjectStore(transport: transport)

        // PROTOCOL.md §7.6 — resolve window → workspace → active tab.
        let window = try await store.load(.window(windowId))
        workspaceId = try XCTUnwrap(window.asWindow?.workspaceid)
        let workspace = try await store.load(.workspace(workspaceId))
        tabId = try XCTUnwrap(workspace.asWorkspace?.activetabid)
        XCTAssertFalse(tabId.isEmpty, "starter workspace has no active tab")

        let win = windowId, tab = tabId
        commands = WaveCommands(transport: transport, store: store) {
            UIContext(windowid: win, activetabid: tab)
        }
    }

    override func tearDown() {
        transport?.disconnect()
        server?.terminate()
        commands = nil
        store = nil
        transport = nil
        server = nil
    }

    // MARK: - Helpers

    /// Create a real web block (`meta.view == "web"`, PROTOCOL.md §5) on the active
    /// tab via the HTTP `ObjectService.CreateBlock` service. The response's inline
    /// `updates` land in the store (GUARDS §B).
    private func createWebBlock(url: String?, partition: String? = nil) async throws -> String {
        var meta: MetaMapType = [WebMetaKeys.view: .string(WebBlockConst.viewType)]
        if let url { meta[WebMetaKeys.url] = .string(url) }
        if let partition { meta[WebMetaKeys.webPartition] = .string(partition) }
        let blockId = try await commands.createBlock(tabId: tabId, blockDef: BlockDef(meta: meta))
        XCTAssertFalse(blockId.isEmpty, "CreateBlock returned an empty blockId")
        return blockId
    }

    /// Re-fetch the block from the backend and return its persisted `meta.url`.
    private func backendURL(_ blockId: String, store target: ObjectStore? = nil) async throws -> String? {
        let s = target ?? store!
        let obj = try await s.load(.block(blockId))
        return obj.asBlock?.meta[WebMetaKeys.url]?.stringValue
    }

    /// Poll `condition` until it returns a non-nil value or the timeout elapses.
    /// Awaits eventually-consistent backend state (fire-and-forget `setmeta`).
    private func poll<T>(
        timeout: TimeInterval = 8.0, intervalMs: UInt64 = 25,
        _ condition: () async -> T?
    ) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = await condition() { return v }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        return await condition()
    }

    // MARK: - GUARDS §W: navigate persists url; reload → same url

    func testNavigatePersistsURLAndSurvivesReload() async throws {
        let blockId = try await createWebBlock(url: "https://start.example/")

        // Sanity: the block exists with its initial url (PROTOCOL.md §5). Loading it
        // also guarantees the cache is populated before the model binds.
        let initial = try await backendURL(blockId)
        XCTAssertEqual(initial, "https://start.example/")

        // The model is the exact object WebBlockView binds; `persistURL` is what its
        // WKWebView `didFinish` delegate calls (GUARDS §W).
        let model = WebBlockModel(blockId: blockId, transport: transport, store: store)
        model.start()
        defer { model.stop() }
        XCTAssertEqual(model.state.url, "https://start.example/")

        // "Navigate": persist a new url. Fire-and-forget, like a real didFinish.
        let navURL = "https://wave.dev/native-e2e?ts=\(Int(Date().timeIntervalSince1970))"
        model.persistURL(navURL)

        // GUARDS §B: SetMeta's change rides back purely as a `waveobj:update` event
        // (scope block:<id>) into the model's subscribed store — no explicit load.
        // This is the live-update path; asserting it FIRST keeps it independent of
        // the backend re-fetch below.
        let liveURL = await poll { model.state.url == navURL ? model.state.url : nil }
        XCTAssertEqual(liveURL, navURL, "waveobj:update did not refresh the model (GUARDS §B)")

        // GUARDS §W: the new url is durable on the server (eventually consistent).
        let persisted = try await backendURL(blockId)
        XCTAssertEqual(persisted, navURL, "SetMeta did not persist url to wavesrv (GUARDS §W)")

        // "Reload": a FRESH store (empty cache) re-fetches from the backend.
        let freshStore = ObjectStore(transport: transport)
        let reloaded = try await freshStore.load(.block(blockId))
        XCTAssertEqual(
            reloaded.asBlock?.meta[WebMetaKeys.url]?.stringValue, navURL,
            "url did not survive reload (GUARDS §W)")
        XCTAssertEqual(WebBlockState.from(block: try XCTUnwrap(reloaded.asBlock)).url, navURL)
        // The view type is preserved across the meta merge (SetMeta merges keys).
        XCTAssertEqual(reloaded.asBlock?.view, WebBlockConst.viewType)
    }

    // MARK: - GUARDS §W: distinct web:partition → isolated sessions

    func testDistinctPartitionsAreIsolated() async throws {
        let blockA = try await createWebBlock(url: "https://a.example/", partition: "e2e-a")
        let blockB = try await createWebBlock(url: "https://b.example/", partition: "e2e-b")
        XCTAssertNotEqual(blockA, blockB)

        let a = try await store.load(.block(blockA))
        let b = try await store.load(.block(blockB))
        let stateA = WebBlockState.from(block: try XCTUnwrap(a.asBlock))
        let stateB = WebBlockState.from(block: try XCTUnwrap(b.asBlock))

        // The partitions round-trip through the real backend distinctly.
        XCTAssertEqual(stateA.partition, "e2e-a")
        XCTAssertEqual(stateB.partition, "e2e-b")
        XCTAssertNotEqual(stateA.partition, stateB.partition)

        // GUARDS §W: distinct partitions → distinct WKWebsiteDataStore (isolated
        // cookies/sessions); same partition → same store; nil/empty → default.
        let registry = WebPartitionStore()
        let storeA = registry.dataStore(for: stateA.partition)
        let storeB = registry.dataStore(for: stateB.partition)
        XCTAssertFalse(storeA === storeB, "distinct partitions must not share a data store")
        XCTAssertTrue(storeA === registry.dataStore(for: "e2e-a"), "same partition must reuse its store")
        XCTAssertFalse(storeA === registry.dataStore(for: nil), "named partition must not be the default")
        // Ephemeral named partitions are isolated in-memory sessions on all macOS.
        XCTAssertFalse(storeA.isPersistent)
        XCTAssertFalse(storeB.isPersistent)
    }

    // MARK: - GUARDS §W: empty/nil partition shares the default session

    func testNoPartitionUsesSharedDefaultStore() async throws {
        let blockId = try await createWebBlock(url: "https://shared.example/")
        let obj = try await store.load(.block(blockId))
        let state = WebBlockState.from(block: try XCTUnwrap(obj.asBlock))
        XCTAssertNil(state.partition, "no web:partition → nil (shared default session)")

        let registry = WebPartitionStore()
        XCTAssertTrue(
            registry.dataStore(for: state.partition) === WKWebsiteDataStore.default(),
            "blocks without a partition share the default persistent store (GUARDS §W)")
    }
}
