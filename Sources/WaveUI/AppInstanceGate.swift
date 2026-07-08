// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the launch-time single-instance / upgrade GATE. Runs before any window is
// built (from `runWaveApp`) and decides whether this process becomes the primary or
// hands off to an already-running instance.
//
// Decision (mirrors the task's version-aware design; Electron only does the
// same-version "open a window" half via `second-instance`):
//   - No primary running        → become primary (first launch / normal path).
//   - Primary, SAME version     → ask it to open a window; THIS process exits.
//   - Primary, DIFFERENT version → ask it to shut down, wait for its lock, take over,
//                                  and restart wavesrv (the upgrade).
//
// The lock + control socket live in WaveProtocol (`AppSingleInstance.swift`).

import Foundation
import WaveProtocol

@MainActor
enum AppInstanceGate {
    /// The outcome of the gate when this process should run as the primary. `lock` is
    /// the held app-instance lock (nil only in the degraded no-isolation case);
    /// `forceWavesrvRestart` is set on an upgrade takeover so the delegate replaces the
    /// old detached wavesrv with this build's binary.
    struct Primary {
        let lock: AppInstanceLock?
        let forceWavesrvRestart: Bool
    }

    /// Evaluate the gate. Returns `Primary` when this process should start the UI, or
    /// nil when it handed off to a running same-version instance and must exit(0).
    static func evaluate(dataHome: String?, version: String) -> Primary? {
        // Without a data home we can't isolate (no shared lock/socket location); just
        // run — the wavesrv sqlite lock still prevents a real double-spawn.
        guard let dataHome else { return Primary(lock: nil, forceWavesrvRestart: false) }

        if let lock = AppInstanceLock.tryAcquire(dataHome: dataHome) {
            return Primary(lock: lock, forceWavesrvRestart: false)
        }

        // A primary holds the lock — negotiate over its control socket.
        switch AppInstanceClient.negotiate(dataHome: dataHome, myVersion: version) {
        case .openedWindow:
            return nil // same version: the running instance opened a window; exit.
        case .requestedTakeover:
            // Upgrade: wait for the old primary to exit (releasing its flock), then
            // take over and restart wavesrv for the new backend binary.
            let lock = AppInstanceLock.waitAcquire(dataHome: dataHome, timeoutMs: 10000)
            return Primary(lock: lock, forceWavesrvRestart: true)
        case .failed:
            // Lock held but socket unreachable (crashed holder / stale lock). Wait
            // briefly for the lock; if it never frees, run anyway (best-effort — the
            // sqlite lock still guards the DB).
            if let lock = AppInstanceLock.waitAcquire(dataHome: dataHome, timeoutMs: 3000) {
                return Primary(lock: lock, forceWavesrvRestart: false)
            }
            return Primary(lock: nil, forceWavesrvRestart: false)
        }
    }
}
