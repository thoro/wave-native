// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveStore — the Wave Object Store (WOS).
//
// Implements PROTOCOL.md §2 ("Wave Object Store"):
//   • oref-keyed observable cache of `AnyWaveObj`
//   • Load   : HTTP `ObjectService.GetObject` / `GetObjects` over the service layer
//              (`pkg/service/objectservice/objectservice.go:39,60`; FE `wos.ts:67`)
//   • Subscribe: WPS `waveobj:update` via the transport's `EventSubCommand`,
//              **scope = the oref string** (`pkg/wps/wps.go:241`; FE `wos.ts:91`)
//   • Merge  : version-guarded (`wos.ts:272`)
//   • Apply inline `WebReturnType.updates` into the SAME cache (`wos.ts:136`)
//
// Encodes GUARDS §B as precondition/assert + tests:
//   [MUST] apply `WebReturnType.updates` from every service response (here: load)
//   [MUST] version-guarded merge — drop any update whose obj.version <= cached.version
//   [MUST] event subscription scope is the oref STRING, not a bare id
//   (`Workspace.pinnedtabids` non-existence is enforced in WaveCore's model.)
//
// Concurrency: the cache and observer registries are guarded by a single NSLock
// using the lock/defer helper pattern. Observer callbacks are always invoked
// OUTSIDE the lock to avoid re-entrancy/deadlock.

import Foundation
import WaveCore

/// The oref-keyed Wave object cache. See file header for the PROTOCOL.md §2 /
/// GUARDS §B contract it implements.
public final class ObjectStore: ObjectStoreProtocol, @unchecked Sendable {
    private let transport: any WaveTransport

    private let lock = NSLock()
    private var cache: [ORef: AnyWaveObj] = [:]

    /// Per-oref local observers (ObjectStoreProtocol.subscribe). Keyed by the oref
    /// string, then by the subscription token id.
    private var observers: [String: [String: @Sendable (AnyWaveObj?) -> Void]] = [:]

    /// The single WPS `waveobj:update` subscription per oref (shared by all local
    /// observers of that oref). Torn down when the last observer cancels.
    private var wpsTokens: [String: SubscriptionToken] = [:]

    public init(transport: any WaveTransport) {
        self.transport = transport
    }

    // MARK: - Read

    public func get(_ oref: ORef) -> AnyWaveObj? {
        lock.lock()
        defer { lock.unlock() }
        return cache[oref]
    }

    // MARK: - Load (HTTP service layer, PROTOCOL.md §2 "Load")

    public func load(_ oref: ORef) async throws -> AnyWaveObj {
        precondition(!oref.isEmpty, "ObjectStore.load requires a non-empty oref")
        let call = WebCallType(
            service: "object",
            method: "GetObject",
            uicontext: nil,
            args: [.string(oref.string)]
        )
        let rtn = try await transport.callService(call)
        // GUARDS §B: apply inline updates from EVERY service response first.
        if let updates = rtn.updates {
            applyUpdates(updates)
        }
        if let err = rtn.error {
            throw WaveError.rpc(err)
        }
        guard let data = rtn.data, !data.isNull else {
            if let cached = get(oref) {
                return cached
            }
            throw WaveError.rpc("GetObject returned no object for \(oref.string)")
        }
        let obj = try Self.decodeObject(from: data)
        merge(obj)
        // A concurrently-delivered newer version may already be cached; return the
        // freshest value the cache holds for this oref.
        return get(oref) ?? obj
    }

    public func loadMany(_ orefs: [ORef]) async throws -> [AnyWaveObj] {
        guard !orefs.isEmpty else { return [] }
        for oref in orefs {
            precondition(!oref.isEmpty, "ObjectStore.loadMany requires non-empty orefs")
        }
        let call = WebCallType(
            service: "object",
            method: "GetObjects",
            uicontext: nil,
            args: [.array(orefs.map { .string($0.string) })]
        )
        let rtn = try await transport.callService(call)
        if let updates = rtn.updates {
            applyUpdates(updates)
        }
        if let err = rtn.error {
            throw WaveError.rpc(err)
        }
        guard let data = rtn.data, let arr = data.arrayValue else {
            throw WaveError.rpc("GetObjects returned a non-array payload")
        }
        var result: [AnyWaveObj] = []
        result.reserveCapacity(arr.count)
        for element in arr {
            if element.isNull { continue }
            let obj = try Self.decodeObject(from: element)
            merge(obj)
            result.append(get(obj.oref) ?? obj)
        }
        return result
    }

    // MARK: - Merge (version-guarded, GUARDS §B)

