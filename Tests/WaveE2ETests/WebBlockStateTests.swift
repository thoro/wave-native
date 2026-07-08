// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveWeb unit tests — encode PROTOCOL.md §5 + GUARDS §W at the type layer:
// the web block meta<->state mapping, URL-scheme normalization, zoom clamping,
// and `web:partition` → distinct WKWebsiteDataStore isolation. No live wavesrv.

import XCTest
import WebKit
import WaveCore
@testable import WaveWeb

final class WebBlockStateTests: XCTestCase {

    // MARK: PROTOCOL §5 — meta -> state mapping

    func testFullMetaMapsToState() {
        let meta: MetaMapType = [
            WebMetaKeys.view: .string("web"),
            WebMetaKeys.url: .string("https://example.com"),
            WebMetaKeys.pinnedUrl: .string("https://home.example"),
            WebMetaKeys.webZoom: .double(1.5),
            WebMetaKeys.webHideNav: .bool(true),
            WebMetaKeys.webPartition: .string("persist:work"),
            WebMetaKeys.webUserAgentType: .string("mobile:iphone"),
        ]
        let state = WebBlockState.from(meta: meta)
        XCTAssertEqual(state.url, "https://example.com")
        XCTAssertEqual(state.pinnedURL, "https://home.example")
        XCTAssertEqual(state.zoom, 1.5)
        XCTAssertTrue(state.hideNav)
        XCTAssertEqual(state.partition, "persist:work")
        XCTAssertEqual(state.userAgentType, "mobile:iphone")
        XCTAssertEqual(state.userAgentString, WebUserAgent.iPhone)
    }

    func testEmptyMetaDefaults() {
        let state = WebBlockState.from(meta: [:])
        XCTAssertNil(state.url)
        XCTAssertNil(state.pinnedURL)
        XCTAssertNil(state.zoom)
        XCTAssertFalse(state.hideNav)        // GUARDS §W: hidenav defaults false
        XCTAssertNil(state.partition)
        XCTAssertNil(state.userAgentType)
        XCTAssertNil(state.userAgentString)
    }

    func testEmptyStringsTreatedAsNil() {
        let meta: MetaMapType = [
            WebMetaKeys.url: .string(""),
            WebMetaKeys.webPartition: .string(""),
        ]
        let state = WebBlockState.from(meta: meta)
        XCTAssertNil(state.url)
        XCTAssertNil(state.partition)
    }

    func testEffectiveURLFallsBackToPinned() {
        XCTAssertEqual(
            WebBlockState(url: nil, pinnedURL: "https://home").effectiveURL,
            "https://home"
        )
        XCTAssertEqual(
            WebBlockState(url: "https://now", pinnedURL: "https://home").effectiveURL,
            "https://now"
        )
        XCTAssertNil(WebBlockState().effectiveURL)
    }

    func testZoomCoercesIntAndClamps() {
        // GUARDS: zoom stored as int 1 must read as 1.0.
        XCTAssertEqual(WebBlockState.from(meta: [WebMetaKeys.webZoom: .int(1)]).zoom, 1.0)
        // Clamp to [0.1, 5].
        XCTAssertEqual(WebBlockState.from(meta: [WebMetaKeys.webZoom: .double(99)]).zoom, 5.0)
        XCTAssertEqual(WebBlockState.from(meta: [WebMetaKeys.webZoom: .double(0.001)]).zoom, 0.1)
    }

    func testBlockMappingUsesMeta() {
        let block = Block(oid: "b1", version: 3, meta: [
            WebMetaKeys.view: .string("web"),
            WebMetaKeys.url: .string("https://wave.dev"),
        ])
        XCTAssertEqual(WebBlockState.from(block: block).url, "https://wave.dev")
        XCTAssertEqual(block.view, "web")
    }

    // MARK: URL-scheme normalization (`webview.tsx:ensureUrlScheme`)

    func testEnsureSchemePassesThroughExplicitSchemes() {
        XCTAssertEqual(WebURLNormalizer.ensureScheme("https://a.com"), "https://a.com")
        XCTAssertEqual(WebURLNormalizer.ensureScheme("http://a.com"), "http://a.com")
        XCTAssertEqual(WebURLNormalizer.ensureScheme("file:///etc/hosts"), "file:///etc/hosts")
    }

