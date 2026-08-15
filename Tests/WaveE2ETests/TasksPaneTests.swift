// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tasks pane unit tests — the pure pieces of the workspace task list:
//   • @-mention tokenization: fragment detection, token→link splitting at commit
//   • pane mention labels (`display:name` > `frame:title` > "view · tab")
//   • WaveTask wire decode (lowercase JSON, optional fields)
//   • the tasks widget is offered by the launcher (parseWidgets + implemented set)
// These run without a live wavesrv.

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveUI

@MainActor
final class TasksPaneTests: XCTestCase {

    // MARK: mention fragment

    func testMentionFragmentDetection() {
        XCTAssertNil(TasksPaneView.mentionFragment("no mention here"))
        XCTAssertEqual(TasksPaneView.mentionFragment("fix @"), "")
        XCTAssertEqual(TasksPaneView.mentionFragment("fix @bui"), "bui")
        XCTAssertEqual(TasksPaneView.mentionFragment("fix @Tab 1"), "Tab 1")
        // The LAST @ opens the fragment.
        XCTAssertEqual(TasksPaneView.mentionFragment("a @first done @sec"), "sec")
    }

    // MARK: splitMentions

    func testSplitMentionsStripsTokensAndBuildsLinks() {
        let pending = [
            "build": WaveTaskLink(tabid: "t1", blockid: "b1", label: "build"),
            "Tab 2": WaveTaskLink(tabid: "t2", blockid: nil, label: "Tab 2"),
        ]
        let (text, links) = TasksPaneView.splitMentions(
            raw: "deploy @build then check @Tab 2 logs", pending: pending)
        XCTAssertEqual(text, "deploy then check logs")
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.contains(WaveTaskLink(tabid: "t1", blockid: "b1", label: "build")))
        XCTAssertTrue(links.contains(WaveTaskLink(tabid: "t2", blockid: nil, label: "Tab 2")))
    }

    func testSplitMentionsIgnoresDeletedTokens() {
        // The user picked a mention but then erased its token from the field.
        let pending = ["build": WaveTaskLink(tabid: "t1", blockid: "b1", label: "build")]
        let (text, links) = TasksPaneView.splitMentions(raw: "plain task", pending: pending)
        XCTAssertEqual(text, "plain task")
        XCTAssertTrue(links.isEmpty)
    }

    func testSplitMentionsLongestLabelWins() {
        // "@build (2)" must not be half-consumed by the shorter "@build".
        let pending = [
            "build": WaveTaskLink(tabid: "t1", blockid: "b1", label: "build"),
            "build (2)": WaveTaskLink(tabid: "t1", blockid: "b2", label: "build (2)"),
        ]
        let (text, links) = TasksPaneView.splitMentions(raw: "check @build (2)", pending: pending)
        XCTAssertEqual(text, "check")
        XCTAssertEqual(links, [WaveTaskLink(tabid: "t1", blockid: "b2", label: "build (2)")])
    }

    func testSplitMentionsMentionOnlyTaskKeepsRawText() {
        // A task that is ONLY a mention must not end up with empty text (the
        // backend rejects empty).
        let pending = ["build": WaveTaskLink(tabid: "t1", blockid: "b1", label: "build")]
        let (text, links) = TasksPaneView.splitMentions(raw: "@build", pending: pending)
        XCTAssertEqual(text, "@build")
        XCTAssertEqual(links.count, 1)
    }

    // MARK: edit round-trip

    func testEditEntryRoundTripsThroughSplitMentions() {
        let links = [
            WaveTaskLink(tabid: "t1", blockid: "b1", label: "old label"),
            WaveTaskLink(tabid: "t2", blockid: nil, label: "build"),
            WaveTaskLink(tabid: "t3", blockid: nil, label: "build"),
        ]
        // Titles resolve to the CURRENT names; two collide and must be uniqued.
        let titles = ["b1": "api server", "t2": "build", "t3": "build"]
        let entry = TasksPaneView.editEntry(text: "ship it", links: links) {
            titles[$0.blockid ?? $0.tabid ?? ""] ?? "?"
        }
        XCTAssertEqual(entry.entry, "ship it @api server @build @build (2)")
        let (text, outLinks) = TasksPaneView.splitMentions(raw: entry.entry, pending: entry.pending)
        XCTAssertEqual(text, "ship it")
        XCTAssertEqual(outLinks.count, 3)
        XCTAssertTrue(outLinks.contains(WaveTaskLink(tabid: "t1", blockid: "b1", label: "api server")))
        XCTAssertTrue(outLinks.contains(WaveTaskLink(tabid: "t2", blockid: nil, label: "build")))
        XCTAssertTrue(outLinks.contains(WaveTaskLink(tabid: "t3", blockid: nil, label: "build (2)")))
    }

    func testEditEntryNoLinks() {
        let entry = TasksPaneView.editEntry(text: "plain", links: []) { _ in "?" }
        XCTAssertEqual(entry.entry, "plain")
        XCTAssertTrue(entry.pending.isEmpty)
        // Deleting the last token while editing must clear the links on save.
        let (text, links) = TasksPaneView.splitMentions(raw: entry.entry, pending: entry.pending)
        XCTAssertEqual(text, "plain")
        XCTAssertTrue(links.isEmpty)
    }

    // MARK: global-mode workspace stage

    func testSplitWorkspacePrefix() {
        let labels = ["dev", "ops/infra", "dev (2)"]
        let hit = TasksPaneView.splitWorkspacePrefix(fragment: "dev/bui", workspaceLabels: labels)
        XCTAssertEqual(hit?.label, "dev")
        XCTAssertEqual(hit?.rest, "bui")
        // A workspace label that itself contains "/" still resolves greedily.
        let slashed = TasksPaneView.splitWorkspacePrefix(fragment: "ops/infra/Tab 1", workspaceLabels: labels)
        XCTAssertEqual(slashed?.label, "ops/infra")
        XCTAssertEqual(slashed?.rest, "Tab 1")
        // No "/" yet → still in the workspace-picking stage.
        XCTAssertNil(TasksPaneView.splitWorkspacePrefix(fragment: "dev", workspaceLabels: labels))
        XCTAssertNil(TasksPaneView.splitWorkspacePrefix(fragment: "unknown/x", workspaceLabels: labels))
    }

    func testSplitMentionsWithWorkspacePrefixedLabel() {
        // Global-mode tokens look like "@Ws/Tab" — the "/" must survive the round trip.
        let pending = ["dev/build": WaveTaskLink(tabid: "t1", blockid: nil, label: "dev/build")]
        let (text, links) = TasksPaneView.splitMentions(raw: "check @dev/build logs", pending: pending)
        XCTAssertEqual(text, "check logs")
        XCTAssertEqual(links, [WaveTaskLink(tabid: "t1", blockid: nil, label: "dev/build")])
    }

    // MARK: pane labels

    func testPaneLabelPrecedence() {
        func block(_ meta: MetaMapType) -> Block {
            Block(oid: "b", version: 1, meta: meta)
        }
        XCTAssertEqual(
            TasksPaneView.paneLabel(block: block(["view": .string("term"), "display:name": .string("api server")]),
                                    tabName: "Tab 1"),
            "api server")
        XCTAssertEqual(
            TasksPaneView.paneLabel(block: block(["view": .string("term"), "frame:title": .string("logs")]),
                                    tabName: "Tab 1"),
            "logs")
        XCTAssertEqual(
            TasksPaneView.paneLabel(block: block(["view": .string("term")]), tabName: "Tab 1"),
            "term · Tab 1")
        XCTAssertEqual(
            TasksPaneView.paneLabel(block: block([:]), tabName: nil),
            "pane")
    }

    // MARK: wire decode

    func testWaveTaskDecodesWireShape() throws {
        let json = """
        {"oid":"task-1","workspaceid":"ws-1","text":"ship it","done":true,
         "createdts":1755000000000,"donets":1755000100000,
         "links":[{"tabid":"t1","blockid":"b1","label":"build"}],"meta":{}}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WaveTask.self, from: json)
        XCTAssertEqual(task.oid, "task-1")
        XCTAssertEqual(task.workspaceid, "ws-1")
        XCTAssertTrue(task.isDone)
        XCTAssertEqual(task.links?.first?.label, "build")
        XCTAssertEqual(task.donets, 1_755_000_100_000)
    }

    func testWaveTaskMinimalDecode() throws {
        let json = #"{"oid":"task-2","workspaceid":"ws-1","text":"open task"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(WaveTask.self, from: json)
        XCTAssertFalse(task.isDone)
        XCTAssertNil(task.links)
    }

    // MARK: widget launcher

    func testTasksWidgetOfferedByLauncher() throws {
        XCTAssertTrue(AppCoordinator.implementedWidgetViews.contains("tasks"))
        let config: JSONValue = .object([
            "widgets": .object([
                "defwidget@tasks": .object([
                    "display:order": .int(0),
                    "icon": .string("list-check"),
                    "label": .string("tasks"),
                    "blockdef": .object(["meta": .object(["view": .string("tasks")])]),
                ]),
            ]),
        ])
        let items = AppCoordinator.parseWidgets(config)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.blockDefMeta["view"]?.stringValue, "tasks")
        // The launcher icon maps to a real SF Symbol (not the generic fallback).
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "list-check"), "checklist")
    }
}
