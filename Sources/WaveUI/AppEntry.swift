// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the AppKit application bootstrap (PROTOCOL.md §7). `runWaveApp` wires
// the injected transport + store into an AppCoordinator and a WaveWindowController
// and runs the NSApplication. The concrete `WaveTransport` (WaveProtocol) and
// `ObjectStoreProtocol` (WaveStore) are injected by the executable (WaveApp), so
// WaveUI never depends on their construction.

import AppKit
import WaveCore
import WaveProtocol

/// NSApplicationDelegate that owns the main window controller.
@MainActor
public final class WaveAppDelegate: NSObject, NSApplicationDelegate {
    /// When true, `applicationWillTerminate` LEAVES wavesrv running instead of terminating
    /// it. Set only for a version-takeover shutdown, where the successor instance must adopt
    /// the still-detached wavesrv. Every real quit — Cmd-Q, the Quit menu, "Quit and Close
    /// All Shells", and the Dock icon's Quit — reaches termination with this false and so
    /// tears wavesrv down. (Closing the last window no longer quits the app at all.)
    private var keepServerOnTerminate = false

    private let makeSession: WindowManager.SessionFactory
    private let provider: BlockViewProvider
    private let config: AppLaunchConfig
    private var windowManager: WindowManager?
    private let menuBar = MenuBarController()

    /// Held app-instance lock (single-instance primary marker) + this instance's
    /// version, and whether we are taking over from a different-version instance and so
    /// must restart wavesrv. Set by `runWaveApp` from the launch-time gate.
    private let instanceLock: AppInstanceLock?
    private let version: String
    private let forceWavesrvRestart: Bool
    private var instanceServer: AppInstanceServer?

    public init(
        makeSession: @escaping WindowManager.SessionFactory,
        provider: BlockViewProvider = DefaultBlockViewProvider(),
        config: AppLaunchConfig = AppLaunchConfig(),
        instanceLock: AppInstanceLock? = nil,
        version: String = WaveProtocolConst.defaultNativeVersion,
        forceWavesrvRestart: Bool = false
    ) {
        self.makeSession = makeSession
        self.provider = provider
        self.config = config
        self.instanceLock = instanceLock
        self.version = version
        self.forceWavesrvRestart = forceWavesrvRestart
    }

