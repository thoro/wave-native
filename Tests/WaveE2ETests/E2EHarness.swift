// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E harness (see docs/E2E.md "Core: a real backend per test class"). Spawns a
// REAL `wavesrv` child — no mocks of the broker / DB / pty / shell — in an
// isolated temp data+config home with a fresh random auth key (GUARDS §P), parses
// its `WAVESRV-ESTART` line for the ws/web TCP addresses, and wires the concrete
// `WaveTransportClient` + `ObjectStore` + `WaveCommands` under test against it.
//
// The only substitution permitted by E2E.md is in the terminal byte-stream test
// (E2E-4): libghostty is replaced by a CAPTURING SINK so the merged byte stream
// can be asserted exactly. That sink lives here (`LockedCapturingSink`) and stands
// in for `WaveTerminal.GhosttySink` — it is thread-safe because live `blockfile`
// events are fed from the transport's delivery thread while the test polls from
// another thread.
//
// Implements the §7 init prefix needed to reach a live terminal block:
//   spawn -> GetClientData -> window -> workspace -> active tab -> CreateBlock(term)
//   -> SetActiveTab (GUARDS §C) -> TerminalController.mount() (GUARDS §T order).

import XCTest
import WaveCore
@testable import WaveProtocol
@testable import WaveTerminal
import WaveStore
import WaveCommands

// MARK: - Harness errors

enum E2EError: Error, CustomStringConvertible {
    case missingBinary(String)
    case timeout(String)
    case bootstrap(String)

    var description: String {
        switch self {
        case let .missingBinary(m): return "wavesrv binary unavailable: \(m)"
        case let .timeout(m): return "e2e timeout: \(m)"
        case let .bootstrap(m): return "e2e bootstrap failed: \(m)"
        }
    }
}

/// Resolve the `wavesrv` binary to drive. CI vendors/builds a pinned binary and
/// exports its path (docs/E2E.md "Vendor a known-good wavesrv binary"). When it is
/// absent we `XCTSkip` (an environment prerequisite is missing) rather than fail —
/// this is NOT skipping a failing assertion, it is declining to run an integration
/// gate that has no backend to talk to.
func requireWavesrvBinary() throws -> String {
    let env = ProcessInfo.processInfo.environment
    let candidates = ["WAVE_E2E_WAVESRV", "WAVE_NATIVE_WAVESRV", "WAVE_WAVESRV_PATH", "WAVESRV_PATH"]
    for key in candidates {
        if let path = env[key], !path.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2EError.missingBinary("\(key)=\(path) is not an executable file")
            }
            return path
        }
    }
    throw XCTSkip("set one of \(candidates) to a wavesrv binary to run the e2e gates")
}

// MARK: - Capturing sink (the only libghostty substitution, E2E.md)

/// Thread-safe capturing terminal sink — the libghostty stand-in for E2E-4. The
/// reconciled byte stream is appended here so a test can assert it equals the
/// shell's real output byte-for-byte (GUARDS §T "[CHECK]").
final class LockedCapturingSink: TerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private var clears = 0
    private var size: TermGridSize?

    func feed(_ bytes: Data) { lock.lock(); buf.append(bytes); lock.unlock() }
    func clear() { lock.lock(); buf.removeAll(keepingCapacity: true); clears += 1; lock.unlock() }
    func setSize(cols: Int, rows: Int) { lock.lock(); size = TermGridSize(cols: cols, rows: rows); lock.unlock() }

    /// Snapshot of all bytes received since the last clear.
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return buf }
    /// Count of `truncate`-driven clears observed.
    var clearCount: Int { lock.lock(); defer { lock.unlock() }; return clears }
    var lastSize: TermGridSize? { lock.lock(); defer { lock.unlock() }; return size }
}

// MARK: - Updates bridge (GUARDS §B)

/// Forwards the transport's inline `WebReturnType.updates` into the object cache,
/// the same way `WaveStore` is wired into the app (GUARDS §B).
final class StoreUpdatesBridge: WaveTransportUpdatesDelegate, @unchecked Sendable {
    private let store: ObjectStoreProtocol
    init(_ store: ObjectStoreProtocol) { self.store = store }
    func transport(_ transport: WaveTransportClient, didReceive updates: [WaveObjUpdate]) {
        store.applyUpdates(updates)
    }
}

