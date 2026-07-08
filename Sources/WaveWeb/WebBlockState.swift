// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveWeb — implements PROTOCOL.md §5 ("Web block") and encodes GUARDS §W.
//
// This file is the PURE meta<->state mapping: it depends only on Foundation +
// WaveCore so it is unit-testable without WebKit/AppKit. The WKWebView plumbing
// lives in WebPartitionStore.swift / WebBlockModel.swift / WebBlockView.swift.
//
// Meta keys are the source-of-truth constants from `pkg/waveobj/metaconsts.go`:
//   view  :9 · url :15 · pinnedurl :17 · web:zoom :133 · web:hidenav :134 ·
//   web:partition :135 · web:useragenttype :136
// The view reads exactly these keys (`frontend/app/view/webview/webview.tsx`
// :91,104,107,114,855-857). On navigate it persists `url` via wshrpc `setmeta`
// (`webview.tsx:382-386`, command "setmeta" `wshclient.go:857-859`).

import Foundation
import WaveCore

// MARK: - Meta keys (`pkg/waveobj/metaconsts.go`)

public enum WebMetaKeys {
    public static let view = "view"
    public static let url = "url"
    public static let pinnedUrl = "pinnedurl"
    public static let webZoom = "web:zoom"
    public static let webHideNav = "web:hidenav"
    public static let webPartition = "web:partition"
    public static let webUserAgentType = "web:useragenttype"
}

/// View type constant for a web block (`meta["view"] == "web"`, PROTOCOL.md §5).
public enum WebBlockConst {
    public static let viewType = "web"

    /// wshrpc command string for persisting meta (`wshclient.go:857-859`).
    public static let setMetaCommand = "setmeta"

    /// Zoom clamps mirroring `webview.tsx:setZoomFactor` (590-607).
    public static let minZoom: Double = 0.1
    public static let maxZoom: Double = 5.0
}

/// User-agent strings for mobile emulation (`webview.tsx:29-32`).
public enum WebUserAgent {
    public static let typeDefault = "default"
    public static let typeIPhone = "mobile:iphone"
    public static let typeAndroid = "mobile:android"

    public static let iPhone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    public static let android =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/120.0.6099.43 Mobile Safari/537.36"

    /// Appended (via `applicationNameForUserAgent`) to WKWebView's DEFAULT UA, which
    /// otherwise omits the "Version/.. Safari/.." token — without it sites like Google
    /// serve a degraded/legacy layout. This keeps the real OS/WebKit version and only
    /// adds the Safari marker so the default reads as desktop Safari.
    public static let desktopAppName = "Version/17.4.1 Safari/605.1.15"

    /// Map a `web:useragenttype` value to a concrete UA string (nil = default UA).
    public static func string(for type: String?) -> String? {
        switch type {
        case typeIPhone: return iPhone
        case typeAndroid: return android
        default: return nil
        }
    }
}

// MARK: - WebBlockState (the meta<->state mapping)

/// The web view's state, derived purely from a block's `meta`. This is the
/// canonical mapping unit-tested in `WebBlockStateTests`.
public struct WebBlockState: Equatable, Sendable {
    /// The last-navigated URL (`meta["url"]`).
    public var url: String?
    /// The block homepage (`meta["pinnedurl"]`); used when `url` is absent.
    public var pinnedURL: String?
    /// Page zoom factor (`meta["web:zoom"]`); nil = default 1.0.
    public var zoom: Double?
    /// Whether the navigation chrome is hidden (`meta["web:hidenav"]`).
    public var hideNav: Bool
    /// Per-block session partition (`meta["web:partition"]`) → WKWebsiteDataStore.
    public var partition: String?
    /// `meta["web:useragenttype"]` (e.g. "mobile:iphone").
    public var userAgentType: String?

    public init(
        url: String? = nil,
        pinnedURL: String? = nil,
        zoom: Double? = nil,
        hideNav: Bool = false,
        partition: String? = nil,
        userAgentType: String? = nil
    ) {
        self.url = url
        self.pinnedURL = pinnedURL
        self.zoom = zoom
        self.hideNav = hideNav
        self.partition = partition
        self.userAgentType = userAgentType
    }

