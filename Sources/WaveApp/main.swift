// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveApp — the executable entry point and composition root. It constructs the
// concrete transport (WaveProtocol) + object store (WaveStore) + a real
// BlockViewProvider, then hands them to WaveUI's `runWaveApp`, which stands up
// the AppKit application and drives the full PROTOCOL.md §7 init sequence
// (spawn wavesrv -> GetClientData -> connect ws -> announce -> subscribe -> load
// the object chain -> ready).
//
// Top-level code in `main.swift` runs on the main actor (SE-0343), so calling the
// `@MainActor`-isolated `runWaveApp` here is valid.
//
// libghostty (Stage 0): the terminal content view (GhosttySink) needs a real
// `ghostty_surface_t`, which only exists once libghostty is linked (see
// Sources/CGhostty + docs/INTEGRATION.md). Until then `ComposedBlockViewProvider`
// renders web blocks for real and falls back to the placeholder for terminals.

import Foundation
import CoreText
import WaveCore
import WaveProtocol
import WaveStore
import WaveUI

// Register the bundled Inter + Hack fonts so `NSFont(name:)` resolves them (Wave's
// default terminal font is "Hack", and the chrome uses "Inter"). Without this the
// app falls back to the system font, which both looks wrong and breaks the STYLE
// snapshot baselines. Resolves the font dir from the .app Resources, an explicit
// WAVE_NATIVE_FONTS override, or the dev-tree `Fonts/` (cwd / next to the binary).
func registerBundledFonts() {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let res = Bundle.main.resourceURL {
        dirs.append(res)
        dirs.append(res.appendingPathComponent("Fonts", isDirectory: true))
    }
    if let override = ProcessInfo.processInfo.environment["WAVE_NATIVE_FONTS"], !override.isEmpty {
        dirs.append(URL(fileURLWithPath: override, isDirectory: true))
    }
    dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Fonts", isDirectory: true))
    if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
        dirs.append(exeDir.appendingPathComponent("Fonts", isDirectory: true))
    }
    var seen = Set<String>()
    for dir in dirs {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
        for url in items where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

registerBundledFonts()

// Resolve the `wavesrv` binary: an explicit override first (CI / dev), then the
// copy bundled in the .app's Resources, then PATH. The per-launch random
// WAVETERM_AUTH_KEY (GUARDS §P) and the data/config home are set by the
// AppCoordinator spawn step inside WaveUI.
// Also captures the app path for the bundle: durable shells exec a bundled "wsh"
// (the job-manager daemon) that wavesrv resolves at $WAVETERM_APP_PATH/bin. In the
// .app that is <Resources>/bin (next to the bundled wavesrv), so WAVETERM_APP_PATH =
// <Resources>. In dev (the WAVE_NATIVE_WAVESRV override) wavesrv resolves bin/
// cwd-relative, so the var stays unset.
let (wavesrvPath, bundledAppPath): (String, String?) = {
    let env = ProcessInfo.processInfo.environment
    if let override = env["WAVE_NATIVE_WAVESRV"], !override.isEmpty {
        return (override, nil)
    }
    if let bundled = Bundle.main.url(forResource: "wavesrv", withExtension: nil)?.path {
        return (bundled, (bundled as NSString).deletingLastPathComponent)
    }
    // Dev run without the override (debug binary launched directly): find the
    // package's bin/wavesrv.arm64 by walking up from the executable
    // (.build/<triple>/<config>/WaveApp -> package root), then try the cwd.
    // Without this, a spawn (needed once no wavesrv is left running) failed
    // with a bare relative "wavesrv" and the window came up black.
    let fm = FileManager.default
    #if arch(arm64)
        let devName = "bin/wavesrv.arm64"
    #else
        let devName = "bin/wavesrv.x64"
    #endif
    if var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(devName)
            if fm.isExecutableFile(atPath: candidate.path) {
                return (candidate.path, nil)
            }
            dir.deleteLastPathComponent()
        }
    }
    let cwdCandidate = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(devName)
    if fm.isExecutableFile(atPath: cwdCandidate.path) {
        return (cwdCandidate.path, nil)
    }
    return ("wavesrv", nil)
}()

// wavesrv REQUIRES WAVETERM_DATA_HOME + WAVETERM_CONFIG_HOME (it exits early if
// they are unset). Honor an explicit override, otherwise use an ISOLATED native
// home under Application Support so this client never contends for the sqlite
// lock of a running Electron Wave (and gets its own starter workspace on first
// launch). Mirrors Electron's getWaveDataDir/getWaveConfigDir layout.
let launchConfig: AppLaunchConfig = {
    let env = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    let defaultBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("waveterm-native", isDirectory: true)
    let dataHome = env["WAVETERM_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBase.path
    let configHome = env["WAVETERM_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? defaultBase.appendingPathComponent("config", isDirectory: true).path
    try? fm.createDirectory(atPath: dataHome, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: configHome, withIntermediateDirectories: true)
    // Native-app version (WAVE_NATIVE_VERSION override, else the build constant) gates
    // the single-instance upgrade behavior; a fake version per build exercises the
    // takeover path (docs/LIVE-UPGRADE-TESTING.md).
    var extraEnv: [String: String] = [:]
    if let bundledAppPath { extraEnv["WAVETERM_APP_PATH"] = bundledAppPath }
    return AppLaunchConfig(
        dataHome: dataHome, configHome: configHome,
        nativeVersion: WaveProtocolConst.nativeVersion(),
        extraEnv: extraEnv)
}()

// One session (transport + store) per window: each binds a distinct backend
// `window:<id>`/route, and the transports share a single detached `wavesrv` through
// the spawn/attach + `WaveServerLock` path (workspace-per-window topology).
let makeSession: WindowManager.SessionFactory = {
    let transport = WaveTransportClient(wavesrvPath: wavesrvPath)
    let store = ObjectStore(transport: transport)
    return (transport, store)
}

// Top-level `main.swift` executes on the main thread; assert main-actor isolation
// so we can call the `@MainActor` `runWaveApp` (which then runs NSApplication).
MainActor.assumeIsolated {
    runWaveApp(
        makeSession: makeSession,
        provider: ComposedBlockViewProvider(),
        config: launchConfig
    )
}