    @discardableResult
    public func merge(_ obj: AnyWaveObj) -> Bool {
        let applied: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = cache[obj.oref], existing.version >= obj.version {
                // GUARDS §B: drop any update whose version <= the cached version.
                // Out-of-order delivery is normal; the guard prevents flicker back
                // to stale state.
                return false
            }
            cache[obj.oref] = obj
            return true
        }()
        if applied {
            notifyObservers(obj.oref.string, obj)
        }
        return applied
    }

    // MARK: - Apply updates (events AND inline WebReturnType.updates, GUARDS §B)

    public func applyUpdates(_ updates: [WaveObjUpdate]) {
        for update in updates {
            applyUpdate(update)
        }
    }

    private func applyUpdate(_ update: WaveObjUpdate) {
        let oref = update.oref
        guard !oref.isEmpty else { return }

        if update.isDelete {
            // Mirror the FE (`wos.ts:263-266`): deletes are applied unconditionally
            // (no version guard) and notify observers with a nil value.
            let removed: Bool = {
                lock.lock()
                defer { lock.unlock() }
                return cache.removeValue(forKey: oref) != nil
            }()
            if removed {
                notifyObservers(oref.string, nil)
            }
            return
        }

        let decoded: AnyWaveObj?
        do {
            decoded = try update.decodedObj()
        } catch {
            assertionFailure("undecodable waveobj:update for \(oref.string): \(error)")
            return
        }
        guard let obj = decoded else {
            // nil for unmodeled otypes / empty obj — nothing to merge (FE
            // `isValidWaveObj` guard, `wos.ts:267`).
            return
        }
        assert(obj.otype == update.otype, "update otype \(update.otype) != decoded otype \(obj.otype)")
        merge(obj)
    }

    // MARK: - Subscribe (WPS waveobj:update, scope = oref string, GUARDS §B)

    public func subscribe(
        _ oref: ORef,
        handler: @escaping @Sendable (AnyWaveObj?) -> Void
    ) -> SubscriptionToken {
        precondition(!oref.isEmpty, "ObjectStore.subscribe requires a non-empty oref")
        let key = oref.string
        let id = UUID().uuidString

        let isFirst: Bool = {
            lock.lock()
            defer { lock.unlock() }
            var byId = observers[key] ?? [:]
            let wasEmpty = byId.isEmpty
            byId[id] = handler
            observers[key] = byId
            return wasEmpty
        }()

        if isFirst {
            // GUARDS §B: the WPS subscription scope is the oref STRING (e.g.
            // "workspace:<oid>"), never a bare id (`pkg/wps/wps.go:241`).
            assert(key.contains(":"), "subscription scope must be an oref string")
            let wpsToken = transport.subscribe(
                SubscriptionRequest(event: WaveEventName.waveObjUpdate, scopes: [key])
            ) { [weak self] event in
                self?.handleObjectEvent(event)
            }
            lock.lock()
            wpsTokens[key] = wpsToken
            lock.unlock()
        }

        return SubscriptionToken { [weak self] in
            self?.removeObserver(key: key, id: id)
        }
    }

    private func removeObserver(key: String, id: String) {
        let tokenToCancel: SubscriptionToken? = {
            lock.lock()
            defer { lock.unlock() }
            guard var byId = observers[key] else { return nil }
            byId.removeValue(forKey: id)
            if byId.isEmpty {
                observers[key] = nil
                let token = wpsTokens.removeValue(forKey: key)
                return token
            }
            observers[key] = byId
            return nil
        }()
        // Cancel the shared WPS subscription outside the lock (cancel may run the
        // transport's teardown callback).
        tokenToCancel?.cancel()
    }

    /// Handler for an inbound `waveobj:update` WPS event: decode the payload into a
    /// `WaveObjUpdate` and route it through the same version-guarded apply path used
    /// for inline service `updates` (GUARDS §B).
    private func handleObjectEvent(_ event: WaveEvent) {
        guard let data = event.data, !data.isNull else { return }
        let update: WaveObjUpdate
        do {
            update = try data.decode(WaveObjUpdate.self)
        } catch {
            assertionFailure("undecodable waveobj:update event payload: \(error)")
            return
        }
        applyUpdate(update)
    }

    // MARK: - Notification (always called OUTSIDE the lock)

    private func notifyObservers(_ orefString: String, _ value: AnyWaveObj?) {
        let handlers: [@Sendable (AnyWaveObj?) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return Array((observers[orefString] ?? [:]).values)
        }()
        for handler in handlers {
            handler(value)
        }
    }

    // MARK: - Helpers

    /// Decode a polymorphic WaveObj JSON payload by reading its embedded `otype`
    /// (the FE does the same via `val["otype"]`, `wos.ts:178`).
    private static func decodeObject(from json: JSONValue) throws -> AnyWaveObj {
        guard let otype = json["otype"]?.stringValue, !otype.isEmpty else {
            throw WaveError.decoding("object payload is missing an \"otype\" field")
        }
        guard let obj = try AnyWaveObj.decode(otype: otype, from: json) else {
            throw WaveError.decoding("object payload has an unmodeled otype: \(otype)")
        }
        return obj
    }
}
