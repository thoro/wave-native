// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for the VERSION-AWARE single-instance upgrade primitives:
//   - the running-server descriptor's new `version` field (round-trip +
//     backward-compatible decode of descriptors written before the field existed),
//   - the app-instance flock (non-blocking acquire / re-acquire after release),
//   - the control-socket negotiation (same version → OPEN, different → SHUTDOWN),
//   - the persisted open-workspace record round-trip.
//
// All file-backed, deterministic, and isolated to a per-test temp data home — no live
// wavesrv or app process required. The data home lives under a SHORT `/tmp` path: a
// unix socket's `sun_path` is capped at 104 bytes, so the default (long) temp dir
// would overflow it (the bind silently truncates).

import XCTest
@testable import WaveCore
@testable import WaveProtocol

final class AppSingleInstanceTests: XCTestCase {
    private var dataHome: String = ""

    override func setUpWithError() throws {
        dataHome = "/tmp/wn-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dataHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dataHome)
    }

    // MARK: Descriptor version field

    func testDescriptorRoundTripsVersion() {
        let desc = RunningServerDescriptor(
            wsaddr: "127.0.0.1:1", webaddr: "127.0.0.1:2", authkey: "k", pid: 123, version: "v9")
        WaveServerDescriptor.write(desc, dataHome: dataHome)
        let read = WaveServerDescriptor.read(dataHome: dataHome)
        XCTAssertEqual(read?.version, "v9")
        XCTAssertEqual(read, desc)
    }

    func testDescriptorDecodesWithoutVersionField() throws {
        // A descriptor written before `version` existed must still decode (version nil).
        let legacy = #"{"wsaddr":"a:1","webaddr":"a:2","authkey":"k","pid":7}"#
        let path = WaveServerDescriptor.path(dataHome: dataHome)
        try legacy.write(toFile: path, atomically: true, encoding: .utf8)
        let read = WaveServerDescriptor.read(dataHome: dataHome)
        XCTAssertNotNil(read)
        XCTAssertNil(read?.version)
        XCTAssertEqual(read?.pid, 7)
    }

    // MARK: App-instance lock

    func testInstanceLockIsExclusiveAndReacquirable() {
        guard let first = AppInstanceLock.tryAcquire(dataHome: dataHome) else {
            return XCTFail("first acquire should succeed")
        }
        // A second non-blocking acquire fails while the first is held (a primary exists).
        XCTAssertNil(AppInstanceLock.tryAcquire(dataHome: dataHome))
        first.release()
        // After release the lock is acquirable again (takeover successor path).
        guard let second = AppInstanceLock.tryAcquire(dataHome: dataHome) else {
            return XCTFail("re-acquire after release should succeed")
        }
        second.release()
    }

    // MARK: Control-socket negotiation

    func testNegotiateSameVersionRequestsOpenWindow() {
        let server = AppInstanceServer(dataHome: dataHome, version: "v1") { _ in nil }
        server.start()
        defer { server.stop() }
        waitForSocket()
        XCTAssertEqual(AppInstanceClient.negotiate(dataHome: dataHome, myVersion: "v1"), .openedWindow)
    }

    func testNegotiateDifferentVersionRequestsTakeover() {
        let received = OpBox()
        let server = AppInstanceServer(dataHome: dataHome, version: "v1") { op in received.set(op); return nil }
        server.start()
        defer { server.stop() }
        waitForSocket()
        XCTAssertEqual(AppInstanceClient.negotiate(dataHome: dataHome, myVersion: "v2"), .requestedTakeover)
        // The primary observed the SHUTDOWN op.
        let deadline = Date().addingTimeInterval(2)
        while received.get() == nil && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(received.get(), AppInstanceOp.shutdownForUpgrade)
    }

    func testQueryReturnsTheReplyLineForAnOpWithArguments() {
        let server = AppInstanceServer(dataHome: dataHome, version: "v1") { op in "ECHO " + op }
        server.start()
        defer { server.stop() }
        waitForSocket()
        let op = AppInstanceOp.dumpViews + " /tmp/dump.txt 640 400"
        XCTAssertEqual(AppInstanceClient.query(dataHome: dataHome, line: op), "ECHO " + op)
    }

    func testQueryReturnsNilWithNoPrimary() {
        XCTAssertNil(AppInstanceClient.query(dataHome: dataHome, line: AppInstanceOp.keyTab))
    }

    func testNegotiateFailsWithNoPrimary() {
        // No server listening: the secondary cannot connect.
        XCTAssertEqual(AppInstanceClient.negotiate(dataHome: dataHome, myVersion: "v1"), .failed)
    }

    // MARK: Open-workspace record

    func testOpenWindowsRecordRoundTrips() {
        OpenWindowsRecord.write(OpenWindowsRecord(workspaceids: ["a", "b"]), dataHome: dataHome)
        XCTAssertEqual(OpenWindowsRecord.read(dataHome: dataHome)?.workspaceids, ["a", "b"])
    }

    // MARK: Helpers

    /// Poll (by attempting a real connect) until the listener is accepting; the listen
    /// thread binds asynchronously after `start()`.
    private func waitForSocket() {
        let path = AppInstanceClient.socketPath(dataHome: dataHome)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if canConnect(path) { return }
            usleep(20_000)
        }
    }

    private func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: min(strlen(src) + 1, 104)))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }
}

/// Thread-safe holder for the op the server observed.
private final class OpBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