    func testEnsureSchemeLocalGetsHttp() {
        XCTAssertEqual(WebURLNormalizer.ensureScheme("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(WebURLNormalizer.ensureScheme("127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(WebURLNormalizer.ensureScheme("192.168.1.5"), "http://192.168.1.5")
    }

    func testEnsureSchemeDomainGetsHttps() {
        XCTAssertEqual(WebURLNormalizer.ensureScheme("example.com"), "https://example.com")
        XCTAssertEqual(WebURLNormalizer.ensureScheme("sub.example.com/path"), "https://sub.example.com/path")
    }

    func testEnsureSchemeFallsBackToSearch() {
        XCTAssertEqual(
            WebURLNormalizer.ensureScheme("hello world"),
            "https://www.google.com/search?q=hello%20world"
        )
        XCTAssertEqual(
            WebURLNormalizer.ensureScheme("cats", searchTemplate: "https://duckduckgo.com/?q={query}"),
            "https://duckduckgo.com/?q=cats"
        )
    }

    func testEnsureSchemeNilIsEmptySearch() {
        XCTAssertEqual(
            WebURLNormalizer.ensureScheme(nil),
            "https://www.google.com/search?q="
        )
    }

    // MARK: GUARDS §W — partition isolation

    func testPartitionStoreDistinctness() {
        let registry = WebPartitionStore()
        // nil/empty -> shared default, same instance.
        XCTAssertTrue(registry.dataStore(for: nil) === registry.dataStore(for: ""))
        XCTAssertTrue(registry.dataStore(for: nil) === WaveWebTestDefaults.defaultStore)

        // Same name -> same store; different names -> different stores.
        let a1 = registry.dataStore(for: "alpha")
        let a2 = registry.dataStore(for: "alpha")
        let b = registry.dataStore(for: "beta")
        XCTAssertTrue(a1 === a2)
        XCTAssertFalse(a1 === b)

        // Ephemeral named partitions are non-persistent + isolated.
        XCTAssertFalse(a1.isPersistent)
        XCTAssertFalse(a1 === registry.dataStore(for: nil))
    }

    func testStableIdentifierIsDeterministic() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("WKWebsiteDataStore(forIdentifier:) requires macOS 14")
        }
        let id1 = WebPartitionStore.stableIdentifier(for: "work")
        let id2 = WebPartitionStore.stableIdentifier(for: "work")
        let id3 = WebPartitionStore.stableIdentifier(for: "play")
        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        // Valid RFC 4122 v5 UUID (version nibble == 5).
        XCTAssertEqual((id1.uuid.6 & 0xF0) >> 4, 5)
    }

    // GUARDS §W cleanup — only `persist:` partitions have on-disk data; removing a
    // nil/empty/bare partition is a safe no-op and must not touch the shared default.
    func testRemoveDataStoreNoOpForNonPersistent() {
        let registry = WebPartitionStore()
        registry.removeDataStore(for: nil)
        registry.removeDataStore(for: "")
        registry.removeDataStore(for: "ephemeral")
        XCTAssertTrue(registry.dataStore(for: nil) === WaveWebTestDefaults.defaultStore)
    }

    // The cleanup decision: only `persist:NAME` partitions have an on-disk store to
    // remove, and the removed identifier matches the one the partition was created with.
    func testRemovableIdentifierMatchesCreation() {
        XCTAssertNil(WebPartitionStore.removableIdentifier(for: nil))
        XCTAssertNil(WebPartitionStore.removableIdentifier(for: ""))
        XCTAssertNil(WebPartitionStore.removableIdentifier(for: "ephemeral"))
        XCTAssertEqual(
            WebPartitionStore.removableIdentifier(for: "persist:work"),
            WebPartitionStore.stableIdentifier(for: "work"))
    }
}

private enum WaveWebTestDefaults {
    static var defaultStore: WKWebsiteDataStore { .default() }
}
