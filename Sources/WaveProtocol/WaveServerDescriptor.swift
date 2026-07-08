// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — "running server" descriptor + single-instance lock for the
// SEAMLESS NATIVE-APP UPGRADE path (Approach A).
//
// Terminal scrollback + the PTYs live inside `wavesrv`, not the native app. To let
// a native-app restart be seamless, we launch `wavesrv` DETACHED from the app's
// lifetime (see WaveProcess.swift) and persist a small descriptor for the server
// we started: its ws/web addrs, the auth key it was given, and its pid. The NEXT
// app launch reads this descriptor and, if that wavesrv is still alive AND its auth
// key still works, ATTACHES to it instead of spawning a fresh one — so the existing
// PTYs survive the upgrade and the normal backfill resumes them.
//
// A `flock`-based lock serializes the discover-or-spawn decision across concurrent
// app instances that share one data home, so we never start two wavesrv for the
// same sqlite database (which both hold an exclusive lock on anyway).

import Foundation
import WaveCore

/// Persisted description of the `wavesrv` this (or a prior) app instance spawned.
/// Lives at `<dataHome>/wavesrv-running.json`. All fields lowercase (no
/// underscores) per the project's JSON conventions.
public struct RunningServerDescriptor: Codable, Sendable, Equatable {
    public let wsaddr: String
    public let webaddr: String
    public let authkey: String
    public let pid: Int32
    /// Native-app version of the instance that spawned this wavesrv. The NEXT launch
    /// compares it to its own version: a SAME-version relaunch attaches seamlessly; a
    /// DIFFERENT-version relaunch (an upgrade) restarts wavesrv so the new backend
    /// binary takes over (durable PTYs are re-adopted by the backend job manager).
    /// Optional so descriptors written before this field decode as `nil`.
    public let version: String?

    public init(wsaddr: String, webaddr: String, authkey: String, pid: Int32, version: String? = nil) {
        self.wsaddr = wsaddr
        self.webaddr = webaddr
        self.authkey = authkey
        self.pid = pid
        self.version = version
    }

    public var addrs: ServerAddrs { ServerAddrs(wsAddr: wsaddr, webAddr: webaddr) }
}

/// Read/write/probe helpers for the running-server descriptor, keyed by the data
/// home (the app's isolated `WAVETERM_DATA_HOME`).
public enum WaveServerDescriptor {
    /// Descriptor file name inside the data home.
    public static let fileName = "wavesrv-running.json"

    public static func path(dataHome: String) -> String {
        (dataHome as NSString).appendingPathComponent(fileName)
    }

    public static func read(dataHome: String) -> RunningServerDescriptor? {
        let url = URL(fileURLWithPath: path(dataHome: dataHome))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RunningServerDescriptor.self, from: data)
    }

    public static func write(_ descriptor: RunningServerDescriptor, dataHome: String) {
        guard let data = try? JSONEncoder().encode(descriptor) else { return }
        // Write to a temp sibling then rename so a concurrent reader never sees a
        // half-written file (atomic replace within the same directory).
        let url = URL(fileURLWithPath: path(dataHome: dataHome))
        try? data.write(to: url, options: .atomic)
    }

    public static func remove(dataHome: String) {
        try? FileManager.default.removeItem(atPath: path(dataHome: dataHome))
    }

    /// True if a process with `pid` currently exists. `kill(pid, 0)` performs the
    /// permission/existence check without sending a signal: 0 => alive; ESRCH =>
    /// gone; EPERM => alive but not ours (still "alive" for our purposes).
    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Terminate the wavesrv recorded in the descriptor and clear it, so the next
    /// spawn starts a FRESH server. Used only on a DIFFERENT-version takeover (an
    /// upgrade): the detached old wavesrv must be replaced by the new build's binary.
    /// We SIGTERM, wait for it to exit (so it releases the sqlite lock before the new
    /// one opens the same DB), then SIGKILL as a last resort. The durable local PTYs
    /// survive because the backend job manager re-adopts them on the new wavesrv.
    /// Blocking by design — runs once, before the new UI is built.
    public static func terminateRunning(dataHome: String, timeoutMs: Int = 5000) {
        defer { remove(dataHome: dataHome) }
        guard let desc = read(dataHome: dataHome), desc.pid > 0, isAlive(pid: desc.pid) else { return }
        kill(desc.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while isAlive(pid: desc.pid) && Date() < deadline {
            usleep(50_000)
        }
        if isAlive(pid: desc.pid) {
            kill(desc.pid, SIGKILL)
        }
    }
}

/// A `flock`-based advisory lock over `<dataHome>/wavesrv.lock`, held only for the
/// duration of the discover-or-spawn critical section so two app instances sharing
/// a data home can't both decide to spawn a fresh wavesrv at the same moment.
public final class WaveServerLock {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Lock file name inside the data home.
    public static let fileName = "wavesrv.lock"

    /// Async acquire that NEVER blocks a Swift cooperative-pool thread: the
    /// blocking flock() waits on a GCD thread. With one window this is
    /// equivalent to the sync path; with MANY windows starting at once (one
    /// per workspace) the old sync call parked every pool thread in flock()
    /// and starved the pool -- the spawning window's own continuations could
    /// no longer run, deadlocking the whole app ("stuck after the first
    /// window, no shells restored").
    public static func acquire(dataHome: String) async -> WaveServerLock? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: acquireBlocking(dataHome: dataHome))
            }
        }
    }

    /// Open + exclusively lock the data home's server lock, blocking until it is
    /// acquired. Returns nil only if the lock file cannot be opened.
    public static func acquireBlocking(dataHome: String) -> WaveServerLock? {
        let path = (dataHome as NSString).appendingPathComponent(fileName)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        // Retry across EINTR; flock() can be interrupted by signals.
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            return nil
        }
        return WaveServerLock(fd: fd)
    }

    /// Release the lock and close the descriptor. Call exactly once.
    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