// NOTE: the real `wavesrv` process wrapper (`WaveServerProcess`) lives in
// WaveServerProcess.swift — the single canonical definition shared by every
// real-backend gate. This file used to declare a second copy, which collided at
// link time and failed the whole WaveE2ETests target; it now reuses the canonical
// one (sync `init(binaryPath:)` + `startOrSkip()`).

// MARK: - Terminal fixture (drives a real shell over a real wavesrv)

/// A fully wired, mounted terminal block on a real wavesrv with a capturing sink.
/// Built via `make()`; provides the send/poll/extract helpers E2E-4 needs.
final class TerminalE2EFixture {
    let server: WaveServerProcess
    let transport: WaveTransportClient
    let store: ObjectStore
    let commands: WaveCommands
    let controller: TerminalController
    let sink: LockedCapturingSink

    let windowId: String
    let workspaceId: String
    let tabId: String
    let blockId: String

    private let bridge: StoreUpdatesBridge

    private init(
        server: WaveServerProcess, transport: WaveTransportClient, store: ObjectStore,
        commands: WaveCommands, controller: TerminalController, sink: LockedCapturingSink,
        bridge: StoreUpdatesBridge, windowId: String, workspaceId: String,
        tabId: String, blockId: String
    ) {
        self.server = server
        self.transport = transport
        self.store = store
        self.commands = commands
        self.controller = controller
        self.sink = sink
        self.bridge = bridge
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.blockId = blockId
    }

    /// Spawn + §7 init + create a terminal block + mount the controller.
    static func make(initialSize: TermSize) async throws -> TerminalE2EFixture {
        let binary = try requireWavesrvBinary()
        let server = try WaveServerProcess(binaryPath: binary)

        // Configure the concrete transport against the already-spawned process so
        // the test owns the process lifecycle for deterministic teardown.
        let transport = WaveTransportClient(wavesrvPath: binary)
        transport._configureServerForTesting(addrs: server.addrs, authKey: server.authKey)
        // Make reconnect attempts instant in tests (no backoff sleeps).
        transport.reconnectDelayProvider = { _ in 0 }

        // §7.2: GetClientData (HTTP-only; works before the WS is up). Retry until
        // EnsureInitialData has created the bootstrap window.
        let client = try await Self.bootstrapClient(transport: transport)
        guard let windowId = client.windowids.first, !windowId.isEmpty else {
            throw E2EError.bootstrap("client has no windows after bootstrap")
        }

        // §7.3-7.4: open the WS, announce route window:<id>.
        try await transport.connect(routeId: WaveRoute.window(windowId))

        let store = ObjectStore(transport: transport)
        let bridge = StoreUpdatesBridge(store)
        transport.updatesDelegate = bridge

        // Resolve window -> workspace -> active tab via the object store.
        let activeTabRef = ActiveTabRef()
        let commands = WaveCommands(transport: transport, store: store, uiContext: {
            UIContext(windowid: windowId, activetabid: activeTabRef.value)
        })
        let window = try await commands.getWindow(windowId)
        let workspace = try await commands.getWorkspace(window.workspaceid)
        guard !workspace.activetabid.isEmpty else {
            throw E2EError.bootstrap("workspace \(workspace.oid) has no active tab")
        }
        let tabId = workspace.activetabid
        activeTabRef.value = tabId

        // Create a terminal block (view=term, controller=shell) on the active tab.
        let blockDef = BlockDef(meta: [
            "view": .string("term"),
            "controller": .string("shell"),
        ])
        let blockId = try await commands.createBlock(
            tabId: tabId, blockDef: blockDef, rtOpts: RuntimeOpts(termsize: initialSize))

        // GUARDS §C: SetActiveTab is the trigger that starts the tab's block
        // controllers — issue it explicitly (the controller's mount also resyncs).
        try await commands.setActiveTab(workspaceId: workspace.oid, tabId: tabId)

        let sink = LockedCapturingSink()
        let controller = TerminalController(
            blockId: blockId, tabId: tabId, transport: transport, sink: sink, initialSize: initialSize)
        // GUARDS §T: mount() subscribes blockfile BEFORE the backfill GET. The view sizes
        // the terminal before mount replays the backfill, so resync uses the real width.
        controller.resize(initialSize)
        try await controller.mount()

        return TerminalE2EFixture(
            server: server, transport: transport, store: store, commands: commands,
            controller: controller, sink: sink, bridge: bridge,
            windowId: windowId, workspaceId: workspace.oid, tabId: tabId, blockId: blockId)
    }

