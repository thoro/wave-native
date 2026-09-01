// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// DeepLink parse tests — the resource-URL contract (`wave-native://<otype>/<oid>`):
// exactly the three navigable resource kinds, id as the single path component,
// nothing action-shaped. No live wavesrv.

import XCTest
@testable import WaveUI

final class DeepLinkTests: XCTestCase {
    private func parse(_ s: String) -> DeepLink? {
        guard let url = URL(string: s) else { return nil }
        return DeepLink.parse(url)
    }

    func testParsesResourceKinds() {
        XCTAssertEqual(parse("wave-native://block/0d3adb-11"), .block("0d3adb-11"))
        XCTAssertEqual(parse("wave-native://tab/t-1"), .tab("t-1"))
        XCTAssertEqual(parse("wave-native://workspace/ws-9"), .workspace("ws-9"))
    }

    func testSchemeAndKindAreCaseInsensitive() {
        XCTAssertEqual(parse("WAVE-NATIVE://Block/abc"), .block("abc"))
    }

    func testTrailingSlashTolerated() {
        XCTAssertEqual(parse("wave-native://tab/t-1/"), .tab("t-1"))
    }

    func testRejectsWrongScheme() {
        XCTAssertNil(parse("https://block/abc"))
        XCTAssertNil(parse("wave://block/abc"))
    }

    func testRejectsUnknownOrActionShapedKinds() {
        XCTAssertNil(parse("wave-native://focus/abc"))
        XCTAssertNil(parse("wave-native://window/abc"))
        XCTAssertNil(parse("wave-native://job/abc"))
    }

    func testRejectsMissingOrNestedId() {
        XCTAssertNil(parse("wave-native://block"))
        XCTAssertNil(parse("wave-native://block/"))
        XCTAssertNil(parse("wave-native://block/abc/def"))
    }

    func testURLStringRoundTrips() {
        for link: DeepLink in [.block("b-1"), .tab("t-2"), .workspace("ws-3")] {
            XCTAssertEqual(parse(link.urlString), link)
        }
    }

    // MARK: firstDeepLink — pasted-URL detection in the tasks quick-add field

    func testFirstDeepLinkFindsURLMidText() {
        let text = "check logs wave-native://block/abc-1 tomorrow"
        let hit = TasksPaneView.firstDeepLink(in: text)
        XCTAssertEqual(hit?.link, .block("abc-1"))
        XCTAssertEqual(hit.map { String(text[$0.range]) }, "wave-native://block/abc-1")
    }

    func testFirstDeepLinkSkipsMalformedThenFindsValid() {
        let text = "wave-native://focus/x wave-native://tab/t-9"
        XCTAssertEqual(TasksPaneView.firstDeepLink(in: text)?.link, .tab("t-9"))
    }

    func testFirstDeepLinkNilWithoutURL() {
        XCTAssertNil(TasksPaneView.firstDeepLink(in: "plain task text @mention"))
        XCTAssertNil(TasksPaneView.firstDeepLink(in: ""))
    }
}
