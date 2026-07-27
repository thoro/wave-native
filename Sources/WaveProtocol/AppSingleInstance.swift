// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — APP-LEVEL single-instance lock + control socket for the
// VERSION-AWARE upgrade path.
//
// Electron just calls `app.requestSingleInstanceLock()` and routes a second launch
// to `createNewWaveWindow` (`emain/emain.ts:382-392`) — no version comparison. We
// go further: a second launch of the SAME version asks the running instance to open
// a new window and exits; a DIFFERENT version (an upgrade) takes over — it signals
// the old instance to close its UI + exit, then (re)starts as the primary and
// restarts wavesrv to adopt the new backend binary.
//
// Two primitives live here (Foundation only, so they unit-test without AppKit):
//   - `AppInstanceLock`: a `flock` over `<dataHome>/wave-native-app.lock` HELD for the
//     whole app lifetime. The holder is the live primary; a non-blocking acquire that
//     fails means a primary is already running. Mirrors `WaveServerLock`'s flock, but
//     non-blocking + held long-term rather than for a short critical section.
//   - `AppInstanceServer` / `AppInstanceClient`: a unix-domain control socket at
//     `<dataHome>/wave-native.sock` speaking newline-delimited one-line ops, reusing
//     the `TestDriver` listener pattern. The primary listens; a secondary connects,
//     reads the primary's version, then sends `OPEN` (same version) or `SHUTDOWN`
//     (upgrade takeover).

import Foundation
import WaveCore

/// Disable SIGPIPE on a socket fd (macOS lacks `MSG_NOSIGNAL`): a write to a peer that
/// already hung up returns EPIPE instead of raising the process-fatal signal.
private func setNoSigpipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Control-socket op names (one line each, no payload). The primary announces its
/// version on accept; the secondary replies with exactly one of these.
public enum AppInstanceOp {
    /// "Open another window in the running (same-version) instance."
    public static let openWindow = "OPEN"
    /// "Shut down your UI + exit so I (a different version) can take over."
    public static let shutdownForUpgrade = "SHUTDOWN"
    /// Query: "which tab is active in the current (key/frontmost) window?" The
    /// primary replies `TAB <tabid>` (empty id when no window is open). Used by
    /// external launchers (claude-vm) to target the tab the user is looking at —
    /// the backend cannot know this (window focus never reaches wavesrv).
    public static let keyTab = "KEYTAB"
    /// Reply prefix for `keyTab`.
    public static let tabPrefix = "TAB "
    /// Prefix the primary writes on accept: `VERSION <version>`.
    public static let versionPrefix = "VERSION "
}

/// A `flock`-based advisory lock over `<dataHome>/wave-native-app.lock`, held for the
/// app's entire lifetime. Unlike `WaveServerLock` (blocking, short critical section)
/// this is acquired NON-BLOCKING: a failed acquire means another app instance (the
/// primary) already holds it.
public final class AppInstanceLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static let fileName = "wave-native-app.lock"

    public static func path(dataHome: String) -> String {
        (dataHome as NSString).appendingPathComponent(fileName)
    }

    /// Non-blocking acquire. Returns nil when another instance holds the lock (a
    /// primary is running) or the lock file cannot be opened.
    public static func tryAcquire(dataHome: String) -> AppInstanceLock? {
        let fd = open(path(dataHome: dataHome), O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return AppInstanceLock(fd: fd)
    }

    /// Poll for the lock until acquired or `timeoutMs` elapses. Used by the takeover
    /// path to wait for the old primary to exit (which releases its flock).
    public static func waitAcquire(dataHome: String, timeoutMs: Int) -> AppInstanceLock? {
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000)
        repeat {
            if let lock = tryAcquire(dataHome: dataHome) { return lock }
            usleep(50_000)
        } while Date() < deadline
        return tryAcquire(dataHome: dataHome)
    }

    /// Release + close. The OS also releases the flock on process exit, so callers
    /// that simply terminate need not call this.
    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Connects to a running primary's control socket as the SECONDARY launch: reads the
/// primary's version and decides whether to ask it to open a window (same version) or
/// to shut down for an upgrade takeover (different version). All-synchronous blocking
/// socket I/O — it runs once, early in launch, before any UI exists.
public enum AppInstanceClient {
    public enum Outcome: Equatable {
        /// Same version: the primary opened a window; this process should exit.
        case openedWindow
        /// Different version: the primary was asked to shut down; this process should
        /// wait for the lock and take over (restarting wavesrv).
        case requestedTakeover
        /// Could not reach the primary (crashed holder / stale lock): caller decides.
        case failed
    }

    public static func socketPath(dataHome: String) -> String {
        (dataHome as NSString).appendingPathComponent("wave-native.sock")
    }

