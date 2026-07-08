// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E harness — a REAL `wavesrv` per test (no mocks of the broker/DB/pty).
//
// Implements docs/E2E.md "Core: a real backend per test class":
//   - random auth key (GUARDS §P), throwaway WAVETERM_DATA_HOME/CONFIG_HOME for
//     full isolation + parallel safety,
//   - spawn `wavesrv`, read stderr until `WAVESRV-ESTART ws:<addr> web:<addr>`
//     and parse the ws/web TCP addresses (PROTOCOL §1, GUARDS §P),
//   - SIGTERM + temp-dir cleanup on teardown.
//
// A fresh data dir triggers wavesrv's own first-launch bootstrap
// (`pkg/wcore/wcore.go:32` EnsureInitialData -> CreateClient + starter workspace +
// window), so GetClientData returns a usable client.windowids[0] (PROTOCOL §7.2).
//
// The wavesrv binary is located via the `WAVE_NATIVE_WAVESRV` env var (CI builds
// the Go binary and points at it). When it is absent the harness throws
// `XCTSkip` so the suite stays green on machines without a built wavesrv while
// still running for real in CI (docs/E2E.md "CI").

import Foundation
import XCTest
import WaveCore

/// Spawns and owns an isolated `wavesrv` child process for an e2e test.
final class WaveServerProcess {
    let binaryPath: String
    let addrs: ServerAddrs
    let authKey: String
    let dataDir: URL
    let configDir: URL

    private let process: Process
    private let stderrPipe: Pipe
    private let stdinPipe: Pipe
    private let collectedStderr: StderrCollector

    /// Locate the wavesrv binary, or throw `XCTSkip` with a clear reason.
    static func locateBinaryOrSkip(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        if let p = ProcessInfo.processInfo.environment["WAVE_NATIVE_WAVESRV"],
           !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw XCTSkip(
            "WAVE_NATIVE_WAVESRV not set to an executable wavesrv binary. " +
            "Build wavesrv (`go build -o <path> ./cmd/server`) and export " +
            "WAVE_NATIVE_WAVESRV=<path> to run the real-backend e2e gates.",
            file: file, line: line
        )
    }

    /// Spawn an isolated wavesrv, or `XCTSkip` if no binary is available.
    static func startOrSkip(
        timeoutSeconds: Double = 20,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> WaveServerProcess {
        let binary = try locateBinaryOrSkip(file: file, line: line)
        return try WaveServerProcess(binaryPath: binary, timeoutSeconds: timeoutSeconds)
    }

    init(binaryPath: String, timeoutSeconds: Double = 20) throws {
        self.binaryPath = binaryPath

        // Isolated, throwaway homes -> no shared state, parallel-safe.
        //
        // CRITICAL: the base path must be SHORT. wavesrv binds a unix domain socket
        // at <dataDir>/wave.sock, and macOS caps sockaddr_un.sun_path at 104 bytes.
        // NSTemporaryDirectory() returns a long /var/folders/<…>/T/ path that, with
        // the dir name + "/data/wave.sock", blows past 104 -> bind fails with
        // "invalid argument" and wavesrv exits BEFORE printing WAVESRV-ESTART. Use
        // /tmp with a short id so the socket path stays well under the limit.
        let shortId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wn-e2e-\(shortId)", isDirectory: true)
        dataDir = base.appendingPathComponent("data", isDirectory: true)
        configDir = base.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Fresh random auth key per launch (GUARDS §P).
        var keyBytes = [UInt8](repeating: 0, count: 32)
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255) }
        authKey = WaveBase64.encode(Data(keyBytes))

        var env = ProcessInfo.processInfo.environment
        // `swift test`/xctest injects DYLD_* (e.g. DYLD_INSERT_LIBRARIES,
        // DYLD_FRAMEWORK_PATH) to load the test runtime. We pass our environment
        // through to the child, but wavesrv is a separate Mach-O (Go) binary that
        // must NOT inherit the test runner's dynamic-linker injection — doing so
        // makes it hang during startup. Strip those before spawning.
        for key in env.keys where key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        env[WaveProtocolConst.authKeyEnv] = authKey
        env[WaveProtocolConst.dataHomeEnv] = dataDir.path
        env[WaveProtocolConst.configHomeEnv] = configDir.path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.environment = env
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice // discard stdout so it can't block
        // wavesrv shuts down on stdin EOF (parent-death detection). Hold a stdin
        // pipe open for the child's lifetime so it survives past ESTART; closing it
        // on teardown (with SIGTERM) lets the server exit cleanly.
        let inPipe = Pipe()
        proc.standardInput = inPipe

        let collector = StderrCollector()
        let estartSemaphore = DispatchSemaphore(value: 0)
        let addrsBox = AddrsBox()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            collector.append(chunk)
            for line in collector.takeCompleteLines() {
                guard line.contains(WaveProtocolConst.eStartPrefix) else { continue }
                // Parse from the prefix onward so any log adornment is ignored.
                guard let range = line.range(of: WaveProtocolConst.eStartPrefix) else { continue }
                let estart = String(line[range.lowerBound...])
                if let a = try? ServerAddrs.parseEStart(estart) {
                    addrsBox.set(a)
                    estartSemaphore.signal()
                    return
                }
            }
        }

        self.process = proc
        self.stderrPipe = errPipe
        self.stdinPipe = inPipe
        self.collectedStderr = collector

        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw WaveError.spawnFailed("could not launch wavesrv at \(binaryPath): \(error)")
        }

        // GUARDS §P: fail fast if ESTART never appears.
        let result = estartSemaphore.wait(timeout: .now() + timeoutSeconds)
        let foundAddrs = addrsBox.get()
        guard result == .success, let foundAddrs else {
            errPipe.fileHandleForReading.readabilityHandler = nil
            proc.terminate()
            let dump = collector.snapshotString()
            try? FileManager.default.removeItem(at: base)
            throw WaveError.badEStart(
                "wavesrv did not print \(WaveProtocolConst.eStartPrefix) within " +
                "\(timeoutSeconds)s. stderr was:\n\(dump)")
        }
        // Keep draining (and discarding) stderr for the process lifetime so a full
        // pipe buffer can never stall wavesrv mid-test.
        errPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        addrs = foundAddrs
    }

    /// SIGTERM the server, wait briefly, and remove the temp homes.
    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            // Bounded wait so a wedged child can't hang teardown.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL) // last resort
            }
        }
        let base = dataDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }
}

/// Thread-safe one-shot holder for the parsed addresses (so the stderr handler,
/// which may be `@Sendable`, never captures a mutable local var).
private final class AddrsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerAddrs?
    func set(_ a: ServerAddrs) { lock.lock(); value = a; lock.unlock() }
    func get() -> ServerAddrs? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Accumulates child stderr bytes and yields complete newline-delimited lines.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var full = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        full.append(data)
    }

    func takeCompleteLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<idx]
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }

    func snapshotString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: full, encoding: .utf8) ?? "<\(full.count) bytes, non-utf8>"
    }
}
