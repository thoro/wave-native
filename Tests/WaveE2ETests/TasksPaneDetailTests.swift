// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tasks pane detail-panel interaction tests: the slide-over must NOT be
// click-through — clicking anywhere on the open detail (text, background)
// must never reach the task rows underneath it.

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveUI

@MainActor
final class TasksPaneDetailTests: XCTestCase {

    final class TasksTransport: FakeTransport, @unchecked Sendable {
        override func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
            command: String, data: Req?, route: String?, timeoutMs: Int64?
        ) async throws -> Res {
            if command == "tasklist" {
                let tasks: JSONValue = .array([
                    .object(["oid": .string("t1"), "workspaceid": .string("ws-1"),
                             "text": .string("first task with a fairly long description text here")]),
                    .object(["oid": .string("t2"), "workspaceid": .string("ws-1"),
                             "text": .string("second task also with quite a lot of text")]),
                    .object(["oid": .string("t3"), "workspaceid": .string("ws-1"),
                             "text": .string("third task short")]),
                ])
                return try tasks.decode(Res.self)
            }
            return try await super.call(command: command, data: data, route: route, timeoutMs: timeoutMs)
        }
    }

    private var window: NSWindow!
    private var pane: TasksPaneView!
    private var transport: TasksTransport!

    override func setUp() async throws {
        let store = FakeStore()
        store.preload(.block(Block(oid: "blk-1", version: 1, meta: ["view": .string("tasks")])))
        transport = TasksTransport()
        let env = BlockEnv(
            transport: transport, store: store,
            blockRef: ORef.block("blk-1"), tabId: "tab-1", windowId: "win-1",
            workspaceId: "ws-1")
        pane = TasksPaneView(env: env)
        pane.frame = CGRect(x: 0, y: 0, width: 560, height: 700)
        window = NSWindow(contentRect: pane.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()

        var loaded = false
        for _ in 0..<150 {
            if taskRows().count == 3 { loaded = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try XCTSkipUnless(loaded, "tasks never rendered")
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        pane = nil
        transport = nil
    }

    private func spinUntil(timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    private func descendants(of root: NSView) -> [NSView] {
        return root.subviews + root.subviews.flatMap { descendants(of: $0) }
    }

    private func taskRows() -> [NSView] {
        return descendants(of: pane).filter { String(describing: type(of: $0)) == "TaskRowView" }
    }

    private func detailPanel() -> TaskDetailPanel? {
        return descendants(of: pane).compactMap { $0 as? TaskDetailPanel }.first
    }

    private func clickView(_ target: NSView) throws {
        let center = NSPoint(x: target.bounds.midX, y: target.bounds.midY)
        let inWindow = target.convert(center, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        target.mouseDown(with: event)
    }

    private func hitChain(atWindowPoint p: NSPoint) -> [NSView] {
        var chain: [NSView] = []
        var v = window.contentView?.hitTest(p)
        while let cur = v { chain.append(cur); v = cur.superview }
        return chain
    }

    /// AppKit re-routes a mouseDown that bubbles up unhandled to the views
    /// visually behind the panel — before the panel swallowed its gestures, a
    /// click on the flyout's chrome "selected" the task row underneath it.
    func testClickOnDetailChromeDoesNotSelectRowBehind() throws {
        let rows = taskRows()
        try clickView(rows[0])
        let panel = try XCTUnwrap(detailPanel())
        pane.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Task" })
        try clickView(title)
        try clickView(panel)
        _ = spinUntil(timeout: 0.3) { false }

        let shown = descendants(of: panel).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("first task") || $0.stringValue.hasPrefix("second task")
                || $0.stringValue.hasPrefix("third task") }
        XCTAssertEqual(shown?.stringValue.hasPrefix("first task"), true,
                       "clicking the open detail switched the selection: now showing \(shown?.stringValue ?? "nil")")
    }

    func testInlineEditCommitsTaskUpdate() throws {
        let rows = taskRows()
        try clickView(rows[0])
        let panel = try XCTUnwrap(detailPanel())
        pane.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("first task") })
        XCTAssertTrue(field.isEditable, "detail text must be editable in place")
        XCTAssertTrue(window.makeFirstResponder(field), "field must accept first responder")
        field.currentEditor()?.string = "first task, edited inline"
        window.makeFirstResponder(nil)

        let committed = spinUntil(timeout: 2) {
            self.transport.recordedGeneric().contains { $0.command == "taskupdate" }
        }
        XCTAssertTrue(committed, "ending the inline edit must issue a taskupdate")
        let call = try XCTUnwrap(transport.recordedGeneric().first { $0.command == "taskupdate" })
        guard case .object(let fields)? = call.data else { return XCTFail("taskupdate payload missing") }
        XCTAssertEqual(fields["taskid"], .string("t1"))
        XCTAssertEqual(fields["text"], .string("first task, edited inline"))
    }

    func testOpenDetailBlocksClicksToRows() throws {
        let rows = taskRows()
        try clickView(rows[0])
        _ = spinUntil(timeout: 1) { self.detailPanel().map { $0.frame.maxX <= self.pane.bounds.maxX } ?? false }
        let panel = try XCTUnwrap(detailPanel())
        pane.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(panel.frame.maxX, pane.bounds.width, "detail panel should be slid in")

        // Probe a grid of points across the visible panel; every hit must stay
        // inside the panel subtree — the rows behind must be unreachable.
        for fx in stride(from: 0.1, through: 0.9, by: 0.2) {
            for fy in stride(from: 0.05, through: 0.95, by: 0.15) {
                let local = NSPoint(x: panel.bounds.minX + panel.bounds.width * fx,
                                    y: panel.bounds.minY + panel.bounds.height * fy)
                let inWindow = panel.convert(local, to: nil)
                let chain = hitChain(atWindowPoint: inWindow)
                let names = chain.map { String(describing: type(of: $0)) }
                let insidePanel = chain.contains { $0 === panel }
                XCTAssertTrue(insidePanel,
                              "hit at panel fraction (\(fx),\(fy)) escaped the panel: \(names)")
                XCTAssertFalse(names.contains("TaskRowView"),
                               "hit at panel fraction (\(fx),\(fy)) reached a task row: \(names)")
            }
        }
    }
}
