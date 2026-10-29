// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — client-side mirror of the backend's transient badge store
// (`pkg/wcore/badge.go`). Seeded by `getallbadges`, kept current by routing the
// `badge` WPS event into `apply`. Block headers and tab pills read it; the merge
// rules (higher priority wins, then newer uuidv7 badgeid) match the backend so a
// late-joining window and a live one agree.
//
// Same locking/notify shape as `ConnectionStore` so it can ride inside the
// `Sendable` `BlockEnv`.

import Foundation
import WaveCore

public final class BadgeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var badges: [String: Badge] = [:]
    private var handlers: [(String, @Sendable () -> Void)] = []

    public init() {}

    /// Replace the whole set (the `getallbadges` snapshot).
    public func seed(_ events: [BadgeEvent]) {
        lock.lock()
        badges = [:]
        for ev in events {
            if let b = ev.badge, !ev.oref.isEmpty { badges[ev.oref] = b }
        }
        lock.unlock()
        notify()
    }

    /// Apply one `badge` event. Returns whether the stored set changed.
    @discardableResult
    public func apply(_ event: BadgeEvent) -> Bool {
        let changed = applyLocked(event)
        if changed { notify() }
        return changed
    }

    private func applyLocked(_ event: BadgeEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if event.clearall == true {
            let had = !badges.isEmpty
            badges = [:]
            return had
        }
        guard !event.oref.isEmpty else { return false }
        if let id = event.clearbyid, !id.isEmpty {
            guard badges[event.oref]?.badgeid == id else { return false }
            badges.removeValue(forKey: event.oref)
            return true
        }
        if event.clear == true {
            return badges.removeValue(forKey: event.oref) != nil
        }
        guard let incoming = event.badge else { return false }
        if let existing = badges[event.oref], Self.compare(incoming, existing) <= 0 { return false }
        badges[event.oref] = incoming
        return true
    }

    public func badge(for oref: String) -> Badge? {
        lock.lock(); defer { lock.unlock() }
        return badges[oref]
    }

    public func blockBadge(_ blockId: String) -> Badge? {
        badge(for: ORef.block(blockId).string)
    }

    /// Every badge shown on a tab's pill: its blocks' badges plus the tab's own,
    /// highest priority first (Electron `getTabBadgeAtom` + `sortBadgesForTab`).
    public func tabBadges(tabId: String, blockIds: [String]) -> [Badge] {
        lock.lock(); defer { lock.unlock() }
        var out = blockIds.compactMap { badges[ORef.block($0).string] }
        if let tb = badges[ORef.tab(tabId).string] { out.append(tb) }
        return Self.sortedForTab(out)
    }

    /// Backend `cmpBadge`: priority, then badgeid (uuidv7 → newer is greater).
    static func compare(_ a: Badge, _ b: Badge) -> Int {
        if a.priority != b.priority { return a.priority > b.priority ? 1 : -1 }
        if a.badgeid != b.badgeid { return a.badgeid > b.badgeid ? 1 : -1 }
        return 0
    }

    /// Priority descending, then OLDEST badgeid first so the pill's lead icon is
    /// stable while newer equal-priority badges pile up behind it.
    static func sortedForTab(_ list: [Badge]) -> [Badge] {
        list.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.badgeid < $1.badgeid
        }
    }

    /// Subscribe to any change. The handler carries no payload — subscribers re-read
    /// what they care about. Cancel to detach.
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
