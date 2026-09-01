// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WorkspaceMenuItem.recencyOrder — the switcher surfaces' display order:
// most-recently-focused first, never-focused trailing in name order. Pure.

import XCTest
@testable import WaveUI

final class WorkspaceOrderTests: XCTestCase {
    private func item(_ id: String, _ name: String) -> WorkspaceMenuItem {
        WorkspaceMenuItem(workspaceId: id, name: name, icon: nil, color: nil)
    }

    func testRecentFirstThenNameOrder() {
        let items = [item("a", "Alpha"), item("b", "Zulu"), item("c", "Mike"), item("d", "Bravo")]
        let stamps = ["b": 200.0, "c": 300.0]
        let ordered = WorkspaceMenuItem.recencyOrder(items, stamps: stamps)
        XCTAssertEqual(ordered.map { $0.workspaceId }, ["c", "b", "a", "d"])
    }

    func testNoStampsFallsBackToNameOrder() {
        let items = [item("a", "zeta"), item("b", "Alpha")]
        let ordered = WorkspaceMenuItem.recencyOrder(items, stamps: [:])
        XCTAssertEqual(ordered.map { $0.workspaceId }, ["b", "a"])
    }

    func testEqualStampsTieBreakByName() {
        let items = [item("a", "beta"), item("b", "alpha")]
        let ordered = WorkspaceMenuItem.recencyOrder(items, stamps: ["a": 100, "b": 100])
        XCTAssertEqual(ordered.map { $0.workspaceId }, ["b", "a"])
    }
}