    public static func negotiate(dataHome: String, myVersion: String) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }
        defer { close(fd) }
        setNoSigpipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath(dataHome: dataHome)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: min(strlen(src) + 1, 104)))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return .failed }

        guard let line = readLine(fd: fd), line.hasPrefix(AppInstanceOp.versionPrefix) else { return .failed }
        let primaryVersion = String(line.dropFirst(AppInstanceOp.versionPrefix.count))
        let op = (primaryVersion == myVersion) ? AppInstanceOp.openWindow : AppInstanceOp.shutdownForUpgrade
        guard writeLine(fd: fd, op) else { return .failed }
        return (op == AppInstanceOp.openWindow) ? .openedWindow : .requestedTakeover
    }

    private static func readLine(fd: Int32) -> String? {
        var acc = ""
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let n = read(fd, &byte, 1)
            if n <= 0 { return acc.isEmpty ? nil : acc }
            if byte == 0x0A { return acc }
            acc.append(Character(UnicodeScalar(byte)))
        }
        return acc.isEmpty ? nil : acc
    }

    private static func writeLine(fd: Int32, _ s: String) -> Bool {
        let data = Array((s + "\n").utf8)
        return data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) == data.count }
    }
}

/// The PRIMARY's control-socket listener. Accepts secondary connections, announces
/// this instance's version, reads one op line, and hands it to `onOp` (invoked on the
/// listener thread — the caller is responsible for hopping to the main actor). Mirrors
/// `TestDriver`'s detached accept loop.
public final class AppInstanceServer: @unchecked Sendable {
    private let path: String
    private let version: String
    /// Handles one op line; a non-nil return is written back to the client as a
    /// single reply line before the connection closes (query ops like `KEYTAB`).
    private let onOp: @Sendable (String) -> String?
    private let listenFD = AtomicFD()

    public init(dataHome: String, version: String, onOp: @escaping @Sendable (String) -> String?) {
        self.path = AppInstanceClient.socketPath(dataHome: dataHome)
        self.version = version
        self.onOp = onOp
    }

    public func start() {
        Thread.detachNewThread { [self] in serve() }
    }

    public func stop() {
        listenFD.close()
        unlink(path)
    }

    private func serve() {
        // A secondary that connects then disconnects before reading our version hello
        // would otherwise make our write raise SIGPIPE. SO_NOSIGPIPE (set per-fd) covers
        // the accepted socket, but ignore SIGPIPE process-wide too as a belt: a broken
        // pipe must never be fatal to the app. (Harmless elsewhere — writes return EPIPE.)
        signal(SIGPIPE, SIG_IGN)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: min(strlen(src) + 1, 104)))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }
        listenFD.set(fd)

        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { break } // listener closed (stop()) or fatal error
            handleConnection(cfd)
            close(cfd)
        }
    }

    private func handleConnection(_ cfd: Int32) {
        // A secondary may disconnect mid-handshake; without SO_NOSIGPIPE a write to the
        // closed peer raises SIGPIPE and would kill the whole app.
        setNoSigpipe(cfd)
        let hello = Array((AppInstanceOp.versionPrefix + version + "\n").utf8)
        _ = hello.withUnsafeBytes { write(cfd, $0.baseAddress, hello.count) }
        // Read exactly one op line.
        var acc = ""
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let n = read(cfd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            acc.append(Character(UnicodeScalar(byte)))
        }
        let op = acc.trimmingCharacters(in: .whitespaces)
        guard !op.isEmpty else { return }
        if let reply = onOp(op) {
            let out = Array((reply + "\n").utf8)
            _ = out.withUnsafeBytes { write(cfd, $0.baseAddress, out.count) }
        }
    }
}

/// Tiny lock-guarded file descriptor box so `stop()` (any thread) can close the
/// listener fd the accept loop is blocked on.
private final class AtomicFD: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    func set(_ value: Int32) { lock.lock(); fd = value; lock.unlock() }
    func close() {
        lock.lock(); let v = fd; fd = -1; lock.unlock()
        if v >= 0 { Foundation.close(v) }
    }
}

/// Persisted record of the workspaces currently shown in open windows, at
/// `<dataHome>/wave-native-open-windows.json`. The authoritative restore source is the
/// backend `client.windowids` (each window:<id> is a sqlite row that SURVIVES a
/// wavesrv restart), so this file is a best-effort mirror used for diagnostics and as
/// a fallback hint; the WindowManager writes it as windows open/close.
/// A saved window frame (screen coordinates), keyed by the stable backend window id.
/// Used for best-effort window position/size restore across launches.
public struct WindowFrameRecord: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct OpenWindowsRecord: Codable, Sendable, Equatable {
    public var workspaceids: [String]
    /// windowId → last-known frame, for best-effort position restore. Decoded leniently
    /// (below) so an older record without this field still loads.
    public var windowframes: [String: WindowFrameRecord]

    public init(workspaceids: [String], windowframes: [String: WindowFrameRecord] = [:]) {
        self.workspaceids = workspaceids
        self.windowframes = windowframes
    }

    enum CodingKeys: String, CodingKey { case workspaceids, windowframes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceids = (try? c.decode([String].self, forKey: .workspaceids)) ?? []
        windowframes = (try? c.decode([String: WindowFrameRecord].self, forKey: .windowframes)) ?? [:]
    }

    public static let fileName = "wave-native-open-windows.json"

    public static func path(dataHome: String) -> String {
        (dataHome as NSString).appendingPathComponent(fileName)
    }

    public static func read(dataHome: String) -> OpenWindowsRecord? {
        let url = URL(fileURLWithPath: path(dataHome: dataHome))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OpenWindowsRecord.self, from: data)
    }

    public static func write(_ record: OpenWindowsRecord, dataHome: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: URL(fileURLWithPath: path(dataHome: dataHome)), options: .atomic)
    }
}
