// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveWeb — implements GUARDS §W ("Map `web:partition` → a distinct
// WKWebsiteDataStore so per-block sessions/cookies stay isolated"). Mirrors the
// Electron `<webview partition=…>` attribute (`webview.tsx:857-858,1120`).
//
// Electron partition semantics we mirror:
//   - empty/nil           → the shared default persistent session (cookies shared)
//   - "persist:NAME"      → a NAMED *persistent* isolated session
//   - "NAME" (no prefix)  → a NAMED in-memory (ephemeral) isolated session
//
// MARK: MAC-LINK / macOS 14 target
// `WKWebsiteDataStore(forIdentifier:)` — the only public API for a *named
// persistent* data store — is macOS 14+. The package deployment target is
// macOS 14, so "persist:NAME" always maps to a distinct persistent store and
// there is no shared-cookie fallback. Ephemeral named partitions use cached
// `.nonPersistent()` stores.

import Foundation
import WebKit
import CryptoKit

/// Process-wide registry mapping a `web:partition` string to a single, stable
/// `WKWebsiteDataStore`. The same partition string always returns the same store
/// instance (so multiple blocks in the same partition share a session), and
/// distinct partition strings return distinct stores (GUARDS §W).
public final class WebPartitionStore: @unchecked Sendable {
    /// Shared registry used by all web blocks in the process.
    public static let shared = WebPartitionStore()

    private let lock = NSLock()
    private var stores: [String: WKWebsiteDataStore] = [:]

    public init() {}

    /// Resolve the data store for a partition. Nil/empty → shared default.
    public func dataStore(for partition: String?) -> WKWebsiteDataStore {
        guard let partition, !partition.isEmpty else {
            return .default()
        }
        return cachedStore(for: partition)
    }

    private func cachedStore(for partition: String) -> WKWebsiteDataStore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = stores[partition] {
            return existing
        }
        let store = WebPartitionStore.makeStore(for: partition)
        stores[partition] = store
        return store
    }

    /// GUARDS §W cleanup: a deleted web block must not leak its on-disk session.
    /// Only `persist:NAME` partitions map to a *persistent* `WKWebsiteDataStore`;
    /// nil/empty (shared default) and bare/ephemeral partitions have nothing on
    /// disk to remove. The identifier is derived exactly as `makeStore` does so the
    /// same block always targets the same store. Drops the cached instance first so
    /// a re-created block rebuilds a fresh store.
    public func removeDataStore(for partition: String?) {
        guard let partition, let identifier = Self.removableIdentifier(for: partition) else { return }
        lock.lock()
        stores[partition] = nil
        lock.unlock()
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            if let error {
                NSLog("WebPartitionStore failed to remove data store for %@: %@",
                      partition, error.localizedDescription)
            }
        }
    }

    /// The persistent store identifier to remove for a partition, or nil when the
    /// partition has no on-disk data (nil/empty/bare/ephemeral → nothing to remove).
    /// Derived exactly as `makeStore` maps `persist:NAME`, so a deleted block targets
    /// the same store it created. Pure + testable.
    static func removableIdentifier(for partition: String?) -> UUID? {
        guard let partition, partition.hasPrefix(persistPrefix) else { return nil }
        return stableIdentifier(for: String(partition.dropFirst(persistPrefix.count)))
    }

    static let persistPrefix = "persist:"

    private static func makeStore(for partition: String) -> WKWebsiteDataStore {
        let persistPrefix = Self.persistPrefix
        if partition.hasPrefix(persistPrefix) {
            let name = String(partition.dropFirst(persistPrefix.count))
            return WKWebsiteDataStore(forIdentifier: stableIdentifier(for: name))
        }
        // Ephemeral named partition: a fresh in-memory store, cached so the same
        // name reuses the same isolated session for the life of the process.
        return .nonPersistent()
    }

    /// Deterministic UUIDv5 (RFC 4122, SHA-1, DNS namespace) from the partition
    /// name so the same "persist:NAME" reuses the same on-disk store across
    /// launches. macOS 14+ only (`forIdentifier:` requirement).
    static func stableIdentifier(for name: String) -> UUID {
        // RFC 4122 DNS namespace UUID.
        let namespace: [UInt8] = [
            0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
            0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
        ]
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespace))
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // Set version (5) and the RFC 4122 variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}