    private static func bootstrapClient(transport: WaveTransportClient) async throws -> Client {
        let deadline = Date().addingTimeInterval(8)
        var lastError: Error?
        while Date() < deadline {
            do {
                let ret = try await transport.callService(
                    WebCallType(service: "client", method: "GetClientData", args: []))
                if let data = ret.data, !data.isNull {
                    let client = try data.decode(Client.self)
                    if !client.windowids.isEmpty { return client }
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw E2EError.bootstrap("GetClientData never returned a window (last error: \(String(describing: lastError)))")
    }

    func teardown() {
        controller.unmount()
        transport.disconnect()
        server.terminate()
    }

    // MARK: - Drive the shell

    /// Type a command line into the PTY (real input path: std-base64
    /// ControllerInputCommand, GUARDS §T).
    func send(_ line: String) {
        controller.sendText(line + "\n")
        controller.flushInput() // flush the coalescing buffer now so ordering vs. later RPCs is deterministic
    }

    /// Quiet the shell for clean captures. Echo-off + empty prompt; correctness
    /// does not depend on this succeeding because all captures are extracted
    /// between echo-proof markers (see `bracketed`).
    func quiet() async throws {
        send("stty -echo; PS1=''; PROMPT_COMMAND=''")
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Poll the sink

    /// Wait until `predicate(snapshot)` holds, polling the capturing sink. Throws
    /// on timeout (the harness never silently proceeds with partial output).
    @discardableResult
    func waitForSink(timeout: TimeInterval = 15, until predicate: (Data) -> Bool) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = sink.snapshot
            if predicate(snap) { return snap }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let snap = sink.snapshot
        if predicate(snap) { return snap }
        throw E2EError.timeout("sink predicate unmet in \(timeout)s (have \(snap.count) bytes)")
    }

    /// Wait until the sink's clear-count exceeds `previous` (a truncate arrived).
    func waitForClear(after previous: Int, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.clearCount > previous { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw E2EError.timeout("no truncate/clear observed in \(timeout)s")
    }
}

/// Mutable holder so the `uiContext` closure always reads the current active tab.
final class ActiveTabRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - Echo-proof markers + extraction

/// Markers split by an empty single-quote pair so the shell ECHO of the typed
/// command (`WV_STA''RT`) never contains the literal marker (`WV_START`) while the
/// command OUTPUT does — making capture immune to whether echo is on or off.
enum Marker {
    static func startSource(_ tag: String) -> String { "WV_STA''RT_\(tag)" }
    static func endSource(_ tag: String) -> String { "WV_EN''D_\(tag)" }
    static func startToken(_ tag: String) -> String { "WV_START_\(tag)" }
    static func endToken(_ tag: String) -> String { "WV_END_\(tag)" }

    /// Build a shell line that emits `<START><body output><END>` where `body` is a
    /// shell fragment (e.g. `printf %s hi` or `seq 1 100`).
    static func line(tag: String, body: String) -> String {
        "printf %s \(startSource(tag)); \(body); printf %s \(endSource(tag))"
    }
}

extension Data {
    /// Bytes strictly between the first `start` token and the first `end` token
    /// after it; nil if the pair is not yet present.
    func slice(between start: String, and end: String) -> Data? {
        let startData = Data(start.utf8)
        let endData = Data(end.utf8)
        guard let s = range(of: startData, in: startIndex..<endIndex) else { return nil }
        guard let e = range(of: endData, in: s.upperBound..<endIndex) else { return nil }
        return subdata(in: s.upperBound..<e.lowerBound)
    }

    /// Count of non-overlapping occurrences of `token`.
    func occurrences(of token: String) -> Int {
        let needle = Data(token.utf8)
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = startIndex
        while let r = range(of: needle, in: from..<endIndex) {
            count += 1
            from = r.upperBound
        }
        return count
    }
}

/// Parse a newline-separated run of integers (the counter payload used to prove
/// no-dup/no-drop across a >2 MB circular wrap).
func parseIntLines(_ data: Data) -> [Int] {
    // The pty translates "\n" to "\r\n" on output (ONLCR). Split on the raw CR/LF
    // BYTES rather than on Swift `Character`s: Swift coalesces "\r\n" into a single
    // extended-grapheme `Character` that equals neither "\r" nor "\n", so a
    // String-level split would never break CRLF-terminated lines apart.
    data
        .split(whereSeparator: { $0 == 0x0a || $0 == 0x0d })
        .compactMap { Int(String(decoding: $0, as: UTF8.self)) }
}
