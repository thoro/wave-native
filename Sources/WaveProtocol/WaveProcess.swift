// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — wavesrv child-process launch + discovery.
//
// Implements PROTOCOL.md §1 ("Launch / discovery") and GUARDS §P: spawn
// `wavesrv` with env (incl. a fresh random `WAVETERM_AUTH_KEY`), then scan its
// STDERR for the single line
//   `WAVESRV-ESTART ws:<addr> web:<addr> version:<v> buildtime:<t>`
// printed via fmt directly to stderr (`cmd/server/main-server.go:611`). The
// Electron launcher matches with `line.includes("WAVESRV-ESTART")`
// (`emain/emain-wavesrv.ts:108-123`); we mirror that (find the prefix anywhere on
// the line) and fail fast with a clear error if it never appears.

import Foundation
import ObjectiveC
import WaveCore

/// Stable key for binding the wavesrv stdin `FileHandle` lifetime to its `Process`
/// via an associated object (see `WaveProcessLauncher.launch`). Its address is the
/// key.
private nonisolated(unsafe) var stdinHandleAssocKey: UInt8 = 0

/// Incremental scanner over a wavesrv stderr byte stream that yields the parsed
/// `ServerAddrs` once a `WAVESRV-ESTART` line is seen. Pure + unit-tested
/// (GUARDS §P) so the launch path's correctness does not depend on a live process.
public struct EStartScanner {
    private var buffer = Data()

    public init() {}

    /// Feed a chunk of stderr bytes. Returns:
    ///   - `.success(addrs)` once a complete `WAVESRV-ESTART` line is parsed,
    ///   - `.failure(err)` if such a line is malformed,
    ///   - `nil` if no terminator/ESTART line has arrived yet (feed more).
    public mutating func feed(_ chunk: Data) -> Result<ServerAddrs, WaveError>? {
        buffer.append(chunk)
        while let nlIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex ..< nlIndex])
            buffer.removeSubrange(buffer.startIndex ... nlIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let result = EStartScanner.parseLine(line) {
                return result
            }
        }
        return nil
    }

    /// Parse a single (possibly already line-split) stderr line. Returns nil if the
    /// line does not contain the `WAVESRV-ESTART` prefix.
    public static func parseLine(_ line: String) -> Result<ServerAddrs, WaveError>? {
        guard let range = line.range(of: WaveProtocolConst.eStartPrefix) else { return nil }
        let payload = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return .success(try ServerAddrs.parseEStart(payload))
        } catch let err as WaveError {
            return .failure(err)
        } catch {
            return .failure(.badEStart("parse failed: \(error) line=\(line)"))
        }
    }
}

/// Launches the `wavesrv` binary and resolves its TCP addresses from the ESTART
/// line. Holds nothing after launch except the returned `Process`, which the
/// caller MUST retain (deallocating it terminates the child).
public enum WaveProcessLauncher {
    /// Launch `wavesrv` at `path` with `env`, returning the discovered addresses
    /// and the running `Process`. Throws `WaveError.spawnFailed` if the process
    /// cannot start and `WaveError.badEStart` if the ESTART line does not appear
    /// within `timeoutMs` (GUARDS §P).
    public static func launch(
        path: String,
        env: [String: String],
        arguments: [String] = [],
        timeoutMs: Int64 = 10000
    ) async throws -> (addrs: ServerAddrs, process: Process) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Overlay the caller's env onto the current environment so PATH etc. survive
        // while WAVETERM_* (incl. the auth key) take precedence (GUARDS §P).
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        process.environment = merged

        // Discard stdout so a full stdout pipe never blocks wavesrv at startup.
        process.standardOutput = FileHandle.nullDevice

        // Detach stderr to a LOG FILE rather than a Pipe. wavesrv writes both the
        // ESTART line AND its ongoing logs to stderr; a Pipe's read end closes when
        // the app exits, so wavesrv would die of SIGPIPE on its next log write —
        // defeating the seamless upgrade. A file write never breaks, so wavesrv
        // survives the app. ESTART is read by tailing the file. We fall back to a Pipe
        // only when the data home is unknown (no detachment is possible there anyway).
        let dataHome = env[WaveProtocolConst.dataHomeEnv].flatMap { $0.isEmpty ? nil : $0 }
        var stderrTail: FileHandle?
        var stderrPipe: Pipe?
        if let dataHome, let (writeFH, readFH) = Self.makeStderrLog(dataHome: dataHome) {
            process.standardError = writeFH
            stderrTail = readFH
        } else {
            let pipe = Pipe()
            process.standardError = pipe
            stderrPipe = pipe
        }
        // wavesrv treats stdin EOF/error as "parent died" and shuts down immediately
        // (cmd/server/main-server.go stdinReadWatch, mirroring Electron). For the
        // SEAMLESS-UPGRADE path we want the OPPOSITE: wavesrv must SURVIVE the app
        // exiting so its PTYs/scrollback persist for the next app instance to attach
        // to. A plain Pipe EOFs the moment the app exits (its write fd closes), and
        // /dev/null reads as immediate EOF — both would kill wavesrv. Instead give it
        // a named FIFO opened O_RDWR: because the child's inherited fd is itself a
        // writer, read() blocks forever (never EOF) and keeps doing so even after the
        // app process — and its own copy of the fd — is gone. The FileHandle is bound
        // to the `Process` via an associated object so ARC can't close the parent's
        // copy across the async ESTART await (harmless to the child either way).
        let stdinHandle = detachedStdinHandle(env: env)
        process.standardInput = stdinHandle