    /// Set the Dock/app icon to the bundled Wave icon. The .app gets it from
    /// Info.plist (CFBundleIconFile) too, but the dev run (unbundled SwiftPM binary)
    /// has no Info.plist — so resolve the icns from a WAVE_NATIVE_ICON override, the
    /// .app Resources, or the dev-tree Resources/ (cwd / next to the binary), mirroring
    /// registerBundledFonts.
    private static func applyAppIcon() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WAVE_NATIVE_ICON"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("AppIcon.icns"))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.icns"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("Resources/AppIcon.icns"))
        }
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = img
                return
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Self.applyAppIcon()
        // Upgrade takeover: replace the previous instance's detached wavesrv with this
        // build's binary BEFORE the window manager's spawn/attach path runs (so it
        // spawns fresh instead of attaching to the old server). The durable local PTYs
        // are re-adopted by the new wavesrv's job manager.
        if forceWavesrvRestart, let dataHome = config.dataHome {
            WaveServerDescriptor.terminateRunning(dataHome: dataHome)
        }
        // Menu actions target whichever window is key (each NSWindow owns its own
        // controller in the workspace-per-window model).
        menuBar.resolveController = {
            NSApp.keyWindow?.windowController as? WaveWindowController
                ?? NSApp.mainWindow?.windowController as? WaveWindowController
        }
        menuBar.install()
        let manager = WindowManager(makeSession: makeSession, provider: provider, config: config, menuBar: menuBar)
        windowManager = manager
        // Desktop-notification click routing: focus the source window → tab → pane.
        NotificationManager.shared.configure()
        NotificationManager.shared.onActivate = { [weak manager] blockId, tabId, windowId in
            manager?.focusWindowTabBlock(windowId: windowId, tabId: tabId, blockId: blockId)
        }
        manager.start()
        startInstanceServer()
        NSApp.activate(ignoringOtherApps: true)
        scheduleSnapshotIfRequested()
        if let sock = ProcessInfo.processInfo.environment["WAVE_NATIVE_TEST_SOCK"], !sock.isEmpty {
            testDriver = TestDriver(path: sock)
            testDriver?.start()
        }
    }

    /// Stand up the control socket so later launches can reach this (primary) instance.
    /// Ops arrive on the listener thread; hop to the main actor before touching the
    /// window manager.
    private func startInstanceServer() {
        guard let dataHome = config.dataHome else { return }
        let server = AppInstanceServer(dataHome: dataHome, version: version) { op in
            // Query ops answer synchronously on the listener thread (the reply is
            // written on the same connection); action ops stay fire-and-forget.
            if op == AppInstanceOp.keyTab {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        AppInstanceOp.tabPrefix
                            + (retainedAppDelegate?.windowManager?.currentActiveTabId() ?? "")
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    retainedAppDelegate?.handleInstanceOp(op)
                }
            }
            return nil
        }
        instanceServer = server
        server.start()
    }

    /// Handle a control-socket op from a later launch.
    private func handleInstanceOp(_ op: String) {
        switch op {
        case AppInstanceOp.openWindow:
            // Same-version second launch: open a fresh window and surface the app.
            windowManager?.openNewWindow()
            NSApp.activate(ignoringOtherApps: true)
        case AppInstanceOp.shutdownForUpgrade:
            // A different-version instance is taking over: close our UI and exit. Keep
            // the detached wavesrv alive (the new instance decides whether to restart
            // it) and keep our backend windows for restore.
            keepServerOnTerminate = true
            windowManager?.beginTermination()
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private var testDriver: TestDriver?

    /// Headless UI verification hook: when `WAVE_NATIVE_SNAPSHOT` is set, render the
    /// main window's own view hierarchy to a PNG at that path after a delay (so the
    /// chain has loaded and blocks have rendered). This is an *in-app* capture — it
    /// needs no Screen-Recording permission, unlike `screencapture`. Quits after the
    /// shot when `WAVE_NATIVE_SNAPSHOT_QUIT=1`.
    private func scheduleSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WAVE_NATIVE_SNAPSHOT"], !path.isEmpty else { return }
        let delay = Double(env["WAVE_NATIVE_SNAPSHOT_DELAY"] ?? "") ?? 10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.mainWindow ?? NSApp.windows.first
            if let view = window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data("WAVE-SNAPSHOT-WROTE \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("WAVE-SNAPSHOT-FAILED no window/contentView\n".utf8))
            }
            if env["WAVE_NATIVE_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    /// Arm the activation-click pane focus (see `WaveWindow.appActivationClickPending`):
    /// when a click re-activates the APP, the clicked window is often key again before
    /// the click dispatches, so `isKeyWindow` alone can't identify that click.
    public func applicationDidBecomeActive(_ notification: Notification) {
        WaveWindow.appActivationClickPending = true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window does NOT quit the app — it keeps running (windowless) with
        // wavesrv + durable shells alive, so the user can reopen instantly. Only an explicit
        // Quit tears things down.
        false
    }

    /// Clicking the Dock icon (or otherwise reopening) with no windows restores a window —
    /// binding the kept backend window, so its workspace + durable shells come back.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            windowManager?.reopenIfNeeded()
        }
        return true
    }

    /// Mark termination BEFORE windows close (Cmd-Q with multiple windows) so their
    /// `windowWillClose` keeps the backend windows for restore instead of deleting them.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowManager?.beginTermination()
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
        windowManager?.shutdown()
        // Terminate wavesrv on quit, EXCEPT a version-takeover shutdown (the successor adopts
        // it). Reaching here already means a real quit — closing the last window no longer
        // terminates the app. Durable shells survive a wavesrv restart, so a fresh launch
        // re-attaches to the re-adopted shells. Done after `shutdown()` disconnects the
        // transports, so no in-flight service call is left to error out.
        if !keepServerOnTerminate, let dataHome = config.dataHome {
            WaveServerDescriptor.terminateRunning(dataHome: dataHome, timeoutMs: 2000)
        }
        instanceServer?.stop()
        // The OS releases the flock on exit anyway, but release explicitly so a takeover
        // successor can acquire it as soon as possible.
        instanceLock?.release()
    }
}

/// Boot the Wave native app. Call from the executable's `main`.
///
/// - Parameters:
///   - makeSession: builds a fresh `(WaveTransport, ObjectStoreProtocol)` per window.
///     Each window binds its own backend `window:<id>`/route; the transports share one
///     `wavesrv` via the spawn/attach path (workspace-per-window topology).
///   - provider: block content provider (WaveTerminal/WaveWeb compose this);
///     defaults to a placeholder so the chrome is runnable standalone.
///   - config: spawn/launch options (GUARDS §P).
@MainActor
public func runWaveApp(
    makeSession: @escaping WindowManager.SessionFactory,
    provider: BlockViewProvider = DefaultBlockViewProvider(),
    config: AppLaunchConfig = AppLaunchConfig()
) -> Never {
    // Single-instance / upgrade gate (before any UI). A same-version second launch
    // hands off to the running instance and exits here; a different-version launch
    // takes over (and will restart wavesrv).
    let version = config.nativeVersion
    guard let primary = AppInstanceGate.evaluate(dataHome: config.dataHome, version: version) else {
        exit(EXIT_SUCCESS)
    }

    let app = NSApplication.shared
    // NSApplication.delegate is weak; keep a strong reference for the app's
    // lifetime. `app.run()` blocks until termination, so this local stays alive.
    let delegate = WaveAppDelegate(
        makeSession: makeSession, provider: provider, config: config,
        instanceLock: primary.lock, version: version,
        forceWavesrvRestart: primary.forceWavesrvRestart)
    retainedAppDelegate = delegate
    app.delegate = delegate
    app.run()
    exit(EXIT_SUCCESS)
}

/// Strong holder for the app delegate (NSApplication only weakly references it).
@MainActor private var retainedAppDelegate: WaveAppDelegate?