    /// Derive the state from a meta map.
    public static func from(meta: MetaMapType) -> WebBlockState {
        WebBlockState(
            url: nonEmpty(meta[WebMetaKeys.url]?.stringValue),
            pinnedURL: nonEmpty(meta[WebMetaKeys.pinnedUrl]?.stringValue),
            zoom: clampZoom(meta[WebMetaKeys.webZoom]?.doubleValue),
            hideNav: meta[WebMetaKeys.webHideNav]?.boolValue ?? false,
            partition: nonEmpty(meta[WebMetaKeys.webPartition]?.stringValue),
            userAgentType: nonEmpty(meta[WebMetaKeys.webUserAgentType]?.stringValue)
        )
    }

    /// Derive the state from a block (PROTOCOL.md §5: a web block is just a Block
    /// whose `meta["view"] == "web"`).
    public static func from(block: Block) -> WebBlockState {
        from(meta: block.meta)
    }

    /// The URL the view should load: the navigated `url`, falling back to the
    /// pinned homepage (`webview.tsx:120`, `homepageUrl` 89-93).
    public var effectiveURL: String? {
        if let url, !url.isEmpty { return url }
        return pinnedURL
    }

    /// The concrete user-agent string for `userAgentType` (nil = default UA).
    public var userAgentString: String? {
        WebUserAgent.string(for: userAgentType)
    }

    // MARK: Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Clamp to [minZoom, maxZoom] like `webview.tsx:setZoomFactor`.
    static func clampZoom(_ z: Double?) -> Double? {
        guard let z else { return nil }
        return Swift.min(Swift.max(z, WebBlockConst.minZoom), WebBlockConst.maxZoom)
    }
}

// MARK: - URL scheme normalization (`webview.tsx:ensureUrlScheme` 393-425)

public enum WebURLNormalizer {
    /// Port of `WebViewModel.ensureUrlScheme`. Pure + testable.
    /// - If the input already has an http/https/file scheme, return as-is.
    /// - localhost / dotted-quad → prefix `http://`.
    /// - a bare domain (`foo.com`) → prefix `https://`.
    /// - otherwise treat as a search query against `searchTemplate`
    ///   (default Google, `webview.tsx:421-424`).
    public static func ensureScheme(_ rawURL: String?, searchTemplate: String? = nil) -> String {
        let url = rawURL ?? ""

        if hasScheme(url) {
            return url
        }

        let firstSegment = url.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? url

        if isLocalHost(firstSegment) {
            return "http://\(url)"
        }
        if isDomain(firstSegment) {
            return "https://\(url)"
        }

        let query = url.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? url
        if let template = searchTemplate, template.contains("{query}") {
            return template.replacingOccurrences(of: "{query}", with: query)
        }
        return "https://www.google.com/search?q=\(query)"
    }

    /// `/^(http|https|file):/`
    private static func hasScheme(_ s: String) -> Bool {
        s.hasPrefix("http:") || s.hasPrefix("https:") || s.hasPrefix("file:")
    }

    /// `/^(localhost|(\d{1,3}\.){3}\d{1,3})(:\d+)?$/`
    private static func isLocalHost(_ segment: String) -> Bool {
        let host = segment.split(separator: ":", maxSplits: 1).first.map(String.init) ?? segment
        if host == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 999) <= 255
        }
    }

    /// `/^[a-z0-9.-]+\.[a-z]{2,}$/i`
    private static func isDomain(_ segment: String) -> Bool {
        guard let dotIdx = segment.lastIndex(of: "."), dotIdx != segment.startIndex else { return false }
        let tld = segment[segment.index(after: dotIdx)...]
        guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        let body = segment[..<dotIdx]
        guard !body.isEmpty else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

private extension CharacterSet {
    /// `encodeURIComponent`-equivalent allowed set (everything else percent-encoded).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()
}
