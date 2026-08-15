// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Rename Pane end-to-end: `setmeta display:name` on a real wavesrv must persist
// AND come back through the WPS `waveobj:update` subscription so the block
// header re-renders with the new name (the exact path BlockFrameView.bindStore
// uses). Regression guard for MergeMeta's mergeSpecial flag: with
// mergeSpecial=false the server silently DROPS `display:*` keys while still
// bumping the version, so the rename looked accepted but never stuck.

import XCTest
@testable import WaveCore
@testable import WaveStore
@testable import WaveUI

private final class NameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.lock(); entries.append(value); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class RenamePaneE2ETests: XCTestCase {

    private func waitFor(_ seconds: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testDisplayNameSetMetaRoundTripsToStoreSubscription() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 24, cols: 80))
        defer { fx.teardown() }

        let oref = ORef(otype: "block", oid: fx.blockId)
        _ = try await fx.store.load(oref)

        let log = NameLog()
        let token = fx.store.subscribe(oref) { obj in
            guard let meta = obj?.asBlock?.meta else { return }
            log.append(meta["display:name"]?.stringValue ?? "-")
        }
        defer { token.cancel() }

        let client = ServiceClient(transport: fx.transport, store: fx.store)
        try await client.setMeta(oref: oref, meta: ["display:name": .string("e2e pane name")])

        try await waitFor { log.all().contains("e2e pane name") }
        XCTAssertTrue(log.all().contains("e2e pane name"),
                      "waveobj:update with the new display:name never reached the store subscription; saw: \(log.all())")

        // Clearing the override (empty rename commit sends .null) must round-trip too.
        try await client.setMeta(oref: oref, meta: ["display:name": .null])
        try await waitFor { log.all().last == "-" }
        XCTAssertEqual(log.all().last, "-",
                       "clearing display:name never reached the store subscription; saw: \(log.all())")
    }
}