        do {
            try process.run()
        } catch {
            throw WaveError.spawnFailed("could not run \(path): \(error)")
        }
        if let stdinHandle {
            objc_setAssociatedObject(process, &stdinHandleAssocKey, stdinHandle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        do {
            let addrs: ServerAddrs
            if let stderrTail {
                addrs = try await awaitEStart(tailing: stderrTail, process: process, timeoutMs: timeoutMs)
            } else if let stderrPipe {
                addrs = try await awaitEStart(reading: stderrPipe.fileHandleForReading, timeoutMs: timeoutMs)
            } else {
                throw WaveError.spawnFailed("no stderr channel for wavesrv")
            }
            return (addrs, process)
        } catch {
            process.terminate()
            throw error
        }
    }

    /// Create the detached stderr log file in the data home, returning a write handle
    /// (handed to wavesrv) and an independent read handle (we tail it for ESTART).
    /// The file is truncated per launch so the ESTART we parse is this run's.
    private static func makeStderrLog(dataHome: String) -> (write: FileHandle, read: FileHandle)? {
        let path = (dataHome as NSString).appendingPathComponent("wavesrv.log")
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let write = FileHandle(forWritingAtPath: path),
              let read = FileHandle(forReadingAtPath: path) else { return nil }
        return (write, read)
    }

    /// Tail a (file-backed) stderr for the ESTART line. Unlike a Pipe, a regular file
    /// never blocks and survives the app, so we poll: read newly-appended bytes, and
    /// fail fast if wavesrv exits or the deadline passes (GUARDS §P).
    private static func awaitEStart(
        tailing read: FileHandle, process: Process, timeoutMs: Int64
    ) async throws -> ServerAddrs {
        let box = EStartBox()
        let deadline = ProcessInfo.processInfo.systemUptime + Double(max(0, timeoutMs)) / 1000
        while true {
            let chunk = read.availableData
            if chunk.isEmpty {
                if !process.isRunning {
                    throw WaveError.badEStart("wavesrv exited before \(WaveProtocolConst.eStartPrefix)")
                }
                if ProcessInfo.processInfo.systemUptime > deadline {
                    throw WaveError.badEStart("timeout (\(timeoutMs)ms) waiting for \(WaveProtocolConst.eStartPrefix)")
                }
                try await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            guard let result = box.feed(chunk) else { continue }
            switch result {
            case let .success(addrs): return addrs
            case let .failure(err): throw err
            }
        }
    }

    /// Pipe-backed ESTART read (degraded fallback when the data home is unknown — no
    /// stderr detachment, so wavesrv will not survive the app here).
    private static func awaitEStart(
        reading readHandle: FileHandle, timeoutMs: Int64
    ) async throws -> ServerAddrs {
        let box = EStartBox()
        let addrs: ServerAddrs = try await withCheckedThrowingContinuation { cont in
            readHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    if box.finishOnce() {
                        handle.readabilityHandler = nil
                        cont.resume(throwing: WaveError.badEStart(
                            "wavesrv stderr closed before \(WaveProtocolConst.eStartPrefix)"))
                    }
                    return
                }
                guard let result = box.feed(chunk) else { return }
                handle.readabilityHandler = nil
                switch result {
                case let .success(addrs): cont.resume(returning: addrs)
                case let .failure(err): cont.resume(throwing: err)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
                if box.finishOnce() {
                    readHandle.readabilityHandler = nil
                    cont.resume(throwing: WaveError.badEStart(
                        "timeout (\(timeoutMs)ms) waiting for \(WaveProtocolConst.eStartPrefix)"))
                }
            }
        }
        readHandle.readabilityHandler = { handle in _ = handle.availableData }
        return addrs
    }

    /// Build the detached stdin `FileHandle` for wavesrv: a named FIFO in the data
    /// home opened O_RDWR so reads block forever (never EOF), keeping wavesrv alive
    /// across app exits (seamless upgrade). Falls back to `nil` (inherit the app's
    /// stdin) if the data home is unknown or the FIFO can't be created — a degraded
    /// but safe outcome (no detachment) rather than a failed launch.
    private static func detachedStdinHandle(env: [String: String]) -> FileHandle? {
        guard let dataHome = env[WaveProtocolConst.dataHomeEnv], !dataHome.isEmpty else { return nil }
        let fifoPath = (dataHome as NSString).appendingPathComponent("wavesrv.stdin.fifo")
        // A stale FIFO from a prior run is harmless to reuse, but recreate it so its
        // mode/owner are well-defined. mkfifo fails with EEXIST if it survived; that
        // is fine — we just open the existing one.
        if mkfifo(fifoPath, 0o600) != 0 && errno != EEXIST {
            return nil
        }
        let fd = open(fifoPath, O_RDWR)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Thread-safe single-resolution guard shared by the stderr reader and the
/// timeout watchdog so the launch continuation resumes exactly once.
private final class EStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner = EStartScanner()
    private var done = false

    /// Feed bytes; returns a result only on the first ESTART/malformed line.
    func feed(_ chunk: Data) -> Result<ServerAddrs, WaveError>? {
        lock.lock()
        defer { lock.unlock() }
        if done { return nil }
        guard let result = scanner.feed(chunk) else { return nil }
        done = true
        return result
    }

    /// Claim completion for the EOF/timeout paths. Returns true exactly once.
    func finishOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Auth key generation (GUARDS §P)

/// Generates the per-launch `WAVETERM_AUTH_KEY` (GUARDS §P: fresh + random every
/// launch, never hardcoded; mirrors `emain/authkey.ts:9`).
public enum WaveAuthKey {
    /// A fresh 32-byte random key, hex-encoded (64 chars).
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
