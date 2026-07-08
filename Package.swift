// swift-tools-version:5.9
// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Wave Native — SwiftPM package for the native macOS (AppKit) Wave client.
//
// Target graph (per docs/PROTOCOL.md "Module map"):
//
//   CGhostty (systemLibrary, libghostty — see Sources/CGhostty/module.modulemap)
//        ^
//   WaveCore  ──────────────────────────────── shared model + wire types + protocols
//        ^                                       (WaveTransport, ObjectStoreProtocol)
//   WaveProtocol  -> Core                        §1 transport/handshake
//   WaveStore     -> Protocol, Core              §2 object store
//   WaveCommands  -> Store                        §3 lifecycle RPC wrappers
//   WaveTerminal  -> Protocol, Store, CGhostty    §4 terminal + libghostty
//   WaveLayout    -> Store                        §6 tiling
//   WaveWeb       -> Store                        §5 WKWebView block
//   WaveUI        -> all + Core                   §7 AppKit chrome + Theme.swift
//   WaveApp (exe) -> UI                           entry point / init sequence
//   WaveE2ETests  -> all                          e2e + GUARDS unit tests
//
// BUILD-ON-MAC: this package targets macOS 14 / Swift 5.9 / AppKit and will not
// build on Linux.

import PackageDescription

let package = Package(
    name: "WaveNative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "WaveApp", targets: ["WaveApp"]),
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .library(name: "WaveProtocol", targets: ["WaveProtocol"]),
        .library(name: "WaveStore", targets: ["WaveStore"]),
        .library(name: "WaveCommands", targets: ["WaveCommands"]),
        .library(name: "WaveTerminal", targets: ["WaveTerminal"]),
        .library(name: "WaveLayout", targets: ["WaveLayout"]),
        .library(name: "WaveWeb", targets: ["WaveWeb"]),
        .library(name: "WaveUI", targets: ["WaveUI"]),
    ],
    targets: [
        // MARK: MAC-LINK — libghostty embeddable C library.
        // Placeholder system-library target. See Sources/CGhostty/module.modulemap
        // and Sources/CGhostty/ghostty_shim.h for how to point this at Ghostty's
        // `zig build lib` output (ghostty.h + libghostty.{a,dylib}) on the Mac.
        .systemLibrary(
            name: "CGhostty",
            path: "Sources/CGhostty"
        ),

        // Shared contract: model + wire types + cross-module protocols.
        .target(
            name: "WaveCore",
            path: "Sources/WaveCore"
        ),

        // §1 — RpcMessage codec, asym WS framer, HTTP service client, auth,
        // ping/pong, reconnect + re-announce. Conforms to WaveTransport.
        .target(
            name: "WaveProtocol",
            dependencies: ["WaveCore"],
            path: "Sources/WaveProtocol"
        ),

        // §2 — oref-keyed object cache, version-guarded merge, inline updates.
        // Conforms to ObjectStoreProtocol.
        .target(
            name: "WaveStore",
            dependencies: ["WaveProtocol", "WaveCore"],
            path: "Sources/WaveStore"
        ),

        // §3 — typed window/workspace/tab/block RPC wrappers.
        .target(
            name: "WaveCommands",
            dependencies: ["WaveStore"],
            path: "Sources/WaveCommands"
        ),

        // §4 — terminal controller resync/backfill/reconcile + libghostty I/O.
        .target(
            name: "WaveTerminal",
            dependencies: ["WaveProtocol", "WaveStore", "CGhostty"],
            path: "Sources/WaveTerminal"
        ),

        // §6 — layout node tree, reducer, persist, pendingbackendactions.
        .target(
            name: "WaveLayout",
            dependencies: ["WaveStore"],
            path: "Sources/WaveLayout"
        ),

        // §5 — WKWebView <-> block meta.
        .target(
            name: "WaveWeb",
            dependencies: ["WaveStore"],
            path: "Sources/WaveWeb"
        ),

        // §7 — AppKit chrome + visual theme (Theme.swift). Depends on everything.
        .target(
            name: "WaveUI",
            dependencies: [
                "WaveCore", "WaveProtocol", "WaveStore", "WaveCommands",
                "WaveTerminal", "WaveLayout", "WaveWeb",
            ],
            path: "Sources/WaveUI"
        ),

        // Executable entry point / init sequence. Depends on the concrete
        // transport (WaveProtocol) + store (WaveStore) + the web content view
        // (WaveWeb) so this composition root can construct the real objects and a
        // real BlockViewProvider, then hand them to WaveUI's `runWaveApp`.
        .executableTarget(
            name: "WaveApp",
            dependencies: ["WaveUI", "WaveCore", "WaveProtocol", "WaveStore", "WaveWeb", "WaveTerminal"],
            path: "Sources/WaveApp"
        ),

        // e2e harness + GUARDS unit tests. Depends on all targets.
        .testTarget(
            name: "WaveE2ETests",
            dependencies: [
                "WaveCore", "WaveProtocol", "WaveStore", "WaveCommands",
                "WaveTerminal", "WaveLayout", "WaveWeb", "WaveUI",
            ],
            path: "Tests/WaveE2ETests"
        ),
    ]
)
