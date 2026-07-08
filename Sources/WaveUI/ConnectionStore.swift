// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — client-side connection state (the connection half of Electron parity).
//
// `ConnectionLabel` is the pure derivation of a block header's connection title +
// icon (local machine vs. remote user@host), mirroring Electron's ConnectionButton
// (`frontend/app/block/connectionbutton.tsx`). It is AppKit-free so it stays unit-
// testable.
//
// `ConnectionStore` is the live status cache. It is seeded by the `connstatus` RPC
// and kept current by routing the `connchange` WPS event (`pkg/wps/wpstypes.go:19`,
// payload `ConnStatus`) into it. Block headers subscribe to colour their remote
// icon by status; the connect-status overlay reads it for connecting/error state.
//
// The store is a reference type guarded by an internal lock (the ObjectStore
// pattern) so it can ride along inside the `Sendable` `BlockEnv`; all mutation and
// notification happen on the main thread in practice.

import Foundation
import WaveCore

/// Pure derivation of a block header's connection presentation. Kept free of
/// AppKit/state so it is directly unit-testable.
public enum ConnectionLabel {
    /// The metadata key carrying a block's connection (`pkg/waveobj/metaconsts.go:19`,
    /// `MetaKey_Connection`).
    public static let metaKey = "connection"

    /// SF Symbol for the local machine (Electron uses FontAwesome "laptop").
    public static let localIcon = "laptopcomputer"
    /// SF Symbol for a remote connection (mirrors Electron's
    /// "arrow-right-arrow-left" connection glyph).
    public static let remoteIcon = "arrow.left.arrow.right"

    public struct Derived: Equatable {
        public let title: String
        public let icon: String
        public let isLocal: Bool
    }

    /// `isLocalConnName` (`frontend/util/util.ts:15`): blank, "local", or a
    /// "local:" variant (e.g. "local:gitbash") is the local machine.
    public static func isLocal(_ connection: String?) -> Bool {
        guard let connection, !connection.isEmpty else { return true }
        return connection == "local" || connection.hasPrefix("local:")
    }

    /// Header title + icon for a block's connection. Local → the local display name
    /// (`localDisplayName`, already resolved from the `conn:localhostdisplayname`
    /// setting or `user@host`); remote → the connection string itself.
    public static func derive(connection: String?, localDisplayName: String) -> Derived {
        if isLocal(connection) {
            return Derived(title: localDisplayName, icon: localIcon, isLocal: true)
        }
        return Derived(title: connection ?? "", icon: remoteIcon, isLocal: false)
    }

    /// The default local display name: `user@host` (Electron's `getUserName() + "@" +
    /// getHostName()` fallback when `conn:localhostdisplayname` is unset).
    public static func defaultLocalDisplayName() -> String {
        let user = NSUserName()
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return "\(user)@\(host)"
    }
}

/// Live connection-status cache. Seeded by `connstatus` and updated by `connchange`.
/// Reference-typed + lock-guarded so it can be carried in the `Sendable` `BlockEnv`.
public final class ConnectionStore: @unchecked Sendable {
    /// Electron's `NumActiveConnColors` (`frontend/app/block/blockutil.tsx:24`).
    public static let numActiveConnColors = 8

    private let lock = NSLock()
    private var statuses: [String: ConnStatus] = [:]
    private var _localDisplayName: String
    private var handlers: [(String, @Sendable () -> Void)] = []

    public init(localDisplayName: String = ConnectionLabel.defaultLocalDisplayName()) {
        self._localDisplayName = localDisplayName
    }

    public var localDisplayName: String {
        lock.lock(); defer { lock.unlock() }
        return _localDisplayName
    }

    public func setLocalDisplayName(_ name: String) {
        lock.lock(); _localDisplayName = name; lock.unlock()
        notify()
    }

    /// Replace the whole status set (the `connstatus` seed).
    public func seed(_ list: [ConnStatus]) {
        lock.lock()
        statuses = Dictionary(list.map { ($0.connection, $0) }, uniquingKeysWith: { _, b in b })
        lock.unlock()
        notify()
    }

    /// Upsert a single status by its `connection` (a `connchange` event).
    public func upsert(_ status: ConnStatus) {
        lock.lock(); statuses[status.connection] = status; lock.unlock()
        notify()
    }

    public func status(for connection: String) -> ConnStatus? {
        lock.lock(); defer { lock.unlock() }
        return statuses[connection]
    }

    /// `computeConnColorNum` (`blockutil.tsx:277`): map the active connection number
    /// onto 1...N so concurrent remotes get distinct header tints.
    public func colorNum(for connection: String) -> Int {
        let active = status(for: connection)?.activeconnnum ?? 1
        let n = active % Self.numActiveConnColors
        return n == 0 ? Self.numActiveConnColors : n
    }

    /// Subscribe to any change (seed/upsert/local-name). The handler carries no
    /// payload — subscribers re-read the status they care about. Cancel to detach.
    public func subscribe(_ handler: @escaping @Sendable () -> Void) -> SubscriptionToken {
        let id = UUID().uuidString
        lock.lock(); handlers.append((id, handler)); lock.unlock()
        return SubscriptionToken(id: id, onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers.removeAll { $0.0 == id }
            self.lock.unlock()
        })
    }

    private func notify() {
        lock.lock(); let hs = handlers.map { $0.1 }; lock.unlock()
        hs.forEach { $0() }
    }
}
